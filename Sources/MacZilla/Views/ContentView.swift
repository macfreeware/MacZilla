import FTPKit
import QuickLook
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(SiteStore.self) private var sites
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @State private var presentedTrust: TrustRequest?

    var body: some View {
        @Bindable var m = model
        let session = model.current
        VStack(spacing: 0) {
            QuickConnectBar()
            Divider()
            TabStrip()
            Divider()
            if session.compare.enabled {
                CompareBar()
                Divider()
            }
            VSplitView {
                if model.showLog {
                    LogView()
                        .frame(minHeight: 60, idealHeight: 110, maxHeight: 400)
                }
                HSplitView {
                    LocalPaneView().frame(minWidth: 340, maxWidth: .infinity)
                    RemotePaneView().frame(minWidth: 340, maxWidth: .infinity)
                }
                .frame(minHeight: 260, idealHeight: 460, maxHeight: .infinity)
                .layoutPriority(1)
                if model.showQueue {
                    TransferQueueView()
                        .frame(minHeight: 170, idealHeight: 210, maxHeight: 500)
                }
            }
            Divider()
            StatusBar()
        }
        .environment(session)
        .navigationTitle(session.title)
        #if DEBUG
        .task { await DebugHooks.run(model, sites: sites, openWindow: openWindow, openSettings: openSettings) }
        #endif
        .onAppear { model.openMainWindow = { [openWindow] in openWindow(id: "main") } }
        .task {
            DockProgress.shared.start(queue: model.queue)
            await model.checkForUpdates(manual: false)
        }
        .toolbar { toolbar(session) }
        .onChange(of: model.showSiteManager) { _, show in
            guard show else { return }
            model.showSiteManager = false
            openWindow(id: "sites")
        }
        .sheet(isPresented: $m.showBookmarks) {
            BookmarksView().environment(session)
        }
        .sheet(isPresented: $m.showSync) {
            SyncSheet().environment(session)
        }
        .sheet(item: $m.trustRequest, onDismiss: { model.trustPromptDismissed(presentedTrust) }) { request in
            TrustSheet(request: request)
                .onAppear { presentedTrust = request }
        }
        .quickLookPreview($m.previewURL)
        .modifier(AppDialogs())
    }

    @ToolbarContentBuilder
    private func toolbar(_ session: Session) -> some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Menu {
                SiteMenuItems()
            } label: {
                Label("Siteler", systemImage: "server.rack")
            } primaryAction: {
                model.showSiteManager = true
            }
            .help("Site Yöneticisi")
        }
        ToolbarItemGroup {
            Button { session.uploadSelection() } label: { Label("Yükle", systemImage: "arrow.up.circle") }
                .disabled(!session.isConnected || session.local.selection.isEmpty)
                .help("Seçili yerel dosyaları yükle")
            Button { session.downloadSelection() } label: { Label("İndir", systemImage: "arrow.down.circle") }
                .disabled(!session.isConnected || session.remote.selection.isEmpty)
                .help("Seçili uzak dosyaları indir")
            Button { session.refreshAll() } label: { Label("Yenile", systemImage: "arrow.clockwise") }
                .help("Her iki paneli yenile (⌘R)")
            if session.config == nil {
                Button { model.quickConnect() } label: { Label("Bağlan", systemImage: "bolt") }
                    .help("Hızlı bağlan")
            } else {
                Button { model.askDisconnect(session) } label: { Label("Bağlantıyı Kes", systemImage: "bolt.slash") }
                    .help("Bağlantıyı kes (⌘D)")
            }
        }
        ToolbarItemGroup {
            Toggle(isOn: Binding(get: { session.compare.enabled }, set: { session.compare.enabled = $0 })) {
                Label("Karşılaştır", systemImage: "rectangle.split.2x1")
            }
            .disabled(!session.isConnected)
            .help("Klasörleri karşılaştır (⌥⌘C)")
            Menu {
                BookmarkMenuItems(session: session)
            } label: {
                Label("Yer İmleri", systemImage: "bookmark")
            }
            .disabled(session.bookmarkKey == nil)
            .help("Yer imleri")
        }
        ToolbarItemGroup {
            Toggle(isOn: Binding(get: { model.showLog }, set: { model.showLog = $0 })) {
                Label("Günlük", systemImage: "text.alignleft")
            }
            .help("Sunucu günlüğünü göster/gizle")
            Toggle(isOn: Binding(get: { model.showQueue }, set: { model.showQueue = $0 })) {
                Label("Kuyruk", systemImage: "list.bullet.rectangle")
            }
            .help("Aktarım kuyruğunu göster/gizle")
        }
    }
}

/// Saved sites, grouped by folder (toolbar menu).
struct SiteMenuItems: View {
    @Environment(AppModel.self) private var model
    @Environment(SiteStore.self) private var sites

    var body: some View {
        if sites.sites.isEmpty {
            Text("Kayıtlı site yok")
        }
        ForEach(sites.grouped, id: \.folder) { group in
            if group.folder.isEmpty {
                ForEach(group.sites) { s in Button(s.name) { model.connect(site: s, store: sites) } }
            } else {
                Menu(group.folder) {
                    ForEach(group.sites) { s in Button(s.name) { model.connect(site: s, store: sites) } }
                }
            }
        }
        Divider()
        Button("Site Yöneticisi…") { model.showSiteManager = true }
    }
}

struct BookmarkMenuItems: View {
    @Environment(AppModel.self) private var model
    /// Passed in: toolbar menus do not see the window's Session environment.
    let session: Session

    var body: some View {
        let marks = model.bookmarks.bookmarks(for: session.bookmarkKey)
        ForEach(marks) { b in
            Button(b.name) { session.go(to: b) }
        }
        if !marks.isEmpty { Divider() }
        Button("Yer İmi Ekle…") { session.askAddBookmark() }
        Button("Yer İmlerini Düzenle…") { model.showBookmarks = true }
            .disabled(marks.isEmpty)
    }
}

/// One chip per connection, with a close button, and a "+" right after the
/// last tab (as in web browsers) that adds a tab at the end.
private struct TabStrip: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(model.sessions) { TabChip(session: $0).id($0.id) }
                    Button { model.newTab(atEnd: true) } label: {
                        Image(systemName: "plus").frame(width: 22, height: 22).contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .help("Yeni sekme (⌘T)")
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
            }
            .onChange(of: model.currentID) { _, id in proxy.scrollTo(id) }
        }
        .frame(height: 30)
        .background(.bar)
    }
}

private struct TabChip: View {
    @Environment(AppModel.self) private var model
    @Environment(SiteStore.self) private var sites
    let session: Session
    @State private var hover = false

    var body: some View {
        let selected = model.currentID == session.id
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            if let p = session.config?.serverProtocol {
                Image(systemName: p.isEncrypted ? "lock.fill" : "lock.open")
                    .font(.caption2)
                    .foregroundStyle(p.isEncrypted ? .green : .orange)
            }
            Text(session.title)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 200)
            let active = session.activeTransfers
            if active > 0 {
                Text("\(active)")
                    .font(.caption2.monospacedDigit())
                    .padding(.horizontal, 5)
                    .background(Capsule().fill(Color.accentColor.opacity(0.25)))
                    .help("Bu bağlantının süren aktarımları")
            }
            if model.sessions.count > 1 || session.config != nil {
                Button { model.askCloseTab(session) } label: {
                    Image(systemName: "xmark").font(.caption2.weight(.bold))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .opacity(hover || selected ? 1 : 0)
                .help(model.sessions.count > 1 ? "Sekmeyi kapat" : "Bağlantıyı kes")
            }
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(selected ? Color.accentColor.opacity(0.18) : hover ? Color.secondary.opacity(0.12) : .clear))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(selected ? Color.accentColor.opacity(0.5) : .clear))
        .contentShape(Rectangle())
        .onTapGesture { model.select(session) }
        .onHover { hover = $0 }
        .help(session.config.map { "\($0.serverProtocol.shortName) · \($0.label)" } ?? "")
        .contextMenu {
            Button("Yeniden Bağlan") { session.reconnect() }.disabled(session.config == nil)
            Button("Bağlantıyı Kes") { model.askDisconnect(session) }.disabled(session.config == nil)
            Button("Sitelere Kaydet…") { model.askSaveAsSite(session, store: sites) }
                .disabled(session.config == nil || session.siteID != nil)
            Divider()
            Button("Yeni Sekme") { model.newTab() }
            Button("Sekmeyi Kapat") { model.askCloseTab(session) }.disabled(model.sessions.count < 2)
        }
    }

    private var color: Color {
        switch session.state {
        case .connected: return .green
        case .connecting: return .orange
        case .disconnected: return .gray
        }
    }
}

/// Text prompts, confirmations, error alerts and the "already connected" question.
private struct AppDialogs: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        @Bindable var m = model
        content
            .alert(model.prompt?.title ?? "", isPresented: Binding(
                get: { model.prompt != nil }, set: { if !$0 { model.prompt = nil } }
            ), presenting: model.prompt) { p in
                TextField("", text: $m.promptText)
                Button(p.confirmTitle) { p.action(model.promptText.trimmingCharacters(in: .whitespaces)) }
                Button("İptal", role: .cancel) {}
            } message: { p in
                Text(p.message)
            }
            .alert(model.confirm?.title ?? "", isPresented: Binding(
                get: { model.confirm != nil }, set: { if !$0 { model.confirm = nil } }
            ), presenting: model.confirm) { c in
                Button(c.confirmTitle, role: .destructive) { c.action() }
                Button("İptal", role: .cancel) {}
            } message: { c in
                Text(c.message)
            }
            .alert(model.error?.title ?? "", isPresented: Binding(
                get: { model.error != nil }, set: { if !$0 { model.error = nil } }
            ), presenting: model.error) { _ in
                Button("Tamam") {}
            } message: { e in
                Text(e.message)
            }
            .modifier(ConnectionDialogs())
    }
}

/// "Already connected" and "new version" questions.
private struct ConnectionDialogs: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content
            .alert("Bu sekme zaten bağlı", isPresented: Binding(
                get: { model.pendingConnect != nil }, set: { if !$0 { model.pendingConnect = nil } }
            ), presenting: model.pendingConnect) { target in
                Button("Yeni Sekmede Aç") { model.connect(target, inNewTab: true) }
                    .keyboardShortcut(.defaultAction)
                Button("Bu Sekmede Bağlan") { model.connect(target, inNewTab: false) }
                Button("İptal", role: .cancel) {}
            } message: { target in
                Text("\(model.current.title) bağlantısı açık. \(target.name ?? target.config.label) için yeni bir sekme açılsın mı, yoksa bu sekmedeki bağlantı mı değiştirilsin? Bu davranışı Ayarlar'dan değiştirebilirsiniz.")
            }
            .sheet(item: Binding(get: { model.availableUpdate }, set: { model.availableUpdate = $0 }),
                   onDismiss: { if model.updateInstalled { Updater.relaunch() } }) { release in
                UpdateSheet(release: release)
            }
    }
}
