import AppKit
import FTPKit
import Observation

enum ConnectionState: Equatable {
    case disconnected, connecting, connected
}

/// Where a connection request goes: a site or a quick connection.
struct ConnectTarget {
    var config: FTPConfig
    var name: String?
    var siteID: Site.ID?
    var remoteDirectory = ""
    var localDirectory = ""
}

extension FTPConfig {
    /// "user@host" (with the port when it is not the protocol's default).
    var label: String {
        let port = port == serverProtocol.defaultPort ? "" : ":\(port)"
        return "\(user)@\(host)\(port)"
    }
}

enum PaneSide { case local, remote }

/// One tab: a local pane, a remote pane and the browsing connection.
@Observable
@MainActor
final class Session: Identifiable {
    let id = UUID()
    @ObservationIgnored unowned let app: AppModel
    let local: LocalPane
    let remote = RemotePane()

    var state: ConnectionState = .disconnected
    var siteName: String?
    var siteID: Site.ID?
    private(set) var config: FTPConfig?

    /// Directory comparison between the two panes (see Compare.swift).
    var compare = CompareOptions()
    /// The pane the user last worked in; menu commands like Quick Look use it.
    var activePane: PaneSide = .local
    /// This tab's server log: its browsing connection and its transfers.
    var logs: [LogEntry] = []

    @ObservationIgnored private(set) var client: (any RemoteClient)?
    @ObservationIgnored private var keepAlive: Task<Void, Never>?

    init(app: AppModel, localPath: URL? = nil) {
        self.app = app
        local = LocalPane(path: localPath)
    }

    var isConnected: Bool { state == .connected }

    /// Window title and the tab's name.
    var title: String {
        guard let config else { return String(localized: "Yeni sekme") }
        return siteName ?? config.label
    }

    /// Transfers that belong to this tab and have not finished.
    var activeTransfers: Int { app.queue.items.filter { $0.sessionID == id && !$0.status.isFinished }.count }

    func log(_ kind: LogKind, _ text: String) {
        logs.append(LogEntry(kind: kind, text: text))
        if logs.count > 3000 { logs.removeFirst(logs.count - 2500) }
    }

    private func fail(_ title: String, _ error: Error) {
        log(.error, "\(title): \(error.localizedDescription)")
        app.error = ErrorInfo(title: title, message: error.localizedDescription)
    }

    // MARK: Connection

    func connect(_ target: ConnectTarget) {
        if state != .disconnected { disconnect() }
        let cfg = target.config
        siteName = target.name
        siteID = target.siteID
        config = cfg
        if !target.localDirectory.isEmpty { local.navigate(toText: target.localDirectory) }
        let client = makeRemoteClient(config: cfg, log: app.logger(prefix: nil, session: id),
                                      trust: { [weak app] info in await app?.askTrust(info) ?? false })
        self.client = client
        state = .connecting
        remote.reset()
        Task {
            do {
                try await client.connect()
                guard self.client === client else { return }
                state = .connected
                let start = target.remoteDirectory.isEmpty ? client.homeDirectory : target.remoteDirectory
                await loadRemote(start, recordHistory: false)
                startKeepAlive()
            } catch {
                guard self.client === client else { return }
                state = .disconnected
                self.client = nil
                config = nil
                fail(String(localized: "Bağlanılamadı"), error)
            }
        }
    }

    /// Closes the browsing connection and stops this tab's transfers.
    func disconnect() {
        keepAlive?.cancel()
        app.queue.cancel(session: id)
        if let client {
            Task { await client.disconnect() }
        }
        client = nil
        config = nil
        siteName = nil
        siteID = nil
        state = .disconnected
        remote.reset()
        compare.enabled = false
    }

    func reconnect() {
        guard let config else { return }
        connect(ConnectTarget(config: config, name: siteName, siteID: siteID, remoteDirectory: remote.path))
    }

    private func startKeepAlive() {
        keepAlive?.cancel()
        keepAlive = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled, let client = self?.client, client.isConnected else { continue }
                try? await client.noop()
            }
        }
    }

    /// Runs an operation on the browsing connection, reconnecting once if it dropped.
    func withClient<T>(_ op: (any RemoteClient) async throws -> T) async throws -> T {
        guard let client else { throw FTPError.notConnected }
        if !client.isConnected {
            log(.status, String(localized: "Yeniden bağlanılıyor…"))
            try await client.connect()
        }
        do {
            return try await op(client)
        } catch let e as FTPError where e.isConnectionError {
            log(.status, String(localized: "Bağlantı koptu, yeniden bağlanılıyor…"))
            try await client.connect()
            return try await op(client)
        }
    }

    // MARK: Remote browsing

    func loadRemote(_ path: String, recordHistory: Bool = true) async {
        guard client != nil else { return }
        remote.isLoading = true
        defer { remote.isLoading = false }
        do {
            let result = try await withClient { try await $0.list(path) }
            if recordHistory && result.path != remote.path { remote.history.append(remote.path) }
            if result.path != remote.path { remote.filter = "" }
            remote.path = result.path
            remote.pathText = result.path
            remote.files = result.files
            remote.selection = remote.selection.intersection(Set(result.files.map(\.id)))
            remote.error = nil
            log(.status, String(localized: "Dizin listelendi: \(result.path) (\(result.files.count) öğe)"))
        } catch {
            remote.pathText = remote.path
            remote.error = error.localizedDescription
            log(.error, String(localized: "Listelenemedi: \(error.localizedDescription)"))
        }
    }

    func remoteNavigate(_ path: String) { Task { await loadRemote(path) } }
    func remoteRefresh() { Task { await loadRemote(remote.path, recordHistory: false) } }
    func remoteUp() { remoteNavigate(RemotePath.parent(remote.path)) }

    func remoteBack() {
        guard let last = remote.history.popLast() else { return }
        Task { await loadRemote(last, recordHistory: false) }
    }

    func remoteOpen(_ file: RemoteFile) {
        if file.isDirectory {
            remoteNavigate(remote.fullPath(file))
        } else if file.isLink {
            // Could be a directory link; try entering it first.
            Task {
                let path = remote.fullPath(file)
                let before = remote.path
                await loadRemote(path)
                if remote.path == before {
                    remote.error = nil
                    download([file])
                }
            }
        } else {
            download([file])
        }
    }

    func refreshAll() {
        local.load()
        if isConnected { remoteRefresh() }
    }

    // MARK: Transfers

    func download(_ files: [RemoteFile], policy: ExistsPolicy? = nil) {
        guard isConnected, let config else { return }
        app.queue.enqueue(files.map {
            TransferItem(direction: .download, config: config, sessionID: id,
                         localURL: local.path.appendingPathComponent($0.name),
                         remotePath: remote.fullPath($0),
                         isDirectory: $0.isDirectory, size: $0.size, policy: policy,
                         sourceDate: $0.modified, sourcePrecise: $0.preciseTime)
        })
        app.showQueue = true
    }

    func upload(_ urls: [URL], policy: ExistsPolicy? = nil) {
        guard isConnected, let config else {
            app.error = ErrorInfo(title: String(localized: "Bağlı değil"),
                                  message: String(localized: "Dosya yüklemek için önce bir sunucuya bağlanın."))
            return
        }
        app.queue.enqueue(urls.map { url in
            let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            return TransferItem(direction: .upload, config: config, sessionID: id, localURL: url,
                                remotePath: RemotePath.join(remote.path, url.lastPathComponent),
                                isDirectory: v?.isDirectory ?? false, size: Int64(v?.fileSize ?? 0), policy: policy)
        })
        app.showQueue = true
    }

    func uploadSelection() { upload(local.selectedFiles.map(\.url)) }
    func downloadSelection() { download(remote.selectedFiles) }

    /// Downloads a remote file to a temp folder and opens it with its default app.
    func remoteView(_ file: RemoteFile) {
        let path = remote.fullPath(file)
        Task {
            if let url = await fetchToTemp(path, name: file.name, folder: "Open") { NSWorkspace.shared.open(url) }
        }
    }

    /// Downloads `path` over the browsing connection into Caches/MacZilla/<folder>/<random>/name.
    func fetchToTemp(_ path: String, name: String, folder: String) async -> URL? {
        let dir = AppModel.cacheDirectory(folder).appendingPathComponent(String(UUID().uuidString.prefix(8)))
        let dest = dir.appendingPathComponent(name)
        remote.isLoading = true
        defer { remote.isLoading = false }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try await withClient { try await $0.download(path, to: dest) { _ in } }
            return dest
        } catch {
            fail(String(localized: "Dosya açılamadı"), error)
            return nil
        }
    }

    // MARK: Quick Look

    func quickLook(_ file: LocalFile) { app.previewURL = file.url }

    /// Downloads a remote file to the cache and shows it; asks first above the size limit.
    func quickLook(_ file: RemoteFile) {
        guard !file.isDirectory else { return }
        let path = remote.fullPath(file)
        let show: () -> Void = { [weak self] in
            Task {
                guard let self, let url = await self.fetchToTemp(path, name: file.name, folder: "Preview") else { return }
                self.app.previewURL = url
            }
        }
        let limit = Int64(UserDefaults.standard.integer(forKey: Prefs.previewLimitMB)) * 1_048_576
        if limit > 0 && file.size > limit {
            app.confirm = ConfirmRequest(title: String(localized: "\(file.name) indirilip gösterilsin mi?"),
                                         message: String(localized: "Dosya \(Fmt.size(file.size)); önizleme için önce indirilmesi gerekiyor."),
                                         confirmTitle: String(localized: "İndir ve Göster"), action: show)
        } else {
            show()
        }
    }

    /// Quick Look for the selection of the pane in use (⌘Y).
    func quickLookSelection() {
        switch activePane {
        case .local: if let f = local.selectedFiles.first { quickLook(f) }
        case .remote: if let f = remote.selectedFiles.first { quickLook(f) }
        }
    }

    // MARK: Remote file operations

    private func remoteOperation(_ title: String, _ op: @escaping (any RemoteClient) async throws -> Void) {
        Task {
            remote.isLoading = true
            do {
                try await withClient(op)
            } catch {
                fail(title, error)
            }
            remote.isLoading = false
            await loadRemote(remote.path, recordHistory: false)
        }
    }

    func askRemoteNewFolder() {
        app.ask(TextPrompt(title: String(localized: "Yeni klasör"),
                           message: String(localized: "\(remote.path) içinde oluşturulacak klasörün adı:"),
                           confirmTitle: String(localized: "Oluştur")) { [weak self] name in
            guard let self, !name.isEmpty else { return }
            let path = RemotePath.join(self.remote.path, name)
            self.remoteOperation(String(localized: "Klasör oluşturulamadı")) { try await $0.makeDirectory(path) }
        }, initial: String(localized: "Yeni klasör"))
    }

    func askRemoteRename(_ file: RemoteFile) {
        app.ask(TextPrompt(title: String(localized: "Yeniden adlandır"),
                           message: String(localized: "\"\(file.name)\" için yeni ad:"),
                           confirmTitle: String(localized: "Yeniden Adlandır")) { [weak self] name in
            guard let self, !name.isEmpty, name != file.name else { return }
            let from = self.remote.fullPath(file)
            let to = RemotePath.join(self.remote.path, name)
            self.remoteOperation(String(localized: "Yeniden adlandırılamadı")) { try await $0.rename(from, to: to) }
        }, initial: file.name)
    }

    func askRemoteChmod(_ files: [RemoteFile]) {
        guard let first = files.first else { return }
        let what = files.count == 1 ? first.name : String(localized: "\(files.count) öğe")
        app.ask(TextPrompt(title: String(localized: "Dosya izinleri"),
                           message: String(localized: "\(what) için sayısal izin değeri (ör. 644, 755):"),
                           confirmTitle: String(localized: "Uygula")) { [weak self] mode in
            guard let self, mode.count == 3 || mode.count == 4, mode.allSatisfy({ ("0"..."7").contains($0) }) else {
                self?.app.error = ErrorInfo(title: String(localized: "Geçersiz değer"),
                                            message: String(localized: "İzin değeri 3 ya da 4 haneli sekizlik sayı olmalı."))
                return
            }
            let paths = files.map { self.remote.fullPath($0) }
            self.remoteOperation(String(localized: "İzinler değiştirilemedi")) { c in
                for p in paths { try await c.chmod(p, mode: mode) }
            }
        }, initial: Self.octal(first.permissions))
    }

    func askRemoteDelete(_ files: [RemoteFile]) {
        guard !files.isEmpty else { return }
        let what = files.count == 1 ? "\"\(files[0].name)\"" : String(localized: "\(files.count) öğe")
        app.confirm = ConfirmRequest(title: String(localized: "\(what) sunucudan silinsin mi?"),
                                     message: String(localized: "Bu işlem geri alınamaz. Klasörler içerikleriyle birlikte silinir."),
                                     confirmTitle: String(localized: "Sil")) { [weak self] in
            guard let self else { return }
            let targets = files.map { (self.remote.fullPath($0), $0.isDirectory && !$0.isLink) }
            self.remoteOperation(String(localized: "Silinemedi")) { c in
                for (path, isDir) in targets {
                    if isDir { try await c.removeDirectory(path, recursive: true) } else { try await c.deleteFile(path) }
                }
            }
        }
    }

    func copyRemoteURL(_ files: [RemoteFile]) {
        guard let config else { return }
        let port = config.port == config.serverProtocol.defaultPort ? "" : ":\(config.port)"
        let urls = files.map { f -> String in
            let path = remote.fullPath(f).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? remote.fullPath(f)
            return "\(config.serverProtocol.urlScheme)://\(config.user)@\(config.host)\(port)\(path)"
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(urls.joined(separator: "\n"), forType: .string)
    }

    private static func octal(_ perms: String) -> String {
        let p = Array(perms.suffix(9))
        guard p.count == 9 else { return "644" }
        return stride(from: 0, to: 9, by: 3).map { i in
            String((p[i] == "r" ? 4 : 0) + (p[i + 1] == "w" ? 2 : 0) + (p[i + 2] == "x" || p[i + 2] == "s" ? 1 : 0))
        }.joined()
    }

    // MARK: Local file operations

    func localOpen(_ file: LocalFile) {
        if file.isDirectory && !file.isPackage {
            local.navigate(to: file.url)
        } else if isConnected {
            upload([file.url])
        } else {
            NSWorkspace.shared.open(file.url)
        }
    }

    func askLocalNewFolder() {
        app.ask(TextPrompt(title: String(localized: "Yeni klasör"),
                           message: String(localized: "\(local.path.path) içinde oluşturulacak klasörün adı:"),
                           confirmTitle: String(localized: "Oluştur")) { [weak self] name in
            guard let self, !name.isEmpty else { return }
            do {
                try FileManager.default.createDirectory(at: self.local.path.appendingPathComponent(name),
                                                        withIntermediateDirectories: false)
            } catch { self.fail(String(localized: "Klasör oluşturulamadı"), error) }
            self.local.load()
        }, initial: String(localized: "Yeni klasör"))
    }

    func askLocalRename(_ file: LocalFile) {
        app.ask(TextPrompt(title: String(localized: "Yeniden adlandır"),
                           message: String(localized: "\"\(file.name)\" için yeni ad:"),
                           confirmTitle: String(localized: "Yeniden Adlandır")) { [weak self] name in
            guard let self, !name.isEmpty, name != file.name else { return }
            do {
                try FileManager.default.moveItem(at: file.url, to: file.url.deletingLastPathComponent().appendingPathComponent(name))
            } catch { self.fail(String(localized: "Yeniden adlandırılamadı"), error) }
            self.local.load()
        }, initial: file.name)
    }

    func askLocalTrash(_ files: [LocalFile]) {
        guard !files.isEmpty else { return }
        let what = files.count == 1 ? "\"\(files[0].name)\"" : String(localized: "\(files.count) öğe")
        app.confirm = ConfirmRequest(title: String(localized: "\(what) Çöp Sepeti'ne taşınsın mı?"),
                                     message: String(localized: "Öğeler Çöp Sepeti'nden geri alınabilir."),
                                     confirmTitle: String(localized: "Çöp Sepeti'ne Taşı")) { [weak self] in
            NSWorkspace.shared.recycle(files.map(\.url)) { _, err in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        if let err { self?.fail(String(localized: "Taşınamadı"), err) }
                        self?.local.load()
                    }
                }
            }
        }
    }
}
