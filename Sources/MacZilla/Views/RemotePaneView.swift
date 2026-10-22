import FTPKit
import SwiftUI

struct RemotePaneView: View {
    @Environment(AppModel.self) private var app
    @Environment(Session.self) private var model
    @State private var dropTargeted = false

    var body: some View {
        let pane = model.remote
        @Bindable var bp = pane
        let cmp = model.comparison
        let items = pane.visibleFiles.filter { !model.compare.hideIdentical || cmp?.remote[$0.name] != .same }

        VStack(spacing: 0) {
            PaneHeader(title: model.isConnected ? model.title : String(localized: "Uzak Sunucu"), systemImage: "server.rack",
                       tint: model.isConnected ? .green : .gray,
                       subtitle: model.config.map { "\($0.serverProtocol.shortName) · \($0.host):\($0.port)" }) {
                if let p = model.config?.serverProtocol, model.isConnected {
                    Image(systemName: p.isEncrypted ? "lock.fill" : "lock.open")
                        .foregroundStyle(p.isEncrypted ? .green : .orange)
                        .help(p.isEncrypted ? "Bağlantı şifreli (\(p.title))" : "Bağlantı şifrelenmemiş: şifre ve dosyalar açık metin gider")
                }
                if pane.isLoading { ProgressView().controlSize(.small) }
                FilterField(text: $bp.filter)
                Toggle(isOn: $bp.showHidden) { Image(systemName: pane.showHidden ? "eye" : "eye.slash") }
                    .toggleStyle(.button)
                    .controlSize(.small)
                    .help("Nokta ile başlayan dosyaları göster")
                Button { model.askRemoteNewFolder() } label: { Image(systemName: "folder.badge.plus") }
                    .controlSize(.small)
                    .disabled(!model.isConnected)
                    .help("Yeni klasör")
            }
            PathBar(text: $bp.pathText, canGoBack: !pane.history.isEmpty && model.isConnected,
                    canGoUp: model.isConnected && pane.path != "/",
                    onBack: model.remoteBack, onUp: model.remoteUp, onRefresh: model.remoteRefresh,
                    onSubmit: model.remoteNavigate, leading: AnyView(breadcrumbMenu))
                .disabled(!model.isConnected)

            if let err = pane.error {
                ErrorBanner(text: err) { pane.error = nil }
            }

            Table(of: RemoteFile.self, selection: $bp.selection, sortOrder: $bp.sortOrder) {
                TableColumn("Ad", value: \.name, comparator: .localizedStandard) { f in
                    let status = cmp?.remote[f.name]
                    HStack(spacing: 6) {
                        CompareMark(status: status)
                        Image(nsImage: f.isDirectory ? IconCache.folder
                              : f.isLink ? IconCache.link
                              : IconCache.icon(forExtension: (f.name as NSString).pathExtension))
                            .resizable()
                            .frame(width: 16, height: 16)
                        Text(f.name).lineLimit(1).truncationMode(.middle)
                            .foregroundStyle(status.map { $0 == .same ? Color.primary : $0.color } ?? .primary)
                        if let t = f.linkTarget {
                            Text("→ \(t)").foregroundStyle(.tertiary).lineLimit(1)
                        }
                    }
                    .opacity(f.name.hasPrefix(".") ? 0.55 : 1)
                }
                .width(min: 140, ideal: 240)
                TableColumn("Boyut", value: \.size) { f in
                    Text(f.isDirectory ? "—" : Fmt.size(f.size))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(min: 60, ideal: 80)
                TableColumn("Tür", value: \.kind) { f in
                    Text(f.kind).foregroundStyle(.secondary).lineLimit(1)
                }
                .width(min: 50, ideal: 90)
                TableColumn("Değiştirilme", value: \.modified) { f in
                    Text(Fmt.date(f.modified)).foregroundStyle(.secondary).monospacedDigit()
                }
                .width(min: 90, ideal: 130)
                TableColumn("İzinler", value: \.permissions) { f in
                    Text(f.permissions).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                }
                .width(min: 60, ideal: 85)
                TableColumn("Sahip", value: \.owner) { f in
                    Text(f.owner).foregroundStyle(.secondary).lineLimit(1)
                }
                .width(min: 40, ideal: 60)
            } rows: {
                ForEach(items) { f in
                    TableRow(f).draggable(RemoteDrag.prefix + pane.fullPath(f))
                }
            }
            .contextMenu(forSelectionType: RemoteFile.ID.self) { ids in
                contextMenu(for: pane.files.filter { ids.contains($0.id) })
            } primaryAction: { ids in
                let files = pane.files.filter { ids.contains($0.id) }
                if files.count == 1 { model.remoteOpen(files[0]) } else { model.download(files) }
            }
            .onDeleteCommand { model.askRemoteDelete(pane.selectedFiles) }
            .onKeyPress(.space) {
                guard let f = pane.selectedFiles.first, !f.isDirectory else { return .ignored }
                model.quickLook(f)
                return .handled
            }
            .onChange(of: pane.selection) { model.activePane = .remote }
            .overlay {
                if items.isEmpty && model.isConnected && !pane.isLoading && pane.error == nil {
                    EmptyFolderArea(message: pane.files.isEmpty ? "Bu klasör boş" : "Gösterilecek öğe yok") {
                        contextMenu(for: [])
                    }
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                let files = urls.filter(\.isFileURL)
                guard model.isConnected, !files.isEmpty else { return false }
                model.upload(files)
                return true
            } isTargeted: { dropTargeted = $0 && model.isConnected }
            .modifier(DropHighlight(active: dropTargeted, label: "Sunucuya yükle"))
            .overlay {
                if !model.isConnected { disconnectedOverlay }
            }

            PaneFooter(dirs: items.filter(\.isDirectory).count,
                       files: items.filter { !$0.isDirectory }.count,
                       bytes: items.reduce(0) { $0 + $1.size },
                       selected: pane.selection.count)
        }
    }

    private var breadcrumbMenu: some View {
        Menu {
            ForEach(RemotePath.ancestors(model.remote.path).reversed(), id: \.self) { p in
                Button(p == "/" ? "/" : RemotePath.name(p)) { model.remoteNavigate(p) }
            }
        } label: {
            Image(systemName: "folder")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Üst dizinler")
    }

    @ViewBuilder
    private var disconnectedOverlay: some View {
        if model.state == .connecting {
            VStack(spacing: 10) {
                ProgressView()
                Text("Bağlanılıyor…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.background)
        } else {
            ContentUnavailableView {
                Label("Bağlı değil", systemImage: "network.slash")
            } description: {
                Text("Üstteki hızlı bağlantı çubuğunu ya da Site Yöneticisi'ni kullanarak bir FTP, FTPS ya da SFTP sunucusuna bağlanın.")
            } actions: {
                Button("Site Yöneticisi…") { app.showSiteManager = true }
            }
            .background(.background)
        }
    }

    @ViewBuilder
    private func contextMenu(for files: [RemoteFile]) -> some View {
        if files.isEmpty {
            Button("Yeni Klasör…") { model.askRemoteNewFolder() }
            Button("Yenile") { model.remoteRefresh() }
        } else {
            Button { model.download(files) } label: { Label("İndir", systemImage: "arrow.down.circle") }
            if files.count == 1, !files[0].isDirectory {
                Button("Aç / Görüntüle") { model.remoteView(files[0]) }
                Button("Hızlı Bakış") { model.quickLook(files[0]) }
                Button { model.editRemote(files[0]) } label: { Label("Düzenle", systemImage: "pencil") }
                Button("Birlikte Düzenle…") { model.editRemoteWithChosenApp(files[0]) }
            }
            Divider()
            if files.count == 1 {
                Button("Yeniden Adlandır…") { model.askRemoteRename(files[0]) }
            }
            Button("Dosya İzinleri…") { model.askRemoteChmod(files) }
            Button("Sil", role: .destructive) { model.askRemoteDelete(files) }
            Divider()
            Button("URL'yi Kopyala") { model.copyRemoteURL(files) }
            Button("Yeni Klasör…") { model.askRemoteNewFolder() }
            Button("Yenile") { model.remoteRefresh() }
        }
    }
}
