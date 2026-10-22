import FTPKit
import SwiftUI

struct SiteManagerView: View {
    @Environment(AppModel.self) private var model
    @Environment(SiteStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    /// The sites selected in the list; several can be dragged to a group at once.
    @State private var picked: Set<Site.ID> = []
    @State private var draft = Site()
    @State private var password = ""
    /// Folders the user folded away ("" is the unfiled group); remembered between launches.
    @AppStorage("collapsedSiteFolders") private var collapsedStore = ""
    /// The sites waiting for a new group's name.
    @State private var newFolderFor: Set<Site.ID>?
    @State private var newFolderName = ""
    /// The group being renamed, and the name typed for it.
    @State private var renaming: OutlineGroup?
    @State private var renameText = ""
    /// The group a drag is over.
    @State private var dropTarget: String?
    @FocusState private var folderFocused: Bool

    /// The site shown in the editor: set while exactly one is selected.
    private var selection: Site.ID? { picked.count == 1 ? picked.first : nil }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                sidebar.frame(width: 260)
                Divider()
                if selection != nil {
                    editor
                } else if picked.count > 1 {
                    ContentUnavailableView {
                        Label("\(picked.count) site seçildi", systemImage: "rectangle.stack")
                    } description: {
                        Text("Seçili siteleri soldaki bir grubun başlığına sürükleyin ya da Grupla menüsünü kullanın.")
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView {
                        Label("Site seçilmedi", systemImage: "server.rack")
                    } description: {
                        Text("Sık bağlandığınız sunucuları kaydedin. Şifreler macOS Anahtar Zinciri'nde saklanır.")
                    } actions: {
                        Button("Yeni Site") { addSite() }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            Divider()
            HStack {
                Button { importFileZilla() } label: { Label("FileZilla'dan Aktar…", systemImage: "square.and.arrow.down") }
                    .help("FileZilla'nın Site Yöneticisi'ndeki siteleri, klasörleri ve yer imlerini aktar")
                Spacer()
                Button("Kapat") { commit(); dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    commit()
                    if let site = store.site(selection) {
                        model.connect(site: site, store: store)
                        dismiss()
                    }
                } label: { Label("Bağlan", systemImage: "bolt.fill") }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(selection == nil || draft.host.isEmpty)
            }
            .padding(12)
        }
        .frame(minWidth: 820, maxWidth: .infinity, minHeight: Self.height, maxHeight: .infinity)
        .onAppear {
            if picked.isEmpty, let id = store.recent.first?.id ?? store.sites.first?.id { picked = [id] }
            load()
        }
        // Closing the window with its close button saves the open site too.
        .onDisappear { commit() }
        .onChange(of: selection) { old, _ in
            commit(id: old)
            load()
        }
        .onChange(of: draft.serverProtocol) { old, new in
            // Follow the protocol's default port unless the user set a custom one.
            if draft.port == Int(old.defaultPort) { draft.port = Int(new.defaultPort) }
        }
        .alert("Yeni grup", isPresented: Binding(get: { newFolderFor != nil }, set: { if !$0 { newFolderFor = nil } })) {
            TextField("Grup adı", text: $newFolderName)
            Button("Taşı") {
                let name = SiteStore.folderName(newFolderName)
                if let ids = newFolderFor, !name.isEmpty { move(ids, to: name) }
            }
            Button("İptal", role: .cancel) {}
        } message: {
            Text("Grup içinde grup için adları / ile ayırın, ör. Müşteriler / Ankara.")
        }
        .alert("Grubu yeniden adlandır", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Grup adı", text: $renameText)
            Button("Yeniden Adlandır") {
                if let group = renaming { rename(group, to: renameText.trimmingCharacters(in: .whitespaces)) }
            }
            Button("İptal", role: .cancel) {}
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: $picked) {
                ForEach(outline, id: \.folder) { group in
                    Section {
                        if !collapsed.contains(group.folder) {
                            ForEach(group.sites) { site in
                                siteRow(site)
                                    // Sites sit one step inside their folder's header.
                                    .padding(.leading, CGFloat(group.depth + 1) * Self.indent)
                                    .tag(site.id)
                                    // Dragging a selected site takes the whole selection along.
                                    .draggable(dragIDs(site.id).map(\.uuidString).joined(separator: "\n"))
                                    .dropDestination(for: String.self) { items, _ in drop(items, on: group.folder) }
                                    .contextMenu { Menu("Grupla") { folderMenu(for: dragIDs(site.id)) } }
                            }
                        }
                    } header: {
                        folderHeader(group)
                    }
                }
            }
            .listStyle(.sidebar)
            Divider()
            HStack(spacing: 2) {
                Button { addSite() } label: { Image(systemName: "plus") }.help("Yeni site")
                Button {
                    guard let id = selection else { return }
                    picked = []
                    store.remove(id)
                    model.bookmarks.removeAll(for: BookmarkStore.key(site: id))
                } label: { Image(systemName: "minus") }
                    .disabled(selection == nil)
                    .help("Siteyi sil")
                Button {
                    commit()
                    var copy = draft
                    copy.id = UUID()
                    copy.name += String(localized: " (kopya)")
                    copy.lastUsed = nil
                    store.add(copy)
                    copy.password = password
                    picked = [copy.id]
                } label: { Image(systemName: "plus.square.on.square") }
                    .disabled(selection == nil)
                    .help("Çoğalt")
                Spacer()
                Menu {
                    folderMenu(for: picked)
                } label: {
                    Label("Grupla", systemImage: "rectangle.stack")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(picked.isEmpty)
                .help("Seçili siteleri bir gruba ekle")
            }
            .buttonStyle(.borderless)
            .padding(6)
        }
    }

    private var collapsed: Set<String> {
        Set(collapsedStore.split(separator: "\n", omittingEmptySubsequences: false).map(String.init).dropFirst())
    }

    private func toggle(_ folder: String) {
        var set = collapsed
        if set.contains(folder) { set.remove(folder) } else { set.insert(folder) }
        saveCollapsed(set)
    }

    /// Unfolds a folder and every folder it sits in.
    private func reveal(_ folder: String) {
        let parts = folder.components(separatedBy: " / ")
        saveCollapsed(collapsed.subtracting((1...parts.count).map { parts.prefix($0).joined(separator: " / ") }))
    }

    private func saveCollapsed(_ set: Set<String>) {
        // A leading line keeps "" (the unfiled group) distinguishable from "nothing collapsed".
        collapsedStore = ([""] + set.sorted()).joined(separator: "\n")
    }

    /// The "Grupla" choices: the groups in use, a new one, or none. Site
    /// folders are called groups on screen, so they are not taken for folders on disk.
    @ViewBuilder
    private func folderMenu(for ids: Set<Site.ID>) -> some View {
        let current = Set(ids.map { folder(of: $0) })
        ForEach(store.folders, id: \.self) { f in Button(f) { move(ids, to: f) }.disabled(current == [f]) }
        if !store.folders.isEmpty { Divider() }
        Button("Yeni Grup…") {
            newFolderName = ""
            newFolderFor = ids
        }
        Button("Gruptan Çıkar") { move(ids, to: "") }.disabled(current == [""])
    }

    private func folder(of id: Site.ID) -> String {
        id == selection ? draft.folder : store.site(id)?.folder ?? ""
    }

    /// Files sites under `folder` right away and shows them there.
    private func move(_ ids: Set<Site.ID>, to folder: String) {
        for id in ids {
            if id == selection {
                draft.folder = folder
                commit()
            } else if var site = store.site(id) {
                site.folder = folder
                store.update(site)
            }
        }
        reveal(folder)
    }

    /// The sites a drag or menu on this row acts on.
    private func dragIDs(_ id: Site.ID) -> Set<Site.ID> { picked.contains(id) ? picked : [id] }

    /// Dropped rows arrive as their site ids, one per line.
    private func drop(_ items: [String], on folder: String) -> Bool {
        let ids = Set(items.flatMap { $0.split(separator: "\n") }.compactMap { UUID(uuidString: String($0)) })
            .filter { store.site($0) != nil }
        guard !ids.isEmpty else { return false }
        move(ids, to: folder)
        return true
    }

    /// Renames a group (its own name, not the groups around it) and those inside it.
    private func rename(_ group: OutlineGroup, to name: String) {
        guard !name.isEmpty, name != group.title else { return }
        let old = group.folder
        let new = SiteStore.folderName(String(old.dropLast(group.title.count)) + name)
        commit()
        store.renameFolder(old, to: new)
        if draft.folder == old || draft.folder.hasPrefix(old + " / ") { draft.folder = new + draft.folder.dropFirst(old.count) }
        saveCollapsed(Set(collapsed.map { $0 == old || $0.hasPrefix(old + " / ") ? new + $0.dropFirst(old.count) : $0 }))
    }

    private static let indent: CGFloat = 16

    /// A group of the sidebar: nested folders ("A / B") are shown under their
    /// parent with only their own name, one indent step further in.
    private struct OutlineGroup {
        let folder: String
        let title: String
        let depth: Int
        let sites: [Site]
        /// Sites here and in nested folders, shown next to the header.
        let total: Int
    }

    private var outline: [OutlineGroup] {
        let groups = store.grouped
        let names = Set(groups.map(\.folder))
        var depths: [String: Int] = [:]
        var out: [OutlineGroup] = []
        for g in groups {
            let parts = g.folder.components(separatedBy: " / ")
            // The nearest enclosing folder that has its own header.
            let parent = (1..<max(parts.count, 1)).reversed()
                .map { parts.prefix($0).joined(separator: " / ") }
                .first { names.contains($0) }
            // Hidden while any enclosing folder is collapsed.
            let hidden = (1..<max(parts.count, 1)).contains { collapsed.contains(parts.prefix($0).joined(separator: " / ")) }
            guard !hidden else { continue }
            let depth = parent.map { (depths[$0] ?? 0) + 1 } ?? 0
            depths[g.folder] = depth
            let title = parent.map { String(g.folder.dropFirst($0.count + 3)) } ?? g.folder
            let total = g.folder.isEmpty ? g.sites.count
                : groups.filter { $0.folder == g.folder || $0.folder.hasPrefix(g.folder + " / ") }.reduce(0) { $0 + $1.sites.count }
            out.append(OutlineGroup(folder: g.folder, title: title, depth: depth, sites: g.sites, total: total))
        }
        return out
    }

    private func siteRow(_ site: Site) -> some View {
        HStack {
            Image(systemName: "server.rack").foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 1) {
                Text(site.id == selection ? draft.name : site.name).lineLimit(1)
                Text(site.host.isEmpty ? String(localized: "sunucu yok") : "\(site.serverProtocol.shortName) · \(site.host)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    /// Clicking anywhere on the header folds or unfolds the group; sites
    /// dropped on it join the group.
    private func folderHeader(_ group: OutlineGroup) -> some View {
        let open = !collapsed.contains(group.folder)
        return Button { withAnimation(.easeInOut(duration: 0.15)) { toggle(group.folder) } } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(open ? 90 : 0))
                    .frame(width: 10)
                Image(systemName: group.folder.isEmpty ? "tray.full.fill" : (open ? "rectangle.stack.fill" : "rectangle.stack"))
                    .foregroundStyle(Color.accentColor)
                Text(group.folder.isEmpty ? String(localized: "Sitelerim") : group.title)
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text("\(group.total)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
            }
            .font(.callout)
            .padding(.leading, CGFloat(group.depth) * Self.indent)
            .padding(.vertical, 2)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 5)
                .fill(dropTarget == group.folder ? Color.accentColor.opacity(0.25) : .clear))
        }
        .buttonStyle(.plain)
        .help(open ? "Grubu kapat" : "Grubu aç")
        .dropDestination(for: String.self) { items, _ in drop(items, on: group.folder) } isTargeted: { over in
            if over { dropTarget = group.folder } else if dropTarget == group.folder { dropTarget = nil }
        }
        .contextMenu {
            if !group.folder.isEmpty {
                Button("Grubu Yeniden Adlandır…") {
                    renameText = group.title
                    renaming = group
                }
                // Groups exist through their sites, so a new one starts with the selected sites.
                Button("Alt Grup Oluştur…") {
                    newFolderName = group.folder + " / "
                    newFolderFor = picked
                }
                .disabled(picked.isEmpty)
            }
        }
    }

    private static var height: CGFloat {
        #if DEBUG
        if let h = ProcessInfo.processInfo.environment["MACZILLA_SHEET_HEIGHT"].flatMap(Double.init) { return h }
        #endif
        return 520
    }

    private var editor: some View {
        Form {
            Section("Genel") {
                FieldRow("Site adı") {
                    TextField("", text: $draft.name)
                }
                FieldRow("Grup") {
                    // A typed name takes effect on Return or when leaving the field.
                    TextField("", text: $draft.folder, prompt: Text("isteğe bağlı, ör. Müşteriler"))
                        .focused($folderFocused)
                        .onSubmit { if let id = selection { move([id], to: SiteStore.folderName(draft.folder)) } }
                        .onChange(of: folderFocused) { _, focused in
                            if !focused, let id = selection { move([id], to: SiteStore.folderName(draft.folder)) }
                        }
                    Menu {
                        if let id = selection { folderMenu(for: [id]) }
                    } label: { Image(systemName: "rectangle.stack") }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .help("Var olan bir grubu seç")
                }
                FieldRow("Sunucu") {
                    TextField("", text: $draft.host, prompt: Text("ftp.ornek.com"))
                }
                FieldRow("Protokol") {
                    Picker("", selection: $draft.serverProtocol) {
                        ForEach(ServerProtocol.allCases) { Text($0.title).tag($0) }
                    }
                    .fixedSize()
                    Spacer(minLength: 0)
                }
                FieldRow("Port") {
                    TextField("", value: $draft.port, format: .number.grouping(.never))
                        .frame(width: 80)
                    Spacer(minLength: 0)
                }
                if draft.serverProtocol == .ftp {
                    Label("Şifre ve dosyalar ağda açık metin olarak gider. Sunucu destekliyorsa FTPES ya da SFTP kullanın.",
                          systemImage: "exclamationmark.shield")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Section("Kimlik doğrulama") {
                if draft.serverProtocol != .sftp {
                    FieldRow("Oturum türü") {
                        Picker("", selection: $draft.anonymous) {
                            Text("Normal").tag(false)
                            Text("Anonim").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .fixedSize()
                        Spacer(minLength: 0)
                    }
                }
                if !draft.anonymous || draft.serverProtocol == .sftp {
                    FieldRow("Kullanıcı") {
                        TextField("", text: $draft.user)
                    }
                    FieldRow(draft.serverProtocol == .sftp ? "Şifre / anahtar parolası" : "Şifre") {
                        SecureField("", text: $password)
                    }
                }
                if draft.serverProtocol == .sftp {
                    FieldRow("Özel anahtar") {
                        TextField("", text: $draft.keyFile, prompt: Text("isteğe bağlı, ör. ~/.ssh/id_ed25519"))
                        Button("Seç…") { chooseKey() }
                    }
                    Text("Anahtar seçilmezse ssh-agent ve ~/.ssh içindeki varsayılan anahtarlar denenir. Sunucu anahtarı ilk bağlantıda ~/.ssh/known_hosts dosyasına kaydedilir.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section("Dizinler") {
                FieldRow("Varsayılan uzak dizin") {
                    TextField("", text: $draft.remoteDirectory, prompt: Text("/public_html"))
                }
                FieldRow("Varsayılan yerel dizin") {
                    TextField("", text: $draft.localDirectory, prompt: Text("~/Sites"))
                    Button("Seç…") { chooseLocal() }
                }
            }
            Section("Diğer") {
                FieldRow("Notlar") {
                    TextField("", text: $draft.notes, prompt: Text("isteğe bağlı"), axis: .vertical)
                        .lineLimit(1...5)
                }
            }
        }
        .formStyle(.grouped)
        .textFieldStyle(.plain)
        .labelsHidden()
    }

    private func addSite() {
        commit()
        var new = Site(name: String(localized: "Yeni site \(store.sites.count + 1)"))
        new.folder = draft.folder
        let site = store.add(new)
        picked = [site.id]
    }

    private func load() {
        guard let site = store.site(selection) else { return }
        draft = site
        password = site.password
    }

    private func commit(id: Site.ID? = nil) {
        guard let target = id ?? selection, draft.id == target, store.site(target) != nil else { return }
        store.update(draft)
        if draft.password != password { draft.password = password }
    }

    private func importFileZilla() {
        commit()
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.xml]
        panel.showsHiddenFiles = true
        panel.message = String(localized: "FileZilla'nın sitemanager.xml dosyasını ya da Dosya › Dışa Aktar ile kaydedilmiş bir dosyayı seçin.")
        if let url = FileZillaImport.defaultFile { panel.directoryURL = url.deletingLastPathComponent() }
        if panel.runModal() == .OK, let url = panel.url {
            let before = Set(store.sites.map(\.id))
            model.importFileZilla(from: url, store: store)
            if let id = store.sites.first(where: { !before.contains($0.id) })?.id { picked = [id] }
        }
    }

    private func chooseKey() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.showsHiddenFiles = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        if panel.runModal() == .OK, let url = panel.url {
            draft.keyFile = (url.path as NSString).abbreviatingWithTildeInPath
        }
    }

    private func chooseLocal() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        if panel.runModal() == .OK, let url = panel.url { draft.localDirectory = url.path }
    }
}

/// A form row with a fixed-width label column and left-aligned controls.
private struct FieldRow<Content: View>: View {
    let label: LocalizedStringKey
    @ViewBuilder var content: Content

    init(_ label: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .frame(width: 160, alignment: .leading)
            content
        }
    }
}
