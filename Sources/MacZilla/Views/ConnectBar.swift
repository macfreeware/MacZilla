import FTPKit
import SwiftUI

struct QuickConnectBar: View {
    @Environment(AppModel.self) private var model
    @Environment(SiteStore.self) private var sites

    var body: some View {
        @Bindable var m = model
        HStack(spacing: 10) {
            Button { model.showSiteManager = true } label: {
                Label("Siteler", systemImage: "server.rack")
            }
            .help("Site Yöneticisi (⌘S)")

            Divider().frame(height: 18)

            Picker("", selection: $m.quickProtocol) {
                ForEach(ServerProtocol.allCases) { p in
                    Label(p.shortName, systemImage: p.isEncrypted ? "lock.fill" : "lock.open").tag(p)
                }
            }
            .labelsHidden()
            .fixedSize()
            .help(model.quickProtocol.title)

            field("Sunucu") {
                TextField("ftp.ornek.com", text: $m.quickHost).frame(width: 220)
            }
            field("Kullanıcı") {
                TextField("anonymous", text: $m.quickUser).frame(width: 140)
            }
            field("Şifre") {
                SecureField("", text: $m.quickPassword).frame(width: 140)
            }
            field("Port") {
                TextField(String(model.quickProtocol.defaultPort), text: $m.quickPort).frame(width: 50)
            }

            Button { model.quickConnect() } label: {
                Label("Bağlan", systemImage: "bolt.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.current.state == .connecting)
            .help(model.current.config == nil ? "Bu sekmede bağlan" : "Yeni bağlantı (bu sekme zaten bağlı)")

            if !sites.recent.isEmpty {
                Menu {
                    Section("Son kullanılan") {
                        ForEach(sites.recent) { s in
                            Button(s.name) { model.connect(site: s, store: sites) }
                        }
                    }
                } label: { Image(systemName: "clock.arrow.circlepath") }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Son bağlantılar")
            }
            Spacer(minLength: 0)
            // The brand mark gives way first when the window is narrow.
            ViewThatFits(in: .horizontal) {
                BrandMark(showName: true)
                BrandMark(showName: false)
                Color.clear.frame(width: 0, height: 0)
            }
        }
        .textFieldStyle(.roundedBorder)
        .controlSize(.regular)
        .onSubmit { model.quickConnect() }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func field<C: View>(_ label: LocalizedStringKey, @ViewBuilder content: () -> C) -> some View {
        HStack(spacing: 5) {
            Text(label).foregroundStyle(.secondary).font(.callout).fixedSize()
            content()
        }
    }
}

struct StatusBar: View {
    @Environment(AppModel.self) private var model
    @Environment(Session.self) private var session
    @AppStorage(Prefs.downloadLimit) private var down = 0
    @AppStorage(Prefs.uploadLimit) private var up = 0

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text)
            if let p = session.config?.serverProtocol, session.state == .connected {
                Label(p.isEncrypted ? "\(p.shortName) · şifreli" : "FTP · şifrelenmemiş",
                      systemImage: p.isEncrypted ? "lock.fill" : "lock.open")
                    .foregroundStyle(p.isEncrypted ? .green : .orange)
            }
            if model.sessions.count > 1 {
                Text("\(model.sessions.filter(\.isConnected).count)/\(model.sessions.count) sekme bağlı")
            }
            Spacer()
            limits
            edits
            let q = model.queue
            if q.pendingCount > 0 {
                Text("\(q.pendingCount) aktarım bekliyor · \(Fmt.size(Int64(q.totalSpeed)))/sn")
                    .monospacedDigit()
            } else if q.failedCount > 0 {
                Text("\(q.failedCount) aktarım başarısız").foregroundStyle(.red)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(.bar)
    }

    @ViewBuilder
    private var limits: some View {
        if down > 0 || up > 0 {
            Label("Hız sınırı açık", systemImage: "gauge.with.dots.needle.33percent")
                .help("İndirme: \(rate(down)) · Yükleme: \(rate(up))")
        }
    }

    private func rate(_ kb: Int) -> String { kb > 0 ? String(localized: "\(kb) KB/sn") : String(localized: "sınırsız") }

    @ViewBuilder
    private var edits: some View {
        let entries = model.edits.entries
        if !entries.isEmpty {
            Menu {
                ForEach(entries) { e in
                    Menu(e.localURL.lastPathComponent) {
                        Text("\(e.config.label):\(e.remotePath)")
                        if e.uploads > 0 { Text("\(e.uploads) kez yüklendi") }
                        Button("Finder'da Göster") { NSWorkspace.shared.activateFileViewerSelecting([e.localURL]) }
                        Button("İzlemeyi Bırak") { model.edits.stop(e.id) }
                    }
                }
                Divider()
                Button("Tümünü İzlemeyi Bırak") { model.edits.stopAll() }
            } label: {
                Label("\(entries.count) dosya düzenleniyor", systemImage: "pencil.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Bu dosyalar kaydedildiğinde sunucuya yeniden yüklenir")
        }
    }

    private var color: Color {
        switch session.state {
        case .connected: return .green
        case .connecting: return .orange
        case .disconnected: return .gray
        }
    }

    private var text: String {
        switch session.state {
        case .connected: return String(localized: "Bağlı: \(session.config?.label ?? "")")
        case .connecting: return String(localized: "Bağlanılıyor…")
        case .disconnected: return String(localized: "Bağlı değil")
        }
    }
}

/// Small app icon and name at the right end of the connection bar.
private struct BrandMark: View {
    @Environment(\.openWindow) private var openWindow
    let showName: Bool

    var body: some View {
        Button { openWindow(id: "about") } label: {
            HStack(spacing: 6) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .frame(width: 22, height: 22)
                if showName {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("MacZilla")
                            .font(.system(size: 14, weight: .heavy, design: .rounded))
                            .foregroundStyle(.primary)
                        BrandStripe(height: 2)
                            .frame(width: 64)
                            .clipShape(Capsule())
                    }
                }
            }
            .fixedSize()
        }
        .buttonStyle(.plain)
        .help("MacZilla Hakkında")
    }
}
