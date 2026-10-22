import AppKit
import FTPKit
import Observation

struct LocalFile: Identifiable, Hashable {
    var id: String { url.path }
    let url: URL
    let name: String
    let isDirectory: Bool
    let isPackage: Bool
    let isHidden: Bool
    let size: Int64
    let modified: Date
    let kind: String
}

extension RemoteFile {
    var kind: String {
        if isDirectory { return String(localized: "Klasör") }
        if isLink { return String(localized: "Bağlantı") }
        return KindCache.kind(forExtension: (name as NSString).pathExtension)
    }
}

/// Directories first, then files, each ordered by the table's sort descriptors.
private func dirsFirst<T>(_ items: [T], isDir: (T) -> Bool, using order: [KeyPathComparator<T>]) -> [T] {
    items.filter(isDir).sorted(using: order) + items.filter { !isDir($0) }.sorted(using: order)
}

@Observable
@MainActor
final class LocalPane {
    var path: URL = FileManager.default.homeDirectoryForCurrentUser
    var pathText = ""
    var files: [LocalFile] = []
    var selection = Set<LocalFile.ID>()
    var sortOrder = [KeyPathComparator(\LocalFile.name, comparator: .localizedStandard)]
    var filter = ""
    var showHidden = false
    var error: String?
    private var history: [URL] = []

    init(path start: URL? = nil) {
        if let start {
            path = start
        } else if let saved = UserDefaults.standard.string(forKey: "lastLocalPath"),
                  FileManager.default.fileExists(atPath: saved) {
            path = URL(fileURLWithPath: saved)
        }
        load()
    }

    var visibleFiles: [LocalFile] {
        var v = showHidden ? files : files.filter { !$0.isHidden }
        if !filter.isEmpty { v = v.filter { $0.name.localizedCaseInsensitiveContains(filter) } }
        return dirsFirst(v, isDir: \.isDirectory, using: sortOrder)
    }

    var selectedFiles: [LocalFile] { files.filter { selection.contains($0.id) } }
    var canGoBack: Bool { !history.isEmpty }

    func load() {
        pathText = path.path
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .isHiddenKey, .fileSizeKey,
                                      .contentModificationDateKey, .localizedTypeDescriptionKey, .isSymbolicLinkKey]
        do {
            let urls = try FileManager.default.contentsOfDirectory(at: path, includingPropertiesForKeys: keys)
            files = urls.map { url in
                var v = try? url.resourceValues(forKeys: Set(keys))
                if v?.isSymbolicLink == true {
                    v = try? url.resolvingSymlinksInPath().resourceValues(forKeys: Set(keys))
                }
                let isDir = v?.isDirectory ?? false
                return LocalFile(url: url, name: url.lastPathComponent, isDirectory: isDir,
                                 isPackage: v?.isPackage ?? false,
                                 isHidden: v?.isHidden ?? url.lastPathComponent.hasPrefix("."),
                                 size: isDir ? 0 : Int64(v?.fileSize ?? 0),
                                 modified: v?.contentModificationDate ?? .distantPast,
                                 kind: isDir && !(v?.isPackage ?? false) ? String(localized: "Klasör")
                                     : (v?.localizedTypeDescription ?? String(localized: "Dosya")))
            }
            error = nil
        } catch {
            files = []
            self.error = error.localizedDescription
        }
        let ids = Set(files.map(\.id))
        selection = selection.intersection(ids)
        UserDefaults.standard.set(path.path, forKey: "lastLocalPath")
    }

    func navigate(to url: URL, recordHistory: Bool = true) {
        let target = url.standardizedFileURL
        guard target != path else { return load() }
        if recordHistory { history.append(path) }
        path = target
        selection = []
        filter = ""
        load()
    }

    func navigate(toText text: String) {
        let expanded = (text as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir), isDir.boolValue {
            navigate(to: URL(fileURLWithPath: expanded))
        } else {
            error = String(localized: "Klasör bulunamadı: \(text)")
            pathText = path.path
        }
    }

    func goUp() { navigate(to: path.deletingLastPathComponent()) }

    func goBack() {
        guard let last = history.popLast() else { return }
        navigate(to: last, recordHistory: false)
    }
}

@Observable
@MainActor
final class RemotePane {
    var path = "/"
    var pathText = "/"
    var files: [RemoteFile] = []
    var selection = Set<RemoteFile.ID>()
    var sortOrder = [KeyPathComparator(\RemoteFile.name, comparator: .localizedStandard)]
    var filter = ""
    var showHidden = true
    var isLoading = false
    var error: String?
    var history: [String] = []

    var visibleFiles: [RemoteFile] {
        var v = showHidden ? files : files.filter { !$0.name.hasPrefix(".") }
        if !filter.isEmpty { v = v.filter { $0.name.localizedCaseInsensitiveContains(filter) } }
        return dirsFirst(v, isDir: \.isDirectory, using: sortOrder)
    }

    var selectedFiles: [RemoteFile] { files.filter { selection.contains($0.id) } }

    func fullPath(_ file: RemoteFile) -> String { RemotePath.join(path, file.name) }

    func reset() {
        path = "/"
        pathText = "/"
        files = []
        selection = []
        filter = ""
        error = nil
        history = []
    }
}
