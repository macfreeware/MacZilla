import SwiftUI

struct LocalPaneView: View {
    @Environment(AppModel.self) private var app
    @Environment(Session.self) private var model
    @State private var dropTargeted = false

    var body: some View {
        let pane = model.local
        @Bindable var bp = pane
        let cmp = model.comparison
        let items = pane.visibleFiles.filter { !model.compare.hideIdentical || cmp?.local[$0.name] != .same }

        VStack(spacing: 0) {
            PaneHeader(title: String(localized: "Bu Mac"), systemImage: "laptopcomputer", tint: .blue,
                       subtitle: pane.path.lastPathComponent) {
                FilterField(text: $bp.filter)
                Toggle(isOn: $bp.showHidden) { Image(systemName: pane.showHidden ? "eye" : "eye.slash") }
                    .toggleStyle(.button)
                    .controlSize(.small)
                    .help("Gizli dosyaları göster")
                Button { model.askLocalNewFolder() } label: { Image(systemName: "folder.badge.plus") }
                    .controlSize(.small)
                    .help("Yeni klasör")
            }
            PathBar(text: $bp.pathText, canGoBack: pane.canGoBack, canGoUp: pane.path.path != "/",
                    onBack: pane.goBack, onUp: pane.goUp, onRefresh: pane.load,
                    onSubmit: pane.navigate(toText:), leading: AnyView(placesMenu))

            if let err = pane.error {
                ErrorBanner(text: err) { pane.error = nil }
            }

            Table(of: LocalFile.self, selection: $bp.selection, sortOrder: $bp.sortOrder) {
                TableColumn("Ad", value: \.name, comparator: .localizedStandard) { f in
                    let status = cmp?.local[f.name]
                    HStack(spacing: 6) {
                        CompareMark(status: status)
                        Image(nsImage: IconCache.icon(forLocal: f.url, isDirectory: f.isDirectory, isPackage: f.isPackage))
                            .resizable()
                            .frame(width: 16, height: 16)
                        Text(f.name).lineLimit(1).truncationMode(.middle)
                            .foregroundStyle(status.map { $0 == .same ? Color.primary : $0.color } ?? .primary)
                    }
                    .opacity(f.isHidden ? 0.55 : 1)
                }
                .width(min: 140, ideal: 260)
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
                .width(min: 60, ideal: 110)
                TableColumn("Değiştirilme", value: \.modified) { f in
                    Text(Fmt.date(f.modified)).foregroundStyle(.secondary).monospacedDigit()
                }
                .width(min: 90, ideal: 130)
            } rows: {
                ForEach(items) { f in
                    TableRow(f).draggable(f.url)
                }
            }
            .contextMenu(forSelectionType: LocalFile.ID.self) { ids in
                contextMenu(for: pane.files.filter { ids.contains($0.id) })
            } primaryAction: { ids in
                if let f = pane.files.first(where: { ids.contains($0.id) }) {
                    if ids.count == 1 { model.localOpen(f) } else { model.upload(pane.files.filter { ids.contains($0.id) }.map(\.url)) }
                }
            }
            .onDeleteCommand { model.askLocalTrash(pane.selectedFiles) }
            .onKeyPress(.space) {
                guard let f = pane.selectedFiles.first else { return .ignored }
                model.quickLook(f)
                return .handled
            }
            .onChange(of: pane.selection) { model.activePane = .local }
            .overlay {
                if items.isEmpty {
                    EmptyFolderArea(message: pane.files.isEmpty ? "Bu klasör boş" : "Gösterilecek öğe yok") {
                        contextMenu(for: [])
                    }
                }
            }
            .dropDestination(for: String.self) { strings, _ in
                let paths = strings.compactMap { $0.hasPrefix(RemoteDrag.prefix) ? String($0.dropFirst(RemoteDrag.prefix.count)) : nil }
                let files = model.remote.files.filter { paths.contains(model.remote.fullPath($0)) }
                guard !files.isEmpty else { return false }
                model.download(files)
                return true
            } isTargeted: { dropTargeted = $0 }
            .modifier(DropHighlight(active: dropTargeted, label: "Bu klasöre indir"))

            PaneFooter(dirs: items.filter(\.isDirectory).count,
                       files: items.filter { !$0.isDirectory }.count,
                       bytes: items.reduce(0) { $0 + $1.size },
                       selected: pane.selection.count)
        }
    }

    private var placesMenu: some View {
        Menu {
            let fm = FileManager.default
            place(Text("Ana Klasör"), "house", fm.homeDirectoryForCurrentUser)
            place(Text("Masaüstü"), "menubar.dock.rectangle", fm.urls(for: .desktopDirectory, in: .userDomainMask)[0])
            place(Text("Belgeler"), "doc", fm.urls(for: .documentDirectory, in: .userDomainMask)[0])
            place(Text("İndirilenler"), "arrow.down.circle", fm.urls(for: .downloadsDirectory, in: .userDomainMask)[0])
            Divider()
            ForEach(volumes, id: \.self) { v in
                place(Text(verbatim: v.lastPathComponent == "/" ? "Macintosh HD" : v.lastPathComponent), "externaldrive", v)
            }
            Divider()
            Button("Klasör Seç…") { chooseFolder() }
        } label: {
            Image(systemName: "star")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Konumlar")
    }

    private var volumes: [URL] {
        FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? []
    }

    private func place(_ title: Text, _ icon: String, _ url: URL) -> some View {
        Button { model.local.navigate(to: url) } label: { Label { title } icon: { Image(systemName: icon) } }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = model.local.path
        if panel.runModal() == .OK, let url = panel.url { model.local.navigate(to: url) }
    }

    @ViewBuilder
    private func contextMenu(for files: [LocalFile]) -> some View {
        if files.isEmpty {
            Button("Yeni Klasör…") { model.askLocalNewFolder() }
            Button("Yenile") { model.local.load() }
            Button("Finder'da Aç") { NSWorkspace.shared.open(model.local.path) }
        } else {
            Button { model.upload(files.map(\.url)) } label: { Label("Sunucuya Yükle", systemImage: "arrow.up.circle") }
                .disabled(!model.isConnected)
            Divider()
            Button("Aç") { files.forEach { NSWorkspace.shared.open($0.url) } }
            Button("Hızlı Bakış") { model.quickLook(files[0]) }
            Button("Finder'da Göster") { NSWorkspace.shared.activateFileViewerSelecting(files.map(\.url)) }
            Divider()
            if files.count == 1 {
                Button("Yeniden Adlandır…") { model.askLocalRename(files[0]) }
            }
            Button("Çöp Sepeti'ne Taşı", role: .destructive) { model.askLocalTrash(files) }
            Divider()
            Button("Yolu Kopyala") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(files.map(\.url.path).joined(separator: "\n"), forType: .string)
            }
            Button("Yeni Klasör…") { model.askLocalNewFolder() }
        }
    }
}

struct ErrorBanner: View {
    let text: String
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(text).font(.callout).lineLimit(2)
            Spacer()
            Button(action: onClose) { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.12))
    }
}

enum RemoteDrag {
    static let prefix = "maczilla-remote:"
}
