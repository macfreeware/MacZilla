import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        MainActor.assumeIsolated {
            Appearance.applySaved()
            Prefs.applySpeedLimits()
            TransferNotifier.requestAuthorizationIfNeeded()
        }
        // Copies made for viewing, previewing or editing in an earlier run.
        for name in ["Open", "Preview", "Edit"] {
            try? FileManager.default.removeItem(at: AppModel.cacheDirectory(name))
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// ⌘Q, or closing the main window: asks first while transfers are running.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated { model?.confirmQuit() ?? true } ? .terminateNow : .terminateCancel
    }
}

@main
struct MacZillaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()
    @State private var sites = SiteStore()

    init() {
        #if DEBUG
        Updater.runSelfTestIfRequested()
        #endif
        Prefs.registerDefaults()
    }

    var body: some Scene {
        Window("MacZilla", id: "main") {
            ContentView()
                .environment(model)
                .environment(sites)
                .frame(minWidth: 900, minHeight: 600)
                .onAppear { delegate.model = model }
        }
        .defaultSize(width: 1320, height: 860)
        .commands {
            CommandGroup(replacing: .appInfo) { AboutCommand() }
            CommandGroup(after: .appInfo) {
                Button("Güncellemeleri Denetle…") { Task { await model.checkForUpdates(manual: true) } }
            }
            CommandGroup(replacing: .newItem) {
                Button("Yeni Sekme") { model.newTab() }
                    .keyboardShortcut("t")
                Button("Site Yöneticisi…") { model.showSiteManager = true }
                    .keyboardShortcut("s")
                Button("FileZilla'dan Siteleri Aktar…") { importFileZilla() }
                Divider()
                Button("Sitelere Kaydet…") { model.askSaveAsSite(model.current, store: sites) }
                    .disabled(model.current.config == nil || model.current.siteID != nil)
                Button("Yeniden Bağlan") { model.current.reconnect() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(model.current.config == nil)
                Button("Bağlantıyı Kes") { model.askDisconnect(model.current) }
                    .keyboardShortcut("d")
                    .disabled(model.current.config == nil)
                Divider()
                // Always enabled: otherwise ⌘W falls through to Close and shuts the
                // main window. The last tab only disconnects.
                Button("Sekmeyi Kapat") { model.closeKeyWindowOrTab() }
                    .keyboardShortcut("w")
            }
            CommandGroup(after: .toolbar) {
                Button("Yenile") { model.current.refreshAll() }
                    .keyboardShortcut("r")
                Button("Hızlı Bakış") { model.current.quickLookSelection() }
                    .keyboardShortcut("y")
                Divider()
                Toggle("Klasörleri Karşılaştır", isOn: Binding(get: { model.current.compare.enabled },
                                                              set: { model.current.compare.enabled = $0 }))
                    .keyboardShortcut("c", modifiers: [.command, .option])
                    .disabled(!model.current.isConnected)
                Button("Eşitle…") { model.showSync = true }
                    .disabled(!model.current.isConnected)
                Divider()
                Toggle("Sunucu Günlüğü", isOn: Binding(get: { model.showLog }, set: { model.showLog = $0 }))
                    .keyboardShortcut("l", modifiers: [.command, .option])
                Toggle("Aktarım Kuyruğu", isOn: Binding(get: { model.showQueue }, set: { model.showQueue = $0 }))
                    .keyboardShortcut("q", modifiers: [.command, .option])
                Picker("Görünüm", selection: Binding(
                    get: { Appearance(rawValue: UserDefaults.standard.string(forKey: Prefs.appearance) ?? "") ?? .system },
                    set: { UserDefaults.standard.set($0.rawValue, forKey: Prefs.appearance); $0.apply() })) {
                    ForEach(Appearance.allCases) { Text($0.title).tag($0) }
                }
                Divider()
                Button("Sonraki Sekme") { model.selectAdjacentTab(1) }
                    .keyboardShortcut("]", modifiers: [.command, .shift])
                    .disabled(model.sessions.count < 2)
                Button("Önceki Sekme") { model.selectAdjacentTab(-1) }
                    .keyboardShortcut("[", modifiers: [.command, .shift])
                    .disabled(model.sessions.count < 2)
                Divider()
            }
            CommandMenu("Yer İmleri") {
                let s = model.current
                Button("Yer İmi Ekle…") { s.askAddBookmark() }
                    .keyboardShortcut("b")
                    .disabled(s.bookmarkKey == nil)
                Button("Yer İmlerini Düzenle…") { model.showBookmarks = true }
                    .disabled(s.bookmarkKey == nil)
                let marks = model.bookmarks.bookmarks(for: s.bookmarkKey)
                if !marks.isEmpty {
                    Divider()
                    ForEach(marks) { b in Button(b.name) { s.go(to: b) } }
                }
            }
            CommandMenu("Aktarım") {
                Button("Seçilenleri Yükle") { model.current.uploadSelection() }
                    .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                Button("Seçilenleri İndir") { model.current.downloadSelection() }
                    .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                Divider()
                Button("Başarısızları Yeniden Dene") { model.queue.retryFailed() }
                Button("Tümünü Durdur") { model.queue.cancelAll() }
                Button("Tamamlananları Temizle") { model.queue.clearFinished() }
                if !model.edits.entries.isEmpty {
                    Divider()
                    Button("Düzenlenen Dosyaları İzlemeyi Bırak") { model.edits.stopAll() }
                }
            }
        }

        // A window rather than a sheet, so it can be resized.
        Window("Site Yöneticisi", id: "sites") {
            SiteManagerView()
                .environment(model)
                .environment(sites)
        }
        .defaultSize(width: 920, height: 680)
        .windowResizability(.contentMinSize)

        Window("MacZilla Hakkında", id: "about") {
            AboutView()
                .environment(model)
                .environment(sites)
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)

        Settings {
            SettingsView()
                .environment(model)
                .environment(sites)
        }
    }

    private func importFileZilla() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.xml]
        panel.showsHiddenFiles = true
        panel.message = String(localized: "FileZilla'nın sitemanager.xml dosyasını ya da Dosya › Dışa Aktar ile kaydedilmiş bir dosyayı seçin.")
        if let url = FileZillaImport.defaultFile {
            panel.directoryURL = url.deletingLastPathComponent()
        }
        if panel.runModal() == .OK, let url = panel.url { model.importFileZilla(from: url, store: sites) }
    }
}

struct AboutCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("MacZilla Hakkında") { openWindow(id: "about") }
    }
}
