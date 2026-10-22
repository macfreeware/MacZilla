import FTPKit
import Foundation
import Observation

struct Site: Codable, Identifiable, Hashable {
    var id = UUID()
    var name = String(localized: "Yeni site")
    var host = ""
    var port = 21
    var user = ""
    var serverProtocol: ServerProtocol = .ftp
    var anonymous = false
    var keyFile = ""
    var remoteDirectory = ""
    var localDirectory = ""
    var notes = ""
    /// Site Manager folder; nested folders are written "A / B".
    var folder = ""
    var lastUsed: Date?

    init() {}

    init(name: String) { self.name = name }

    // Tolerates sites.json files written before newer fields existed.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Site"
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? ""
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? 21
        user = try c.decodeIfPresent(String.self, forKey: .user) ?? ""
        serverProtocol = try c.decodeIfPresent(ServerProtocol.self, forKey: .serverProtocol) ?? .ftp
        anonymous = try c.decodeIfPresent(Bool.self, forKey: .anonymous) ?? false
        keyFile = try c.decodeIfPresent(String.self, forKey: .keyFile) ?? ""
        remoteDirectory = try c.decodeIfPresent(String.self, forKey: .remoteDirectory) ?? ""
        localDirectory = try c.decodeIfPresent(String.self, forKey: .localDirectory) ?? ""
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        folder = try c.decodeIfPresent(String.self, forKey: .folder) ?? ""
        lastUsed = try c.decodeIfPresent(Date.self, forKey: .lastUsed)
    }

    var password: String {
        get { Keychain.get(id.uuidString) }
        nonmutating set { Keychain.set(newValue, for: id.uuidString) }
    }

    var target: ConnectTarget {
        let anonymous = anonymous && serverProtocol != .sftp
        let cfg = FTPConfig(host: host, port: UInt16(clamping: port),
                            user: anonymous ? "anonymous" : user,
                            password: anonymous ? "maczilla@" : password,
                            serverProtocol: serverProtocol, keyFile: keyFile)
        return ConnectTarget(config: cfg, name: name, siteID: id,
                             remoteDirectory: remoteDirectory, localDirectory: localDirectory)
    }
}

@Observable
@MainActor
final class SiteStore {
    private(set) var sites: [Site] = []

    private let fileURL: URL = {
        #if DEBUG
        if let path = ProcessInfo.processInfo.environment["MACZILLA_SITES_FILE"] { return URL(fileURLWithPath: path) }
        #endif
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacZilla", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("sites.json")
    }()

    init() {
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([Site].self, from: data) {
            sites = decoded
        }
    }

    var recent: [Site] {
        sites.filter { $0.lastUsed != nil }.sorted { $0.lastUsed! > $1.lastUsed! }.prefix(5).map { $0 }
    }

    /// Folder names in use, sorted; "" (no folder) is not included.
    var folders: [String] {
        Array(Set(sites.map(\.folder).filter { !$0.isEmpty })).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Sites grouped by folder: the unfiled ones first, then each folder.
    var grouped: [(folder: String, sites: [Site])] {
        let byName = { (a: Site, b: Site) in a.name.localizedStandardCompare(b.name) == .orderedAscending }
        var out: [(String, [Site])] = []
        let loose = sites.filter { $0.folder.isEmpty }
        if !loose.isEmpty { out.append(("", loose)) }
        for f in folders { out.append((f, sites.filter { $0.folder == f }.sorted(by: byName))) }
        return out
    }

    func site(_ id: Site.ID?) -> Site? { sites.first { $0.id == id } }

    @discardableResult
    func add(_ site: Site = Site()) -> Site {
        sites.append(site)
        save()
        return site
    }

    /// Adds imported sites in one save; passwords go to the Keychain.
    func add(contentsOf new: [(site: Site, password: String)]) {
        sites.append(contentsOf: new.map(\.site))
        for (site, password) in new where !password.isEmpty { site.password = password }
        save()
    }

    /// Saves a quick connection as a site and returns it.
    func add(from config: FTPConfig, name: String, remoteDirectory: String = "") -> Site {
        var site = Site(name: name)
        site.host = config.host
        site.port = Int(config.port)
        site.serverProtocol = config.serverProtocol
        site.anonymous = config.serverProtocol != .sftp && config.user == "anonymous"
        site.user = site.anonymous ? "" : config.user
        site.keyFile = config.keyFile
        site.remoteDirectory = remoteDirectory
        site.lastUsed = Date()
        add(site)
        if !site.anonymous { site.password = config.password }
        return site
    }

    func update(_ site: Site) {
        guard let i = sites.firstIndex(where: { $0.id == site.id }), sites[i] != site else { return }
        sites[i] = site
        save()
    }

    /// A typed folder name in stored form: "A/B" and "A / B" both nest B in A.
    static func folderName(_ text: String) -> String {
        text.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            .joined(separator: " / ")
    }

    /// Renames a folder and the folders nested in it.
    func renameFolder(_ old: String, to new: String) {
        guard !old.isEmpty, !new.isEmpty, old != new else { return }
        var changed = false
        for i in sites.indices where sites[i].folder == old || sites[i].folder.hasPrefix(old + " / ") {
            sites[i].folder = new + sites[i].folder.dropFirst(old.count)
            changed = true
        }
        if changed { save() }
    }

    func remove(_ id: Site.ID) {
        Keychain.delete(id.uuidString)
        sites.removeAll { $0.id == id }
        save()
    }

    func markUsed(_ id: Site.ID) {
        guard let i = sites.firstIndex(where: { $0.id == id }) else { return }
        sites[i].lastUsed = Date()
        save()
    }

    private func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(sites).write(to: fileURL, options: .atomic)
    }
}
