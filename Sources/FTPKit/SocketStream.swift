import CryptoKit
import Darwin
import Foundation
import Security

public enum FTPError: LocalizedError {
    case connectionFailed(String)
    case connectionClosed
    case timeout
    case badResponse(String)
    case server(code: Int, message: String)
    case notConnected
    case tls(String)
    case local(String)

    public var errorDescription: String? {
        switch self {
        case .connectionFailed(let m): return String(localized: "Bağlantı hatası: \(m)")
        case .connectionClosed: return String(localized: "Sunucu bağlantıyı kapattı.")
        case .timeout: return String(localized: "Zaman aşımı.")
        case .badResponse(let m): return String(localized: "Geçersiz sunucu yanıtı: \(m)")
        case .server(let code, let m): return String(localized: "Sunucu hatası \(String(code)): \(m)")
        case .notConnected: return String(localized: "Sunucuya bağlı değil.")
        case .tls(let m): return String(localized: "TLS hatası: \(m)")
        case .local(let m): return m
        }
    }

    /// Errors after which the control connection is unusable.
    public var isConnectionError: Bool {
        switch self {
        case .connectionFailed, .connectionClosed, .timeout, .notConnected: return true
        case .server(let code, _): return code == 421
        default: return false
        }
    }
}

/// What the user is shown when a server certificate is not trusted by macOS.
public struct CertificateInfo: Sendable, Hashable {
    public let host: String
    public let subject: String
    public let fingerprint: String
    public let problem: String
}

/// Asked whether to accept an untrusted certificate; return true to continue.
public typealias TrustHandler = @Sendable (CertificateInfo) async -> Bool

/// FIFO async mutex; FTP control connections must run one command at a time.
actor AsyncLock {
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !locked { locked = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty { locked = false } else { waiters.removeFirst().resume() }
    }
}

/// Blocking BSD socket driven from a private queue, with optional TLS
/// (SecureTransport, so data connections can resume the control session).
final class SocketStream: @unchecked Sendable {
    let host: String
    let port: UInt16
    let timeout: TimeInterval
    fileprivate var fd: Int32 = -1
    private let queue = DispatchQueue(label: "maczilla.socket")
    private let closeLock = NSLock()
    private var closed = false
    private var ssl: SSLContext?
    private var buffer = Data()
    private var eof = false

    var isSecure: Bool { ssl != nil }

    init(host: String, port: UInt16, timeout: TimeInterval) {
        self.host = host
        self.port = port
        self.timeout = timeout
    }

    deinit {
        if fd >= 0 { Darwin.close(fd) }
    }

    private func onQueue<T>(_ body: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            queue.async { cont.resume(with: Result { try body() }) }
        }
    }

    // MARK: Connect

    func open() async throws {
        try await onQueue { try self.connectBlocking() }
    }

    private func connectBlocking() throws {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP
        var res: UnsafeMutablePointer<addrinfo>?
        let rc = getaddrinfo(host, String(port), &hints, &res)
        guard rc == 0, let first = res else {
            throw FTPError.connectionFailed(String(localized: "\(host) çözümlenemedi (\(String(cString: gai_strerror(rc))))"))
        }
        defer { freeaddrinfo(first) }

        var lastError = String(localized: "bağlanılamadı")
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let ai = cursor {
            cursor = ai.pointee.ai_next
            let s = socket(ai.pointee.ai_family, ai.pointee.ai_socktype, ai.pointee.ai_protocol)
            guard s >= 0 else { continue }
            let flags = fcntl(s, F_GETFL)
            _ = fcntl(s, F_SETFL, flags | O_NONBLOCK)
            var ok = Darwin.connect(s, ai.pointee.ai_addr, ai.pointee.ai_addrlen) == 0
            var err = errno
            if !ok && err == EINPROGRESS {
                var pfd = pollfd(fd: s, events: Int16(POLLOUT), revents: 0)
                let pr = poll(&pfd, 1, Int32(timeout * 1000))
                if pr == 1 {
                    var soErr: Int32 = 0
                    var len = socklen_t(MemoryLayout<Int32>.size)
                    getsockopt(s, SOL_SOCKET, SO_ERROR, &soErr, &len)
                    ok = soErr == 0
                    err = soErr
                } else {
                    err = ETIMEDOUT
                }
            }
            if ok {
                _ = fcntl(s, F_SETFL, flags)
                configure(s)
                fd = s
                return
            }
            lastError = String(cString: strerror(err))
            Darwin.close(s)
        }
        throw FTPError.connectionFailed(lastError)
    }

    private func configure(_ s: Int32) {
        var one: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(s, SOL_SOCKET, SO_KEEPALIVE, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(s, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    // MARK: TLS

    /// Performs a client TLS handshake. `peerID` keys the session cache, so
    /// data connections using the control connection's ID resume its session.
    func startTLS(peerID: String, verify: @escaping (SecTrust) async -> Bool) async throws {
        try await onQueue { try self.setupTLS(peerID: peerID) }
        while true {
            let status: OSStatus = try await onQueue {
                guard let ssl = self.ssl else { throw FTPError.connectionClosed }
                return SSLHandshake(ssl)
            }
            switch status {
            case noErr:
                return
            case errSSLPeerAuthCompleted:
                guard let ssl else { throw FTPError.connectionClosed }
                var trust: SecTrust?
                SSLCopyPeerTrust(ssl, &trust)
                guard let trust, await verify(trust) else {
                    close()
                    throw FTPError.tls(String(localized: "Sunucu sertifikası reddedildi."))
                }
            case errSSLWouldBlock:
                throw FTPError.timeout
            default:
                close()
                throw FTPError.tls(Self.describe(status))
            }
        }
    }

    private func setupTLS(peerID: String) throws {
        guard let ctx = SSLCreateContext(nil, .clientSide, .streamType) else {
            throw FTPError.tls(String(localized: "TLS bağlamı oluşturulamadı."))
        }
        SSLSetIOFuncs(ctx, socketRead, socketWrite)
        SSLSetConnection(ctx, Unmanaged.passUnretained(self).toOpaque())
        SSLSetProtocolVersionMin(ctx, .tlsProtocol12)
        SSLSetSessionOption(ctx, .breakOnServerAuth, true)
        if host.rangeOfCharacter(from: .letters) != nil {
            SSLSetPeerDomainName(ctx, host, host.utf8.count)
        }
        let id = Array(peerID.utf8)
        SSLSetPeerID(ctx, id, id.count)
        ssl = ctx
    }

    static func describe(_ status: OSStatus) -> String {
        if let s = SecCopyErrorMessageString(status, nil) as String? { return "\(s) (\(status))" }
        return "kod \(status)"
    }

    /// Fills in certificate details and macOS's own verdict for a peer trust.
    static func inspect(_ trust: SecTrust, host: String) -> (trusted: Bool, info: CertificateInfo) {
        SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, host as CFString))
        var error: CFError?
        let trusted = SecTrustEvaluateWithError(trust, &error)
        let chain = (SecTrustCopyCertificateChain(trust) as? [SecCertificate]) ?? []
        let leaf = chain.first
        let subject = leaf.flatMap { SecCertificateCopySubjectSummary($0) as String? } ?? "bilinmiyor"
        let fingerprint = leaf.map { cert -> String in
            let digest = SHA256.hash(data: SecCertificateCopyData(cert) as Data)
            return digest.map { String(format: "%02X", $0) }.joined(separator: ":")
        } ?? ""
        let problem = error.map { CFErrorCopyDescription($0) as String } ?? ""
        return (trusted, CertificateInfo(host: host, subject: subject, fingerprint: fingerprint, problem: problem))
    }

    // MARK: I/O

    /// Next chunk of bytes, or nil at end of stream.
    func receive(maximum: Int = 256 * 1024) async throws -> Data? {
        if !buffer.isEmpty {
            let d = buffer
            buffer = Data()
            return d
        }
        if eof { return nil }
        return try await onQueue { try self.readBlocking(maximum) }
    }

    private func readBlocking(_ maximum: Int) throws -> Data? {
        if eof { return nil }
        var data = Data(count: maximum)
        if let ssl {
            var processed = 0
            let status = data.withUnsafeMutableBytes { SSLRead(ssl, $0.baseAddress!, maximum, &processed) }
            if status == errSSLClosedGraceful || status == errSSLClosedNoNotify || status == errSSLClosedAbort {
                eof = true
            }
            if processed > 0 { return data.prefix(processed) }
            if eof { return nil }
            if status == errSSLWouldBlock { throw FTPError.timeout }
            throw status == noErr ? FTPError.connectionClosed : FTPError.tls(Self.describe(status))
        }
        while true {
            let n = data.withUnsafeMutableBytes { Darwin.recv(fd, $0.baseAddress!, maximum, 0) }
            if n > 0 { return data.prefix(n) }
            if n == 0 { eof = true; return nil }
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK { throw FTPError.timeout }
            throw FTPError.connectionFailed(String(cString: strerror(errno)))
        }
    }

    func readLine() async throws -> String {
        while true {
            if let idx = buffer.firstIndex(of: 0x0A) {
                var line = buffer[buffer.startIndex..<idx]
                buffer = Data(buffer[buffer.index(after: idx)...])
                if line.last == 0x0D { line = line.dropLast() }
                return String(data: line, encoding: .utf8) ?? String(data: line, encoding: .isoLatin1) ?? ""
            }
            guard let chunk = try await onQueue({ try self.readBlocking(64 * 1024) }) else {
                throw FTPError.connectionClosed
            }
            buffer.append(chunk)
        }
    }

    func send(_ data: Data) async throws {
        try await onQueue { try self.writeBlocking(data) }
    }

    private func writeBlocking(_ data: Data) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            if let ssl {
                var offset = 0
                while offset < raw.count {
                    var processed = 0
                    let status = SSLWrite(ssl, base + offset, raw.count - offset, &processed)
                    offset += processed
                    if status != noErr && processed == 0 {
                        throw status == errSSLWouldBlock ? FTPError.timeout : FTPError.tls(Self.describe(status))
                    }
                }
            } else {
                try socketWriteAll(fd, base, raw.count)
            }
        }
    }

    /// Ends the upload stream (TLS close_notify, then TCP FIN).
    func finishSending() async {
        _ = try? await onQueue {
            if let ssl = self.ssl { SSLClose(ssl) }
            Darwin.shutdown(self.fd, SHUT_WR)
        }
    }

    /// Safe from any thread; unblocks a pending read.
    func close() {
        closeLock.lock()
        defer { closeLock.unlock() }
        guard !closed else { return }
        closed = true
        if fd >= 0 { Darwin.shutdown(fd, SHUT_RDWR) }
    }
}

fileprivate func socketWriteAll(_ fd: Int32, _ base: UnsafeRawPointer, _ count: Int) throws {
    var offset = 0
    while offset < count {
        let n = Darwin.send(fd, base + offset, count - offset, 0)
        if n > 0 { offset += n; continue }
        if n < 0 && errno == EINTR { continue }
        if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { throw FTPError.timeout }
        throw FTPError.connectionFailed(String(cString: strerror(errno)))
    }
}

private func socketRead(_ conn: SSLConnectionRef, _ data: UnsafeMutableRawPointer,
                        _ length: UnsafeMutablePointer<Int>) -> OSStatus {
    let stream = Unmanaged<SocketStream>.fromOpaque(conn).takeUnretainedValue()
    let wanted = length.pointee
    var got = 0
    while got < wanted {
        let n = Darwin.recv(stream.fd, data + got, wanted - got, 0)
        if n > 0 { got += n; continue }
        length.pointee = got
        if n == 0 { return errSSLClosedNoNotify }
        if errno == EINTR { continue }
        if errno == EAGAIN || errno == EWOULDBLOCK { return errSSLWouldBlock }
        return errSSLClosedAbort
    }
    length.pointee = got
    return noErr
}

private func socketWrite(_ conn: SSLConnectionRef, _ data: UnsafeRawPointer,
                         _ length: UnsafeMutablePointer<Int>) -> OSStatus {
    let stream = Unmanaged<SocketStream>.fromOpaque(conn).takeUnretainedValue()
    do {
        try socketWriteAll(stream.fd, data, length.pointee)
        return noErr
    } catch FTPError.timeout {
        length.pointee = 0
        return errSSLWouldBlock
    } catch {
        length.pointee = 0
        return errSSLClosedAbort
    }
}
