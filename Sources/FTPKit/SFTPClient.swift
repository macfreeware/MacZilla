import Darwin
import Foundation

/// SFTP (protocol version 3) spoken over the system `ssh -s sftp`, so keys,
/// ssh-agent, ~/.ssh/config and known_hosts all work as they do in Terminal.
public final class SFTPClient: RemoteClient, @unchecked Sendable {
    public let config: FTPConfig
    private let logHandler: @Sendable (LogKind, String) -> Void
    private let state = NSLock()
    private var process: Process?
    private var input: FileHandle?
    private var connected = false
    private var nextID: UInt32 = 1
    private var pending: [UInt32: CheckedContinuation<Packet, Error>] = [:]
    private var versionWaiter: CheckedContinuation<Packet, Error>?
    private var stderrTail: [String] = []
    private let writeQueue = DispatchQueue(label: "maczilla.sftp.write")
    public private(set) var homeDirectory = "/"

    public var isConnected: Bool {
        state.withLock { connected }
    }

    public init(config: FTPConfig, log: @escaping @Sendable (LogKind, String) -> Void = { _, _ in }) {
        self.config = config
        self.logHandler = log
        signal(SIGPIPE, SIG_IGN)
    }

    deinit { process?.terminate() }

    private func log(_ kind: LogKind, _ text: String) { logHandler(kind, text) }

    // MARK: Connection

    public func connect() async throws {
        shutdown()
        guard !config.host.hasPrefix("-"), !config.user.hasPrefix("-") else {
            throw FTPError.local(String(localized: "Geçersiz sunucu ya da kullanıcı adı."))
        }
        log(.status, String(localized: "\(config.user)@\(config.host):\(String(config.port)) adresine SSH ile bağlanılıyor…"))

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        var args = ["-p", String(config.port),
                    "-o", "StrictHostKeyChecking=accept-new",
                    "-o", "NumberOfPasswordPrompts=1",
                    "-o", "ConnectTimeout=20",
                    "-o", "ServerAliveInterval=30",
                    "-o", "ServerAliveCountMax=3",
                    "-o", "LogLevel=ERROR",
                    "-T"]
        if !config.keyFile.isEmpty {
            args += ["-i", (config.keyFile as NSString).expandingTildeInPath]
        }
        args += config.sshOptions
        args += ["-l", config.user, "-s", "--", config.host, "sftp"]
        p.arguments = args

        var env = ProcessInfo.processInfo.environment
        env["SSH_ASKPASS"] = try Self.askpassScript().path
        env["SSH_ASKPASS_REQUIRE"] = "force"
        env["DISPLAY"] = env["DISPLAY"] ?? ":0"
        env["MACZILLA_SSH_SECRET"] = config.password
        p.environment = env

        let stdinPipe = Pipe(), stdoutPipe = Pipe(), stderrPipe = Pipe()
        p.standardInput = stdinPipe
        p.standardOutput = stdoutPipe
        p.standardError = stderrPipe
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty, let self else { return }
            let text = String(decoding: data, as: UTF8.self)
            for line in text.split(whereSeparator: \.isNewline) where !line.isEmpty {
                self.state.lock()
                self.stderrTail.append(String(line))
                if self.stderrTail.count > 20 { self.stderrTail.removeFirst() }
                self.state.unlock()
                self.log(.response, "ssh: \(line)")
            }
        }
        p.terminationHandler = { _ in stderrPipe.fileHandleForReading.readabilityHandler = nil }

        do { try p.run() } catch { throw FTPError.connectionFailed(String(localized: "ssh başlatılamadı: \(error.localizedDescription)")) }
        state.withLock {
            process = p
            input = stdinPipe.fileHandleForWriting
            connected = true
            stderrTail = []
        }
        startReader(stdoutPipe.fileHandleForReading.fileDescriptor)

        var initPacket = Data()
        initPacket.appendU32(5)
        initPacket.append(SFTP.initType)
        initPacket.appendU32(3)
        log(.command, String(localized: "sftp: INIT (sürüm 3)"))
        let version: Packet = try await withCheckedThrowingContinuation { cont in
            state.lock()
            versionWaiter = cont
            state.unlock()
            write(initPacket, id: nil)
        }
        var r = ByteReader(version.payload)
        let v = (try? r.u32()) ?? 0
        log(.response, "sftp: VERSION \(v)")
        homeDirectory = try await realpath(".")
        log(.status, String(localized: "SFTP oturumu açıldı. Ana dizin: \(homeDirectory)"))
    }

    public func disconnect() async {
        guard isConnected else { return }
        shutdown()
        log(.status, String(localized: "Bağlantı kesildi."))
    }

    private func shutdown() {
        state.lock()
        let p = process, h = input
        process = nil
        input = nil
        connected = false
        state.unlock()
        try? h?.close()
        if let p, p.isRunning { p.terminate() }
    }

    private static func askpassScript() throws -> URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacZilla", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("askpass.sh")
        let script = """
        #!/bin/sh
        # MacZilla: answers ssh's password / passphrase prompt from the environment.
        printf '%s\\n' "$MACZILLA_SSH_SECRET"

        """
        if (try? String(contentsOf: url, encoding: .utf8)) != script {
            try script.write(to: url, atomically: true, encoding: .utf8)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    // MARK: Packet I/O

    struct Packet {
        let type: UInt8
        let payload: Data
    }

    private func startReader(_ fd: Int32) {
        let thread = Thread { [weak self] in
            var buffer = [UInt8]()
            var chunk = [UInt8](repeating: 0, count: 256 * 1024)
            while true {
                let n = read(fd, &chunk, chunk.count)
                if n <= 0 { break }
                buffer.append(contentsOf: chunk[0..<n])
                var start = 0
                while buffer.count - start >= 4 {
                    let len = Int(buffer[start]) << 24 | Int(buffer[start + 1]) << 16
                        | Int(buffer[start + 2]) << 8 | Int(buffer[start + 3])
                    guard buffer.count - start - 4 >= len, len >= 1 else { break }
                    let body = Data(buffer[(start + 4)..<(start + 4 + len)])
                    start += 4 + len
                    self?.dispatch(body)
                }
                if start > 0 { buffer.removeFirst(start) }
            }
            self?.readerFinished()
        }
        thread.name = "MacZilla SFTP reader"
        thread.start()
    }

    private func dispatch(_ body: Data) {
        let type = body[body.startIndex]
        if type == SFTP.versionType {
            state.lock()
            let waiter = versionWaiter
            versionWaiter = nil
            state.unlock()
            waiter?.resume(returning: Packet(type: type, payload: Data(body.dropFirst())))
            return
        }
        guard body.count >= 5 else { return }
        var r = ByteReader(Data(body.dropFirst()))
        guard let id = try? r.u32() else { return }
        state.lock()
        let cont = pending.removeValue(forKey: id)
        state.unlock()
        cont?.resume(returning: Packet(type: type, payload: r.rest))
    }

    private func readerFinished() {
        // Give the stderr handler a moment to deliver ssh's reason.
        usleep(150_000)
        state.lock()
        connected = false
        let waiters = Array(pending.values)
        pending.removeAll()
        let versionWaiter = self.versionWaiter
        self.versionWaiter = nil
        let reason = stderrTail.last(where: { !$0.lowercased().hasPrefix("warning") }) ?? stderrTail.last
        state.unlock()
        let error = FTPError.connectionFailed(reason ?? String(localized: "SSH bağlantısı kapandı."))
        versionWaiter?.resume(throwing: error)
        waiters.forEach { $0.resume(throwing: error) }
    }

    private func write(_ data: Data, id: UInt32?) {
        state.lock()
        let handle = input
        state.unlock()
        writeQueue.async { [weak self] in
            do {
                guard let handle else { throw FTPError.notConnected }
                try handle.write(contentsOf: data)
            } catch {
                guard let self, let id else { return }
                self.state.lock()
                let cont = self.pending.removeValue(forKey: id)
                self.state.unlock()
                cont?.resume(throwing: FTPError.connectionClosed)
            }
        }
    }

    private func request(_ type: UInt8, _ body: Data) async throws -> Packet {
        try await withCheckedThrowingContinuation { cont in
            state.lock()
            guard connected else {
                state.unlock()
                cont.resume(throwing: FTPError.notConnected)
                return
            }
            let id = nextID
            nextID &+= 1
            pending[id] = cont
            state.unlock()
            var packet = Data()
            packet.appendU32(UInt32(1 + 4 + body.count))
            packet.append(type)
            packet.appendU32(id)
            packet.append(body)
            write(packet, id: id)
        }
    }

    /// Throws for any STATUS other than OK.
    private func check(_ packet: Packet, _ what: String) throws {
        guard packet.type == SFTP.status else {
            if packet.type == SFTP.handle || packet.type == SFTP.name || packet.type == SFTP.attrs || packet.type == SFTP.data { return }
            throw FTPError.badResponse(String(localized: "\(what): beklenmeyen paket \(String(packet.type))"))
        }
        var r = ByteReader(packet.payload)
        let code = (try? r.u32()) ?? 4
        guard code != SFTP.ok else { return }
        let message = (try? r.string()) ?? ""
        throw FTPError.server(code: Int(code), message: message.isEmpty ? SFTP.describe(code) : "\(message) (\(what))")
    }

    private func statusCode(_ packet: Packet) -> UInt32? {
        guard packet.type == SFTP.status else { return nil }
        var r = ByteReader(packet.payload)
        return try? r.u32()
    }

    private func handle(from packet: Packet, _ what: String) throws -> Data {
        try check(packet, what)
        guard packet.type == SFTP.handle else { throw FTPError.badResponse(what) }
        var r = ByteReader(packet.payload)
        return try r.bytes()
    }

    // MARK: Operations

    private func pathBody(_ path: String) -> Data {
        var d = Data()
        d.appendString(path)
        return d
    }

    private func realpath(_ path: String) async throws -> String {
        let reply = try await request(SFTP.realpath, pathBody(path))
        try check(reply, path)
        var r = ByteReader(reply.payload)
        guard try r.u32() >= 1 else { throw FTPError.badResponse("REALPATH") }
        return try r.string()
    }

    private func stat(_ path: String) async throws -> Attributes? {
        let reply = try await request(SFTP.stat, pathBody(path))
        if statusCode(reply) == SFTP.noSuchFile { return nil }
        try check(reply, path)
        var r = ByteReader(reply.payload)
        return try r.attributes()
    }

    public func list(_ path: String) async throws -> (path: String, files: [RemoteFile]) {
        let canonical = try await realpath(path)
        log(.command, "sftp: ls \(canonical)")
        let dirHandle = try handle(from: try await request(SFTP.opendir, pathBody(canonical)), canonical)
        defer { closeHandle(dirHandle) }

        var entries: [(name: String, longname: String, attrs: Attributes)] = []
        while true {
            var body = Data()
            body.appendBytes(dirHandle)
            let reply = try await request(SFTP.readdir, body)
            if statusCode(reply) == SFTP.eof { break }
            try check(reply, canonical)
            var r = ByteReader(reply.payload)
            let count = try r.u32()
            for _ in 0..<count {
                let name = try r.string()
                let longname = try r.string()
                let attrs = try r.attributes()
                if name != "." && name != ".." { entries.append((name, longname, attrs)) }
            }
        }

        var files: [RemoteFile] = []
        for e in entries {
            let mode = e.attrs.permissions ?? 0
            let isLink = mode & 0o170000 == 0o120000
            var isDir = mode & 0o170000 == 0o040000
            if isLink, let target = try? await stat(RemotePath.join(canonical, e.name)) {
                isDir = (target.permissions ?? 0) & 0o170000 == 0o040000
            }
            let owner = e.longname.split(separator: " ", omittingEmptySubsequences: true)
            files.append(RemoteFile(name: e.name, isDirectory: isDir, isLink: isLink,
                                    size: isDir ? 0 : Int64(e.attrs.size ?? 0),
                                    modified: e.attrs.mtime.map { Date(timeIntervalSince1970: TimeInterval($0)) } ?? .distantPast,
                                    permissions: Attributes.modeString(mode),
                                    owner: owner.count > 2 ? String(owner[2]) : "",
                                    preciseTime: e.attrs.mtime != nil))
        }
        log(.response, String(localized: "sftp: \(files.count) öğe"))
        return (canonical, files)
    }

    private func closeHandle(_ h: Data) {
        var body = Data()
        body.appendBytes(h)
        Task { _ = try? await request(SFTP.close, body) }
    }

    private func simple(_ type: UInt8, _ body: Data, _ what: String) async throws {
        log(.command, "sftp: \(what)")
        try check(try await request(type, body), what)
    }

    public func makeDirectory(_ path: String) async throws {
        var body = pathBody(path)
        body.appendU32(0)
        try await simple(SFTP.mkdir, body, "mkdir \(path)")
    }

    public func deleteFile(_ path: String) async throws {
        try await simple(SFTP.remove, pathBody(path), "rm \(path)")
    }

    public func removeDirectory(_ path: String, recursive: Bool) async throws {
        if recursive {
            let (_, files) = try await list(path)
            for f in files {
                let child = RemotePath.join(path, f.name)
                if f.isDirectory && !f.isLink {
                    try await removeDirectory(child, recursive: true)
                } else {
                    try await deleteFile(child)
                }
            }
        }
        try await simple(SFTP.rmdir, pathBody(path), "rmdir \(path)")
    }

    public func rename(_ from: String, to: String) async throws {
        var body = pathBody(from)
        body.appendString(to)
        try await simple(SFTP.rename, body, "rename \(from) \(to)")
    }

    public func chmod(_ path: String, mode: String) async throws {
        guard let m = UInt32(mode, radix: 8) else { throw FTPError.local(String(localized: "Geçersiz izin değeri: \(mode)")) }
        var body = pathBody(path)
        body.appendU32(SFTP.attrPermissions)
        body.appendU32(m)
        try await simple(SFTP.setstat, body, "chmod \(mode) \(path)")
    }

    public func size(_ path: String) async throws -> Int64? {
        try await stat(path).map { Int64($0.size ?? 0) }
    }

    public func noop() async throws {
        _ = try await realpath(".")
    }

    public func modified(_ path: String) async throws -> Date? {
        try await stat(path)?.mtime.map { Date(timeIntervalSince1970: TimeInterval($0)) }
    }

    public func setModified(_ path: String, to date: Date) async throws -> Bool {
        let t = UInt32(clamping: Int(date.timeIntervalSince1970))
        var body = pathBody(path)
        body.appendU32(SFTP.attrTimes)
        body.appendU32(t) // atime
        body.appendU32(t) // mtime
        try await simple(SFTP.setstat, body, "touch \(path)")
        return true
    }

    private static let chunk = 32 * 1024
    private static let window = 32

    public func download(_ remotePath: String, to localURL: URL,
                         progress: @escaping @Sendable (Int64) -> Void) async throws {
        log(.command, "sftp: get \(remotePath)")
        var open = pathBody(remotePath)
        open.appendU32(SFTP.openRead)
        open.appendU32(0)
        let fileHandle = try handle(from: try await request(SFTP.open, open), remotePath)
        defer { closeHandle(fileHandle) }

        guard FileManager.default.createFile(atPath: localURL.path, contents: nil) else {
            throw FTPError.local(String(localized: "Yerel dosya oluşturulamadı: \(localURL.path)"))
        }
        let out = try FileHandle(forWritingTo: localURL)
        defer { try? out.close() }

        let throttle = ProgressThrottle(progress)
        var total: Int64 = 0
        var nextOffset: UInt64 = 0
        var reachedEOF = false
        var inflight: [(offset: UInt64, length: Int, task: Task<Packet, Error>)] = []
        var retries: [(UInt64, Int)] = []

        func issue(_ offset: UInt64, _ length: Int) {
            var body = Data()
            body.appendBytes(fileHandle)
            body.appendU64(offset)
            body.appendU32(UInt32(length))
            inflight.append((offset, length, Task { try await self.request(SFTP.read, body) }))
        }

        while true {
            while inflight.count < Self.window, !Task.isCancelled {
                if !retries.isEmpty {
                    let (o, l) = retries.removeFirst()
                    issue(o, l)
                } else if !reachedEOF {
                    issue(nextOffset, Self.chunk)
                    nextOffset += UInt64(Self.chunk)
                } else {
                    break
                }
            }
            guard !inflight.isEmpty else { break }
            let (offset, length, task) = inflight.removeFirst()
            let reply = try await task.value
            if Task.isCancelled { continue }
            if statusCode(reply) == SFTP.eof { reachedEOF = true; continue }
            try check(reply, remotePath)
            var r = ByteReader(reply.payload)
            let data = try r.bytes()
            try out.seek(toOffset: offset)
            try out.write(contentsOf: data)
            total += Int64(data.count)
            throttle.report(total)
            try await TransferLimits.shared.consume(data.count, upload: false)
            if data.count < length && !data.isEmpty {
                retries.append((offset + UInt64(data.count), length - data.count))
            } else if data.isEmpty {
                reachedEOF = true
            }
        }
        if Task.isCancelled { throw CancellationError() }
        throttle.finish(total)
    }

    public func upload(_ localURL: URL, to remotePath: String,
                       progress: @escaping @Sendable (Int64) -> Void) async throws {
        let input: FileHandle
        do { input = try FileHandle(forReadingFrom: localURL) }
        catch { throw FTPError.local(String(localized: "Yerel dosya okunamadı: \(localURL.path)")) }
        defer { try? input.close() }

        log(.command, "sftp: put \(remotePath)")
        var open = pathBody(remotePath)
        open.appendU32(SFTP.openWrite | SFTP.openCreate | SFTP.openTruncate)
        open.appendU32(0)
        let fileHandle = try handle(from: try await request(SFTP.open, open), remotePath)

        let throttle = ProgressThrottle(progress)
        var total: Int64 = 0
        var offset: UInt64 = 0
        var inflight: [(count: Int, task: Task<Packet, Error>)] = []
        var finished = false
        do {
            while true {
                while !finished, inflight.count < Self.window, !Task.isCancelled {
                    guard let data = try input.read(upToCount: Self.chunk), !data.isEmpty else {
                        finished = true
                        break
                    }
                    try await TransferLimits.shared.consume(data.count, upload: true)
                    var body = Data()
                    body.appendBytes(fileHandle)
                    body.appendU64(offset)
                    body.appendBytes(data)
                    offset += UInt64(data.count)
                    inflight.append((data.count, Task { try await self.request(SFTP.write, body) }))
                }
                guard !inflight.isEmpty else { break }
                let (count, task) = inflight.removeFirst()
                try check(try await task.value, remotePath)
                total += Int64(count)
                throttle.report(total)
            }
        } catch {
            closeHandle(fileHandle)
            throw error
        }
        var body = Data()
        body.appendBytes(fileHandle)
        try check(try await request(SFTP.close, body), remotePath)
        if Task.isCancelled { throw CancellationError() }
        throttle.finish(total)
    }
}

// MARK: - Wire format

enum SFTP {
    static let initType: UInt8 = 1, versionType: UInt8 = 2
    static let open: UInt8 = 3, close: UInt8 = 4, read: UInt8 = 5, write: UInt8 = 6
    static let setstat: UInt8 = 9, opendir: UInt8 = 11, readdir: UInt8 = 12, remove: UInt8 = 13
    static let mkdir: UInt8 = 14, rmdir: UInt8 = 15, realpath: UInt8 = 16, stat: UInt8 = 17, rename: UInt8 = 18
    static let status: UInt8 = 101, handle: UInt8 = 102, data: UInt8 = 103, name: UInt8 = 104, attrs: UInt8 = 105

    static let ok: UInt32 = 0, eof: UInt32 = 1, noSuchFile: UInt32 = 2
    static let openRead: UInt32 = 0x01, openWrite: UInt32 = 0x02, openCreate: UInt32 = 0x08, openTruncate: UInt32 = 0x10
    static let attrSize: UInt32 = 0x01, attrUIDGID: UInt32 = 0x02, attrPermissions: UInt32 = 0x04
    static let attrTimes: UInt32 = 0x08, attrExtended: UInt32 = 0x8000_0000

    static func describe(_ code: UInt32) -> String {
        switch code {
        case 1: return String(localized: "Dosya sonu")
        case 2: return String(localized: "Böyle bir dosya yok")
        case 3: return String(localized: "İzin reddedildi")
        case 4: return String(localized: "İşlem başarısız")
        case 5: return String(localized: "Hatalı mesaj")
        case 6: return String(localized: "Bağlantı yok")
        case 7: return String(localized: "Bağlantı kaybedildi")
        case 8: return String(localized: "Desteklenmeyen işlem")
        default: return String(localized: "SFTP hata kodu \(String(code))")
        }
    }
}

struct Attributes {
    var size: UInt64?
    var permissions: UInt32?
    var mtime: UInt32?

    static func modeString(_ mode: UInt32) -> String {
        guard mode != 0 else { return "" }
        let type: Character
        switch mode & 0o170000 {
        case 0o040000: type = "d"
        case 0o120000: type = "l"
        default: type = "-"
        }
        let chars = Array("rwxrwxrwx")
        return String(type) + String((0..<9).map { mode & (1 << (8 - UInt32($0))) != 0 ? chars[$0] : "-" })
    }
}

struct ByteReader {
    private let data: Data
    private var offset: Int

    init(_ data: Data) {
        self.data = data
        offset = data.startIndex
    }

    var rest: Data { Data(data[offset...]) }

    mutating func u32() throws -> UInt32 {
        guard data.endIndex - offset >= 4 else { throw FTPError.badResponse(String(localized: "kısa paket")) }
        let v = data[offset..<offset + 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        offset += 4
        return v
    }

    mutating func u64() throws -> UInt64 {
        UInt64(try u32()) << 32 | UInt64(try u32())
    }

    mutating func bytes() throws -> Data {
        let len = Int(try u32())
        guard data.endIndex - offset >= len else { throw FTPError.badResponse(String(localized: "kısa paket")) }
        let d = Data(data[offset..<offset + len])
        offset += len
        return d
    }

    mutating func string() throws -> String {
        let d = try bytes()
        return String(data: d, encoding: .utf8) ?? String(decoding: d, as: UTF8.self)
    }

    mutating func attributes() throws -> Attributes {
        var a = Attributes()
        let flags = try u32()
        if flags & SFTP.attrSize != 0 { a.size = try u64() }
        if flags & SFTP.attrUIDGID != 0 { _ = try u32(); _ = try u32() }
        if flags & SFTP.attrPermissions != 0 { a.permissions = try u32() }
        if flags & SFTP.attrTimes != 0 { _ = try u32(); a.mtime = try u32() }
        if flags & SFTP.attrExtended != 0 {
            for _ in 0..<(try u32()) { _ = try bytes(); _ = try bytes() }
        }
        return a
    }
}

extension Data {
    mutating func appendU32(_ v: UInt32) {
        append(contentsOf: [UInt8(v >> 24), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)])
    }

    mutating func appendU64(_ v: UInt64) {
        appendU32(UInt32(v >> 32))
        appendU32(UInt32(v & 0xFFFF_FFFF))
    }

    mutating func appendBytes(_ d: Data) {
        appendU32(UInt32(d.count))
        append(d)
    }

    mutating func appendString(_ s: String) {
        appendBytes(Data(s.utf8))
    }
}
