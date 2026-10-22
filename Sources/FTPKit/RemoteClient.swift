import Foundation

public enum LogKind: Sendable {
    case status, command, response, error
}

public enum ServerProtocol: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Plain FTP.
    case ftp
    /// FTP over explicit TLS (AUTH TLS on the normal port).
    case ftpes
    /// FTP over implicit TLS (TLS from the first byte, usually port 990).
    case ftps
    /// SSH File Transfer Protocol.
    case sftp

    public var id: String { rawValue }

    public var defaultPort: UInt16 {
        switch self {
        case .ftp, .ftpes: return 21
        case .ftps: return 990
        case .sftp: return 22
        }
    }

    public var shortName: String {
        switch self {
        case .ftp: return "FTP"
        case .ftpes: return "FTPES"
        case .ftps: return "FTPS"
        case .sftp: return "SFTP"
        }
    }

    public var title: String {
        switch self {
        case .ftp: return String(localized: "FTP – şifrelenmemiş")
        case .ftpes: return String(localized: "FTPES – açık TLS (AUTH TLS)")
        case .ftps: return String(localized: "FTPS – örtük TLS")
        case .sftp: return String(localized: "SFTP – SSH dosya aktarımı")
        }
    }

    public var isEncrypted: Bool { self != .ftp }

    public var urlScheme: String {
        switch self {
        case .ftp: return "ftp"
        case .ftpes: return "ftpes"
        case .ftps: return "ftps"
        case .sftp: return "sftp"
        }
    }

    public init?(scheme: String) {
        switch scheme.lowercased() {
        case "ftp": self = .ftp
        case "ftpes": self = .ftpes
        case "ftps": self = .ftps
        case "sftp", "ssh": self = .sftp
        default: return nil
        }
    }
}

public struct FTPConfig: Sendable, Hashable {
    public var host: String
    public var port: UInt16
    public var user: String
    public var password: String
    public var serverProtocol: ServerProtocol
    /// SFTP: private key file; empty uses ssh's defaults and agent.
    public var keyFile: String
    /// SFTP: extra `-o` style arguments passed to ssh.
    public var sshOptions: [String]

    public init(host: String, port: UInt16? = nil, user: String = "", password: String = "",
                serverProtocol: ServerProtocol = .ftp, keyFile: String = "", sshOptions: [String] = []) {
        self.host = host
        self.serverProtocol = serverProtocol
        self.port = port ?? serverProtocol.defaultPort
        if user.isEmpty {
            self.user = serverProtocol == .sftp ? NSUserName() : "anonymous"
        } else {
            self.user = user
        }
        self.password = password
        self.keyFile = keyFile
        self.sshOptions = sshOptions
    }
}

/// A file-transfer session. All methods may be called from multiple tasks.
public protocol RemoteClient: AnyObject, Sendable {
    var config: FTPConfig { get }
    var isConnected: Bool { get }
    var homeDirectory: String { get }

    func connect() async throws
    func disconnect() async
    /// Lists `path`; returns the canonical path reported by the server.
    func list(_ path: String) async throws -> (path: String, files: [RemoteFile])
    func makeDirectory(_ path: String) async throws
    func deleteFile(_ path: String) async throws
    func removeDirectory(_ path: String, recursive: Bool) async throws
    func rename(_ from: String, to: String) async throws
    func chmod(_ path: String, mode: String) async throws
    /// Size of a remote file, or nil if it does not exist.
    func size(_ path: String) async throws -> Int64?
    /// Exact modification time of a remote file, or nil if the server cannot tell.
    func modified(_ path: String) async throws -> Date?
    /// Sets a remote file's modification time; false if the server does not support it.
    func setModified(_ path: String, to date: Date) async throws -> Bool
    func noop() async throws
    func download(_ remotePath: String, to localURL: URL, progress: @escaping @Sendable (Int64) -> Void) async throws
    func upload(_ localURL: URL, to remotePath: String, progress: @escaping @Sendable (Int64) -> Void) async throws
}

public func makeRemoteClient(config: FTPConfig,
                             log: @escaping @Sendable (LogKind, String) -> Void,
                             trust: TrustHandler? = nil) -> any RemoteClient {
    switch config.serverProtocol {
    case .sftp: return SFTPClient(config: config, log: log)
    case .ftp, .ftpes, .ftps: return FTPClient(config: config, log: log, trust: trust)
    }
}

/// Calls the handler at most ~8 times a second, plus a final call.
final class ProgressThrottle: @unchecked Sendable {
    private let handler: @Sendable (Int64) -> Void
    private var last = Date.distantPast
    init(_ handler: @escaping @Sendable (Int64) -> Void) { self.handler = handler }
    func report(_ value: Int64) {
        let now = Date()
        if now.timeIntervalSince(last) > 0.12 {
            last = now
            handler(value)
        }
    }
    func finish(_ value: Int64) { handler(value) }
}
