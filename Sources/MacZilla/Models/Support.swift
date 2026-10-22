import AppKit
import FTPKit
import Security
import UniformTypeIdentifiers

struct LogEntry: Identifiable {
    let id = UUID()
    let date = Date()
    let kind: LogKind
    let text: String
}

enum Fmt {
    static let bytes: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()

    static func size(_ n: Int64) -> String { bytes.string(fromByteCount: n) }

    static let date: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    static func date(_ d: Date) -> String { d == .distantPast ? "—" : date.string(from: d) }

    static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}

/// File icons and kind descriptions, cached by extension.
@MainActor
enum IconCache {
    private static var icons: [String: NSImage] = [:]

    static let folder: NSImage = NSWorkspace.shared.icon(for: .folder)
    static let link: NSImage = NSWorkspace.shared.icon(for: .aliasFile)

    static func icon(forExtension ext: String) -> NSImage {
        let key = ext.lowercased()
        if let i = icons[key] { return i }
        let type = UTType(filenameExtension: key) ?? .data
        let i = NSWorkspace.shared.icon(for: type)
        icons[key] = i
        return i
    }

    static func icon(forLocal url: URL, isDirectory: Bool, isPackage: Bool) -> NSImage {
        if isPackage { return NSWorkspace.shared.icon(forFile: url.path) }
        if isDirectory { return folder }
        return icon(forExtension: url.pathExtension)
    }

}

/// Kind descriptions by extension; usable off the main actor (table sorting).
enum KindCache {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var kinds: [String: String] = [:]

    static func kind(forExtension ext: String) -> String {
        let key = ext.lowercased()
        lock.lock(); defer { lock.unlock() }
        if let k = kinds[key] { return k }
        let k = key.isEmpty ? String(localized: "Dosya") : (UTType(filenameExtension: key)?.localizedDescription ?? String(localized: "Dosya"))
        kinds[key] = k
        return k
    }
}

enum Keychain {
    private static let service: String = {
        #if DEBUG
        if let s = ProcessInfo.processInfo.environment["MACZILLA_KEYCHAIN_SERVICE"] { return s }
        #endif
        return "com.maczilla.sites"
    }()

    static func set(_ password: String, for account: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
        guard !password.isEmpty else { return }
        var add = query
        add[kSecValueData as String] = Data(password.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(_ account: String) -> String {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func delete(_ account: String) { set("", for: account) }
}

struct TextPrompt: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let confirmTitle: String
    let action: (String) -> Void
}

struct ConfirmRequest: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let confirmTitle: String
    let action: () -> Void
}

struct TrustRequest: Identifiable {
    let id = UUID()
    let info: CertificateInfo
}

struct ErrorInfo: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}
