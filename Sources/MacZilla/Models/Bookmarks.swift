import FTPKit
import Foundation
import Observation

/// A saved pair of folders: where to go locally and on the server.
struct Bookmark: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var localPath = ""
    var remotePath = ""
}

/// Bookmarks per connection: a site's own, or a quick connection's (by address).
@Observable
@MainActor
final class BookmarkStore {
    private(set) var byKey: [String: [Bookmark]] = [:]

    private let fileURL: URL = {
        #if DEBUG
        if let path = ProcessInfo.processInfo.environment["MACZILLA_BOOKMARKS_FILE"] { return URL(fileURLWithPath: path) }
        #endif
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacZilla", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("bookmarks.json")
    }()

    init() {
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String: [Bookmark]].self, from: data) {
            byKey = decoded
        }
    }

    static func key(site: Site.ID) -> String { "site:\(site.uuidString)" }

    /// nil while the tab is not connected.
    static func key(for session: Session) -> String? {
        if let id = session.siteID { return key(site: id) }
        guard let c = session.config else { return nil }
        return "url:\(c.serverProtocol.urlScheme)://\(c.user)@\(c.host):\(c.port)"
    }

    func bookmarks(for key: String?) -> [Bookmark] { key.flatMap { byKey[$0] } ?? [] }

    func add(_ bookmark: Bookmark, for key: String) {
        byKey[key, default: []].append(bookmark)
        save()
    }

    func set(_ list: [Bookmark], for key: String) {
        byKey[key] = list.isEmpty ? nil : list
        save()
    }

    func removeAll(for key: String) {
        guard byKey.removeValue(forKey: key) != nil else { return }
        save()
    }

    private func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(byKey).write(to: fileURL, options: .atomic)
    }
}

extension Session {
    var bookmarkKey: String? { BookmarkStore.key(for: self) }

    func go(to bookmark: Bookmark) {
        if !bookmark.localPath.isEmpty { local.navigate(toText: bookmark.localPath) }
        if !bookmark.remotePath.isEmpty, isConnected { remoteNavigate(bookmark.remotePath) }
    }

    /// Asks for a name and bookmarks the two folders shown now.
    func askAddBookmark() {
        guard let key = bookmarkKey else { return }
        let localPath = local.path.path, remotePath = remote.path
        app.ask(TextPrompt(title: String(localized: "Yer imi ekle"),
                           message: String(localized: "Bu Mac: \(localPath)\nSunucu: \(remotePath)"),
                           confirmTitle: String(localized: "Ekle")) { [weak self] name in
            guard let self else { return }
            let title = name.isEmpty ? RemotePath.name(remotePath) : name
            self.app.bookmarks.add(Bookmark(name: title, localPath: localPath, remotePath: remotePath), for: key)
        }, initial: RemotePath.name(remotePath))
    }
}
