import AppKit
import FTPKit
import Observation

/// Remote files opened for editing: each is a local copy that is uploaded
/// back to its server whenever it is saved.
@Observable
@MainActor
final class EditWatcher {
    struct Entry: Identifiable {
        let id = UUID()
        let localURL: URL
        let remotePath: String
        let config: FTPConfig
        let sessionID: UUID?
        var modified: Date
        var size: Int64
        /// A change seen on the last check; uploaded once it stops changing.
        var pending: (Date, Int64)?
        var uploads = 0
    }

    private(set) var entries: [Entry] = []
    @ObservationIgnored var queue: TransferQueue?
    @ObservationIgnored var onUpload: ((Entry) -> Void)?
    @ObservationIgnored private var timer: Timer?

    func watch(_ localURL: URL, remotePath: String, config: FTPConfig, sessionID: UUID?) {
        let (date, size) = Self.stamp(localURL)
        entries.removeAll { $0.localURL == localURL }
        entries.append(Entry(localURL: localURL, remotePath: remotePath, config: config, sessionID: sessionID,
                             modified: date, size: size))
        startTimer()
    }

    func stop(_ id: Entry.ID) {
        entries.removeAll { $0.id == id }
        if entries.isEmpty { timer?.invalidate(); timer = nil }
    }

    func stopAll() {
        entries.removeAll()
        timer?.invalidate()
        timer = nil
    }

    private func startTimer() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func poll() {
        for i in entries.indices {
            let e = entries[i]
            guard FileManager.default.fileExists(atPath: e.localURL.path) else { continue }
            let (date, size) = Self.stamp(e.localURL)
            guard date != e.modified || size != e.size else {
                entries[i].pending = nil
                continue
            }
            // Editors may write in several steps; wait until a check sees no change.
            if let p = e.pending, p.0 == date, p.1 == size {
                entries[i].modified = date
                entries[i].size = size
                entries[i].pending = nil
                entries[i].uploads += 1
                queue?.enqueue([TransferItem(direction: .upload, config: e.config, sessionID: e.sessionID,
                                             localURL: e.localURL, remotePath: e.remotePath,
                                             isDirectory: false, size: size, policy: .overwrite)])
                onUpload?(entries[i])
            } else {
                entries[i].pending = (date, size)
            }
        }
    }

    private static func stamp(_ url: URL) -> (Date, Int64) {
        let v = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        return (v?.contentModificationDate ?? .distantPast, Int64(v?.fileSize ?? 0))
    }
}

extension Session {
    /// Downloads a copy, opens it (in `app` or the default editor) and
    /// uploads it again each time it is saved.
    func editRemote(_ file: RemoteFile, with appURL: URL? = nil) {
        guard let config else { return }
        let path = remote.fullPath(file)
        Task {
            guard let url = await fetchToTemp(path, name: file.name, folder: "Edit") else { return }
            app.edits.watch(url, remotePath: path, config: config, sessionID: id)
            log(.status, String(localized: "Düzenleniyor: \(path). Kaydettiğinizde sunucuya yüklenecek."))
            if let appURL {
                NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration(),
                                        completionHandler: nil)
            } else {
                NSWorkspace.shared.open(url)
            }
        }
    }

    func editRemoteWithChosenApp(_ file: RemoteFile) {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.prompt = String(localized: "Düzenle")
        if panel.runModal() == .OK, let appURL = panel.url { editRemote(file, with: appURL) }
    }
}
