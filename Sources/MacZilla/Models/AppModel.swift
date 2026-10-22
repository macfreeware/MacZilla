import AppKit
import FTPKit
import Observation

/// App-wide state: the tabs, the shared transfer queue, dialogs and
/// certificate trust. Each tab's connection and log live in its `Session`.
@Observable
@MainActor
final class AppModel {
    let queue = TransferQueue()
    let edits = EditWatcher()
    let bookmarks = BookmarkStore()

    private(set) var sessions: [Session] = []
    var currentID: Session.ID

    var quickProtocol: ServerProtocol = .ftp
    var quickHost = ""
    var quickUser = ""
    var quickPassword = ""
    var quickPort = ""

    var showLog = true
    var showQueue = true
    var showSiteManager = false
    var showBookmarks = false
    var showSync = false

    var prompt: TextPrompt?
    var promptText = ""
    var confirm: ConfirmRequest?
    var error: ErrorInfo?
    var trustRequest: TrustRequest?
    /// A connection waiting for "new tab or this tab?".
    var pendingConnect: ConnectTarget?
    /// The file shown in the Quick Look panel.
    var previewURL: URL?
    var availableUpdate: UpdateChecker.Release?

    @ObservationIgnored private var sessionTrusted = Set<String>()
    @ObservationIgnored private var trustWaiters: [String: [CheckedContinuation<Bool, Never>]] = [:]
    @ObservationIgnored private var trustBacklog: [CertificateInfo] = []
    @ObservationIgnored private var localRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var remoteRefreshTask: Task<Void, Never>?

    init() {
        currentID = UUID()
        let first = Session(app: self)
        sessions = [first]
        currentID = first.id
        queue.makeLogger = { [weak self] prefix, sessionID in
            self?.logger(prefix: prefix, session: sessionID) ?? { _, _ in }
        }
        queue.onFinished = { [weak self] item in self?.transferFinished(item) }
        queue.onIdle = { [weak self] batch in self?.transfersIdle(batch) }
        queue.trust = { [weak self] info in await self?.askTrust(info) ?? false }
        edits.queue = queue
        edits.onUpload = { [weak self] e in
            self?.log(.status, String(localized: "Değişiklik kaydedildi, yükleniyor: \(e.remotePath)"), session: e.sessionID)
            self?.showQueue = true
        }
        if let saved = UserDefaults.standard.dictionary(forKey: "quickConnect") as? [String: String] {
            quickHost = saved["host"] ?? ""
            quickUser = saved["user"] ?? ""
            quickPort = saved["port"] ?? ""
            quickProtocol = saved["protocol"].flatMap(ServerProtocol.init(rawValue:)) ?? .ftp
        }
    }

    var current: Session { sessions.first { $0.id == currentID } ?? sessions[0] }

    // MARK: Tabs

    /// Opens a tab next to the current one, or after the last (the strip's "+").
    @discardableResult
    func newTab(select: Bool = true, atEnd: Bool = false) -> Session {
        let s = Session(app: self, localPath: current.local.path)
        if !atEnd, let i = sessions.firstIndex(where: { $0.id == currentID }) {
            sessions.insert(s, at: i + 1)
        } else {
            sessions.append(s)
        }
        if select { currentID = s.id }
        return s
    }

    func select(_ session: Session) { currentID = session.id }

    func selectAdjacentTab(_ offset: Int) {
        guard let i = sessions.firstIndex(where: { $0.id == currentID }), sessions.count > 1 else { return }
        currentID = sessions[(i + offset + sessions.count) % sessions.count].id
    }

    /// Closes a tab, asking first if it still has transfers running.
    func askCloseTab(_ session: Session) {
        let active = session.activeTransfers
        guard active > 0 else { return closeTab(session) }
        confirm = ConfirmRequest(title: String(localized: "\(session.title) sekmesi kapatılsın mı?"),
                                 message: String(localized: "Bu bağlantının \(active) aktarımı durdurulacak."),
                                 confirmTitle: String(localized: "Sekmeyi Kapat")) { [weak self] in
            self?.closeTab(session)
        }
    }

    private func closeTab(_ session: Session) {
        session.disconnect()
        guard let i = sessions.firstIndex(where: { $0.id == session.id }) else { return }
        if sessions.count == 1 { return } // the last tab only disconnects
        sessions.remove(at: i)
        if currentID == session.id { currentID = sessions[min(i, sessions.count - 1)].id }
    }

    func askDisconnect(_ session: Session) {
        let active = session.activeTransfers
        guard active > 0 else { return session.disconnect() }
        confirm = ConfirmRequest(title: String(localized: "Bağlantı kesilsin mi?"),
                                 message: String(localized: "Bu bağlantının \(active) aktarımı durdurulacak."),
                                 confirmTitle: String(localized: "Bağlantıyı Kes")) { session.disconnect() }
    }

    // MARK: Logging

    /// Adds a line to a tab's log; `nil` means the tab in front. Lines for a
    /// tab that has been closed are dropped.
    func log(_ kind: LogKind, _ text: String, session id: Session.ID?) {
        guard let id else { return current.log(kind, text) }
        sessions.first { $0.id == id }?.log(kind, text)
    }

    nonisolated func logger(prefix: String?, session id: Session.ID?) -> @Sendable (LogKind, String) -> Void {
        { [weak self] kind, text in
            let line = prefix.map { "[\($0)] \(text)" } ?? text
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.log(kind, line, session: id) } }
        }
    }

    func ask(_ p: TextPrompt, initial: String) {
        promptText = initial
        prompt = p
    }

    // MARK: Certificate trust

    private static let trustedKey = "trustedCertificates"

    /// Called by any connection (browsing or transfer) that meets an
    /// untrusted certificate; concurrent asks for one certificate share a prompt.
    nonisolated func askTrust(_ info: CertificateInfo) async -> Bool {
        await withCheckedContinuation { cont in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.enqueueTrust(info, cont) }
            }
        }
    }

    private func enqueueTrust(_ info: CertificateInfo, _ cont: CheckedContinuation<Bool, Never>) {
        let saved = UserDefaults.standard.dictionary(forKey: Self.trustedKey) as? [String: [String]] ?? [:]
        if sessionTrusted.contains(info.fingerprint) || saved[info.host]?.contains(info.fingerprint) == true {
            cont.resume(returning: true)
            return
        }
        if trustWaiters[info.fingerprint] != nil {
            trustWaiters[info.fingerprint]!.append(cont)
            return
        }
        trustWaiters[info.fingerprint] = [cont]
        if trustRequest == nil { trustRequest = TrustRequest(info: info) } else { trustBacklog.append(info) }
    }

    enum TrustDecision { case always, once, reject }

    /// Only an explicit button press may accept; any other way the prompt
    /// goes away (closing, quitting) ends up in `trustPromptDismissed`, which rejects.
    func resolveTrust(_ request: TrustRequest, _ decision: TrustDecision) {
        let info = request.info
        guard let waiters = trustWaiters.removeValue(forKey: info.fingerprint) else { return }
        switch decision {
        case .always:
            var saved = UserDefaults.standard.dictionary(forKey: Self.trustedKey) as? [String: [String]] ?? [:]
            saved[info.host, default: []].append(info.fingerprint)
            UserDefaults.standard.set(saved, forKey: Self.trustedKey)
            sessionTrusted.insert(info.fingerprint)
            logTrust(.status, String(localized: "Sertifikaya kalıcı olarak güvenildi: \(info.host)"), host: info.host)
        case .once:
            sessionTrusted.insert(info.fingerprint)
            logTrust(.status, String(localized: "Sertifikaya bu oturum için güvenildi: \(info.host)"), host: info.host)
        case .reject:
            logTrust(.error, String(localized: "Sertifika reddedildi: \(info.host)"), host: info.host)
        }
        waiters.forEach { $0.resume(returning: decision != .reject) }
        if trustRequest?.id == request.id { trustRequest = nil }
    }

    /// A trust decision goes to the tabs connected to that server.
    private func logTrust(_ kind: LogKind, _ text: String, host: String) {
        let tabs = sessions.filter { $0.config?.host == host }
        (tabs.isEmpty ? [current] : tabs).forEach { $0.log(kind, text) }
    }

    func trustPromptDismissed(_ request: TrustRequest?) {
        if let request { resolveTrust(request, .reject) }
        guard trustRequest == nil, !trustBacklog.isEmpty else { return }
        let next = trustBacklog.removeFirst()
        // Present after the previous sheet has finished closing.
        DispatchQueue.main.async { MainActor.assumeIsolated { self.trustRequest = TrustRequest(info: next) } }
    }

    // MARK: Connecting

    func quickConnect() {
        var host = quickHost.trimmingCharacters(in: .whitespaces)
        var user = quickUser
        var password = quickPassword
        var port = UInt16(quickPort)
        // Accept ftp://, ftpes://, ftps://, sftp://user:pass@host:port/path
        var path = ""
        if host.contains("://") || host.contains("@"),
           let url = URL(string: host.contains("://") ? host : "\(quickProtocol.urlScheme)://" + host) {
            if let scheme = url.scheme, let proto = ServerProtocol(scheme: scheme) { quickProtocol = proto }
            host = url.host ?? host
            if let u = url.user { user = u.removingPercentEncoding ?? u }
            if let p = url.password { password = p.removingPercentEncoding ?? p }
            if let p = url.port { port = UInt16(p) }
            if !url.path.isEmpty && url.path != "/" { path = url.path }
            quickHost = host
            quickUser = user
            if let port { quickPort = String(port) }
        }
        guard !host.isEmpty else {
            error = ErrorInfo(title: String(localized: "Sunucu gerekli"),
                              message: String(localized: "Bağlanmak için bir sunucu adresi girin."))
            return
        }
        UserDefaults.standard.set(["host": host, "user": user, "port": quickPort, "protocol": quickProtocol.rawValue],
                                  forKey: "quickConnect")
        open(ConnectTarget(config: FTPConfig(host: host, port: port, user: user, password: password,
                                             serverProtocol: quickProtocol),
                           remoteDirectory: path))
    }

    func connect(site: Site, store: SiteStore) {
        store.markUsed(site.id)
        open(site.target)
    }

    /// Connects in the current tab when it is free; otherwise follows the
    /// "connect while connected" setting.
    func open(_ target: ConnectTarget) {
        let tab = current
        guard tab.config != nil else { return tab.connect(target) }
        let behavior = ConnectBehavior(rawValue: UserDefaults.standard.string(forKey: Prefs.connectBehavior) ?? "") ?? .ask
        switch behavior {
        case .ask: pendingConnect = target
        case .newTab: newTab().connect(target)
        case .sameTab: replaceCurrent(with: target)
        }
    }

    /// The answer to "this tab is already connected".
    func connect(_ target: ConnectTarget, inNewTab: Bool) {
        pendingConnect = nil
        if inNewTab { newTab().connect(target) } else { replaceCurrent(with: target) }
    }

    private func replaceCurrent(with target: ConnectTarget) {
        let tab = current
        let active = tab.activeTransfers
        guard active > 0 else { return tab.connect(target) }
        confirm = ConfirmRequest(title: String(localized: "Bu sekmedeki bağlantı değiştirilsin mi?"),
                                 message: String(localized: "\(tab.title) bağlantısının \(active) aktarımı durdurulacak."),
                                 confirmTitle: String(localized: "Bağlan")) { tab.connect(target) }
    }

    // MARK: Transfers

    private func transferFinished(_ item: TransferItem) {
        guard item.status == .done else { return }
        switch item.direction {
        case .download:
            let dir = item.localURL.deletingLastPathComponent().standardizedFileURL.path
            let tabs = sessions.filter { $0.local.path.standardizedFileURL.path == dir }
            guard !tabs.isEmpty else { return }
            localRefreshTask?.cancel()
            localRefreshTask = Task {
                try? await Task.sleep(for: .milliseconds(300))
                if !Task.isCancelled { tabs.forEach { $0.local.load() } }
            }
        case .upload:
            let dir = RemotePath.parent(item.remotePath)
            let tabs = sessions.filter { $0.config == item.config && $0.remote.path == dir }
            guard !tabs.isEmpty else { return }
            remoteRefreshTask?.cancel()
            remoteRefreshTask = Task {
                try? await Task.sleep(for: .milliseconds(600))
                if !Task.isCancelled { for t in tabs { await t.loadRemote(t.remote.path, recordHistory: false) } }
            }
        }
    }

    private func transfersIdle(_ batch: TransferQueue.Batch) {
        DockProgress.shared.update(queue: queue)
        TransferNotifier.notify(batch)
    }

    // MARK: Sites

    /// Saves the current quick connection as a site; the tab then belongs to it.
    func askSaveAsSite(_ session: Session, store: SiteStore) {
        guard let config = session.config, session.siteID == nil else { return }
        ask(TextPrompt(title: String(localized: "Sitelere kaydet"),
                       message: String(localized: "\(config.label) için site adı:"),
                       confirmTitle: String(localized: "Kaydet")) { [weak self] name in
            guard let self else { return }
            let oldKey = session.bookmarkKey
            let site = store.add(from: config, name: name.isEmpty ? config.host : name)
            session.siteID = site.id
            session.siteName = site.name
            // Bookmarks made before saving move to the site.
            if let oldKey, let newKey = session.bookmarkKey, oldKey != newKey {
                let marks = self.bookmarks.bookmarks(for: oldKey)
                if !marks.isEmpty {
                    self.bookmarks.set(marks, for: newKey)
                    self.bookmarks.removeAll(for: oldKey)
                }
            }
            session.log(.status, String(localized: "Site kaydedildi: \(site.name)"))
        }, initial: config.host)
    }

    func importFileZilla(from url: URL, store: SiteStore) {
        do {
            let result = try FileZillaImport.read(url)
            store.add(contentsOf: result.sites)
            for (id, marks) in result.bookmarks { bookmarks.set(marks, for: BookmarkStore.key(site: id)) }
            var lines = [String(localized: "\(result.sites.count) site içe aktarıldı.")]
            if result.encryptedPasswords > 0 {
                lines.append(String(localized: "\(result.encryptedPasswords) sitenin şifresi FileZilla ana parolasıyla korunduğu için aktarılamadı; bu sitelerde şifreyi yeniden girin."))
            }
            if result.unsupported > 0 {
                lines.append(String(localized: "Desteklenmeyen protokol kullanan \(result.unsupported) site atlandı."))
            }
            error = ErrorInfo(title: String(localized: "FileZilla siteleri aktarıldı"), message: lines.joined(separator: "\n"))
        } catch {
            self.error = ErrorInfo(title: String(localized: "İçe aktarılamadı"), message: error.localizedDescription)
        }
    }

    // MARK: Updates

    /// `manual`: from the menu, so "up to date" and errors are shown too.
    func checkForUpdates(manual: Bool) async {
        let d = UserDefaults.standard
        if !manual {
            guard d.bool(forKey: Prefs.checkUpdates) else { return }
            if let last = d.object(forKey: Prefs.lastUpdateCheck) as? Date, Date().timeIntervalSince(last) < 86_400 { return }
        }
        d.set(Date(), forKey: Prefs.lastUpdateCheck)
        switch await UpdateChecker.check() {
        case .newer(let release):
            availableUpdate = release
        case .upToDate(let version):
            if manual {
                error = ErrorInfo(title: String(localized: "MacZilla güncel"),
                                  message: String(localized: "Kullandığınız \(version) sürümü en yeni sürüm."))
            }
        case .failed(let reason):
            if manual {
                error = ErrorInfo(title: String(localized: "Güncellemeler denetlenemedi"), message: reason)
            }
        }
    }

    static func cacheDirectory(_ name: String) -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacZilla/\(name)", isDirectory: true)
    }
}
