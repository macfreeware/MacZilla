import Foundation
import Security

public struct FTPResponse: Sendable {
    public let code: Int
    public let lines: [String]

    public var message: String {
        lines.map { $0.count > 4 ? String($0.dropFirst(4)) : $0 }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
    }
}

/// A single FTP session (one control connection). All public methods are
/// serialized, so it is safe to call them from multiple tasks.
public final class FTPClient: RemoteClient, @unchecked Sendable {
    public let config: FTPConfig
    private let logHandler: @Sendable (LogKind, String) -> Void
    private let trustHandler: TrustHandler?
    private let lock = AsyncLock()
    private var control: SocketStream?
    private var protectData = false
    private var acceptedFingerprint: String?
    private var features = Set<String>()
    private var useEPSV = true
    private var listArgsSupported = true
    private var transferType: String?
    public private(set) var homeDirectory = "/"

    public var isConnected: Bool { control != nil }

    public init(config: FTPConfig, log: @escaping @Sendable (LogKind, String) -> Void = { _, _ in },
                trust: TrustHandler? = nil) {
        self.config = config
        self.logHandler = log
        self.trustHandler = trust
    }

    private var peerID: String { "\(config.host):\(config.port)" }

    // MARK: Public API

    public func connect() async throws {
        try await locked { try await self._connect() }
    }

    public func disconnect() async {
        await lock.acquire()
        if control != nil {
            _ = try? await raw("QUIT")
            control?.close()
            control = nil
            log(.status, String(localized: "Bağlantı kesildi."))
        }
        await lock.release()
    }

    /// Changes to `path` and lists it. Returns the canonical path reported by the server.
    public func list(_ path: String) async throws -> (path: String, files: [RemoteFile]) {
        try await locked { try await self._list(path) }
    }

    public func makeDirectory(_ path: String) async throws {
        try await locked { _ = try await self.cmd("MKD \(path)") }
    }

    public func deleteFile(_ path: String) async throws {
        try await locked { _ = try await self.cmd("DELE \(path)") }
    }

    public func removeDirectory(_ path: String, recursive: Bool) async throws {
        try await locked {
            if recursive { try await self._deleteRecursive(path) } else { _ = try await self.cmd("RMD \(path)") }
        }
    }

    public func rename(_ from: String, to: String) async throws {
        try await locked {
            _ = try await self.cmd("RNFR \(from)")
            _ = try await self.cmd("RNTO \(to)")
        }
    }

    public func chmod(_ path: String, mode: String) async throws {
        try await locked { _ = try await self.cmd("SITE CHMOD \(mode) \(path)") }
    }

    /// Remote file size, or nil if the file does not exist.
    public func size(_ path: String) async throws -> Int64? {
        try await locked {
            try await self.setType("I")
            let r = try await self.raw("SIZE \(path)")
            guard r.code == 213 else { return nil }
            return Int64(r.message.trimmingCharacters(in: .whitespaces))
        }
    }

    public func noop() async throws {
        try await locked { _ = try await self.cmd("NOOP") }
    }

    public func modified(_ path: String) async throws -> Date? {
        try await locked {
            // Servers without FEAT may still know MDTM, so only skip when FEAT says no.
            guard self.features.isEmpty || self.features.contains("MDTM") else { return nil }
            let r = try await self.raw("MDTM \(path)")
            return r.code == 213 ? FTPTime.parse(r.message) : nil
        }
    }

    public func setModified(_ path: String, to date: Date) async throws -> Bool {
        try await locked {
            guard self.features.contains("MFMT") else { return false }
            return try await self.raw("MFMT \(FTPTime.format(date)) \(path)").code == 213
        }
    }

    public func download(_ remotePath: String, to localURL: URL,
                         progress: @escaping @Sendable (Int64) -> Void) async throws {
        try await locked {
            try await self.setType("I")
            let data = try await self.openDataConnection()
            defer { data.close() }
            let r = try await self.raw("RETR \(remotePath)")
            guard r.code == 150 || r.code == 125 else { throw FTPError.server(code: r.code, message: r.message) }
            try await self.secureData(data)
            guard FileManager.default.createFile(atPath: localURL.path, contents: nil) else {
                self.abortConnection()
                throw FTPError.local(String(localized: "Yerel dosya oluşturulamadı: \(localURL.path)"))
            }
            let handle = try FileHandle(forWritingTo: localURL)
            defer { try? handle.close() }
            let throttle = ProgressThrottle(progress)
            var total: Int64 = 0
            do {
                try await withTaskCancellationHandler {
                    while let chunk = try await data.receive() {
                        try Task.checkCancellation()
                        try handle.write(contentsOf: chunk)
                        total += Int64(chunk.count)
                        throttle.report(total)
                        try await TransferLimits.shared.consume(chunk.count, upload: false)
                    }
                } onCancel: {
                    data.close()
                }
                try Task.checkCancellation()
            } catch {
                self.abortConnection()
                throw Task.isCancelled ? CancellationError() : error
            }
            throttle.finish(total)
            let done = try await self.readResponse()
            if done.code >= 400 { throw FTPError.server(code: done.code, message: done.message) }
        }
    }

    public func upload(_ localURL: URL, to remotePath: String,
                       progress: @escaping @Sendable (Int64) -> Void) async throws {
        try await locked {
            let handle: FileHandle
            do { handle = try FileHandle(forReadingFrom: localURL) }
            catch { throw FTPError.local(String(localized: "Yerel dosya okunamadı: \(localURL.path)")) }
            defer { try? handle.close() }
            try await self.setType("I")
            let data = try await self.openDataConnection()
            defer { data.close() }
            let r = try await self.raw("STOR \(remotePath)")
            guard r.code == 150 || r.code == 125 else { throw FTPError.server(code: r.code, message: r.message) }
            try await self.secureData(data)
            let throttle = ProgressThrottle(progress)
            var total: Int64 = 0
            do {
                try await withTaskCancellationHandler {
                    while true {
                        try Task.checkCancellation()
                        let size = TransferLimits.shared.chunkSize(upload: true, default: 256 * 1024)
                        guard let chunk = try handle.read(upToCount: size), !chunk.isEmpty else { break }
                        try await data.send(chunk)
                        total += Int64(chunk.count)
                        throttle.report(total)
                        try await TransferLimits.shared.consume(chunk.count, upload: true)
                    }
                } onCancel: {
                    data.close()
                }
            } catch {
                self.abortConnection()
                throw Task.isCancelled ? CancellationError() : error
            }
            await data.finishSending()
            throttle.finish(total)
            let done = try await self.readResponse()
            if done.code >= 400 { throw FTPError.server(code: done.code, message: done.message) }
        }
    }

    // MARK: Internals

    private func log(_ kind: LogKind, _ text: String) {
        logHandler(kind, text)
    }

    private func locked<T>(_ body: () async throws -> T) async throws -> T {
        await lock.acquire()
        do {
            let result = try await body()
            await lock.release()
            return result
        } catch {
            await lock.release()
            throw error
        }
    }

    private func abortConnection() {
        control?.close()
        control = nil
        transferType = nil
        protectData = false
    }

    /// Accepts certificates macOS trusts, ones the user already accepted in
    /// this session, and otherwise asks the trust handler.
    private func verify(_ trust: SecTrust) async -> Bool {
        let (trusted, info) = SocketStream.inspect(trust, host: config.host)
        if trusted { return true }
        if info.fingerprint == acceptedFingerprint { return true }
        log(.status, String(localized: "Sertifika doğrulanamadı: \(info.subject) — \(info.problem)"))
        guard let trustHandler, await trustHandler(info) else { return false }
        acceptedFingerprint = info.fingerprint
        log(.status, String(localized: "Sertifikaya güvenildi: \(info.fingerprint)"))
        return true
    }

    private func secureData(_ data: SocketStream) async throws {
        guard protectData else { return }
        try await data.startTLS(peerID: peerID) { [weak self] trust in
            await self?.verify(trust) ?? false
        }
    }

    private func dropIfFatal(_ error: Error) {
        if let e = error as? FTPError, e.isConnectionError {
            if control != nil { log(.error, e.localizedDescription) }
            abortConnection()
        }
    }

    private func _connect() async throws {
        abortConnection()
        log(.status, String(localized: "\(config.host):\(String(config.port)) adresine bağlanılıyor…"))
        let stream = SocketStream(host: config.host, port: config.port, timeout: 20)
        try await stream.open()
        control = stream
        do {
            let tls = config.serverProtocol == .ftps || config.serverProtocol == .ftpes
            if config.serverProtocol == .ftps {
                log(.status, String(localized: "TLS bağlantısı başlatılıyor…"))
                try await stream.startTLS(peerID: peerID) { [weak self] in await self?.verify($0) ?? false }
            }
            log(.status, String(localized: "Bağlantı kuruldu, karşılama mesajı bekleniyor…"))
            let welcome = try await readResponse()
            guard welcome.code == 220 else { throw FTPError.server(code: welcome.code, message: welcome.message) }
            if config.serverProtocol == .ftpes {
                let auth = try await raw("AUTH TLS")
                guard auth.code == 234 else {
                    throw FTPError.tls(String(localized: "Sunucu açık TLS'i (AUTH TLS) desteklemiyor: \(auth.message)"))
                }
                log(.status, String(localized: "TLS bağlantısı başlatılıyor…"))
                try await stream.startTLS(peerID: peerID) { [weak self] in await self?.verify($0) ?? false }
            }
            if tls { log(.status, String(localized: "TLS bağlantısı kuruldu.")) }
            var r = try await raw("USER \(config.user)")
            if r.code == 331 || r.code == 332 { r = try await raw("PASS \(config.password)") }
            guard r.code == 230 || r.code == 202 else { throw FTPError.server(code: r.code, message: r.message) }
            log(.status, String(localized: "Oturum açıldı."))
            if tls {
                try await cmd("PBSZ 0")
                try await cmd("PROT P")
                protectData = true
            }
            let feat = try await raw("FEAT")
            if feat.code == 211 {
                features = Set(feat.lines.dropFirst().dropLast().compactMap {
                    $0.trimmingCharacters(in: .whitespaces).split(separator: " ").first.map { $0.uppercased() }
                })
            } else {
                features = []
            }
            if features.contains("UTF8") { _ = try? await raw("OPTS UTF8 ON") }
            homeDirectory = try await pwd()
        } catch {
            abortConnection()
            throw error
        }
    }

    private func readResponse() async throws -> FTPResponse {
        guard let control else { throw FTPError.notConnected }
        do {
            let first = try await control.readLine()
            guard first.count >= 3, let code = Int(first.prefix(3)) else { throw FTPError.badResponse(first) }
            var lines = [first]
            log(.response, first)
            if first.count > 3 && first[first.index(first.startIndex, offsetBy: 3)] == "-" {
                let terminator = "\(code) "
                while true {
                    let line = try await control.readLine()
                    lines.append(line)
                    log(.response, line)
                    if line.hasPrefix(terminator) || line == "\(code)" { break }
                }
            }
            let response = FTPResponse(code: code, lines: lines)
            if code == 421 { abortConnection() }
            return response
        } catch {
            dropIfFatal(error)
            throw error
        }
    }

    private func raw(_ command: String) async throws -> FTPResponse {
        guard let control else { throw FTPError.notConnected }
        log(.command, command.hasPrefix("PASS ") ? "PASS ********" : command)
        do {
            try await control.send(Data((command + "\r\n").utf8))
        } catch {
            dropIfFatal(error)
            throw error
        }
        return try await readResponse()
    }

    @discardableResult
    private func cmd(_ command: String) async throws -> FTPResponse {
        let r = try await raw(command)
        if r.code >= 400 { throw FTPError.server(code: r.code, message: r.message) }
        return r
    }

    private func setType(_ type: String) async throws {
        guard transferType != type else { return }
        try await cmd("TYPE \(type)")
        transferType = type
    }

    private func pwd() async throws -> String {
        let r = try await cmd("PWD")
        let text = r.lines.first ?? ""
        guard let open = text.firstIndex(of: "\"") else { return "/" }
        var result = ""
        var i = text.index(after: open)
        while i < text.endIndex {
            let c = text[i]
            if c == "\"" {
                let next = text.index(after: i)
                if next < text.endIndex && text[next] == "\"" {
                    result.append("\"")
                    i = text.index(after: next)
                    continue
                }
                break
            }
            result.append(c)
            i = text.index(after: i)
        }
        return result.isEmpty ? "/" : result
    }

    private func openDataConnection() async throws -> SocketStream {
        var host = config.host
        var port: UInt16?
        if useEPSV {
            let r = try await raw("EPSV")
            if r.code == 229, let p = Self.parseEPSV(r.message) { port = p } else { useEPSV = false }
        }
        if port == nil {
            let r = try await cmd("PASV")
            guard let (h, p) = Self.parsePASV(r.message) else { throw FTPError.badResponse(r.message) }
            // Servers behind NAT often advertise an unroutable address.
            if h != "0.0.0.0" && !(Self.isPrivate(h) && !Self.isPrivate(config.host)) { host = h }
            port = p
        }
        let stream = SocketStream(host: host, port: port!, timeout: 30)
        do {
            try await stream.open()
        } catch {
            log(.error, String(localized: "Veri bağlantısı kurulamadı (\(host):\(String(port!)))."))
            throw error
        }
        return stream
    }

    private func readDataCommand(_ command: String) async throws -> FTPResponse? {
        let data = try await openDataConnection()
        defer { data.close() }
        let r = try await raw(command)
        guard r.code == 150 || r.code == 125 else {
            if r.code == 226 || r.code == 250 || r.code == 450 { lastListing = Data(); return r }
            throw FTPError.server(code: r.code, message: r.message)
        }
        try await secureData(data)
        var buffer = Data()
        while let chunk = try await data.receive() { buffer.append(chunk) }
        let done = try await readResponse()
        if done.code >= 400 { throw FTPError.server(code: done.code, message: done.message) }
        lastListing = buffer
        return done
    }

    private var lastListing = Data()

    private func _list(_ path: String) async throws -> (path: String, files: [RemoteFile]) {
        try await cmd("CWD \(path)")
        let cwd = try await pwd()
        try await setType("A")
        var mlsd = features.contains("MLST") || features.contains("MLSD")
        if mlsd {
            do { _ = try await readDataCommand("MLSD") }
            catch let e as FTPError {
                guard case .server(let code, _) = e, code == 500 || code == 502 else { throw e }
                features.remove("MLST"); features.remove("MLSD")
                mlsd = false
            }
        }
        if !mlsd {
            if listArgsSupported {
                do { _ = try await readDataCommand("LIST -a") }
                catch let e as FTPError {
                    guard case .server = e else { throw e }
                    listArgsSupported = false
                }
            }
            if !listArgsSupported { _ = try await readDataCommand("LIST") }
        }
        let text = String(data: lastListing, encoding: .utf8) ?? String(data: lastListing, encoding: .isoLatin1) ?? ""
        return (cwd, ListParser.parse(text, mlsd: mlsd))
    }

    private func _deleteRecursive(_ path: String) async throws {
        let (_, files) = try await _list(path)
        for f in files {
            let child = RemotePath.join(path, f.name)
            if f.isDirectory && !f.isLink {
                try await _deleteRecursive(child)
            } else {
                try await cmd("DELE \(child)")
            }
        }
        try await cmd("CWD \(RemotePath.parent(path))")
        try await cmd("RMD \(path)")
    }

    // MARK: Parsing helpers

    static func parseEPSV(_ text: String) -> UInt16? {
        guard let open = text.firstIndex(of: "("), let close = text.lastIndex(of: ")"), open < close else { return nil }
        let inner = text[text.index(after: open)..<close]
        let digits = inner.filter(\.isNumber)
        return UInt16(digits)
    }

    static func parsePASV(_ text: String) -> (String, UInt16)? {
        let regex = try! NSRegularExpression(pattern: #"(\d+),\s*(\d+),\s*(\d+),\s*(\d+),\s*(\d+),\s*(\d+)"#)
        let ns = text as NSString
        guard let m = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let n = (1...6).map { Int(ns.substring(with: m.range(at: $0))) ?? 0 }
        return ("\(n[0]).\(n[1]).\(n[2]).\(n[3])", UInt16(clamping: n[4] * 256 + n[5]))
    }

    static func isPrivate(_ host: String) -> Bool {
        let p = host.split(separator: ".").compactMap { Int($0) }
        guard p.count == 4 else { return host == "localhost" }
        return p[0] == 10 || p[0] == 127 || (p[0] == 172 && (16...31).contains(p[1]))
            || (p[0] == 192 && p[1] == 168) || (p[0] == 169 && p[1] == 254)
    }
}
