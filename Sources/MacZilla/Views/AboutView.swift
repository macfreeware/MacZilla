import AppKit
import FTPKit
import SwiftUI

/// Uygulama ve geliştirici bilgileri.
enum AppInfo {
    static let name = "MacZilla"
    static let developer = "Rafet SAPANCI"
    static let year = "2026"
    static let repositoryURL = URL(string: "https://gitlab.com/freeware2/maczilla")!
    static let license = "GPL-3.0-or-later"
    static let licenseURL = URL(string: "https://gitlab.com/freeware2/maczilla/-/blob/main/LICENSE")!

    static var version: String? { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String }
    static var build: String? { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String }
    static var commit: String? { Bundle.main.object(forInfoDictionaryKey: "MacZillaCommit") as? String }

    /// "Sürüm 1.1.0 (derleme 3 · 1a2b3c4)" ya da paketsiz çalışırken "Geliştirme derlemesi".
    static var versionDisplay: String {
        guard let version, !version.isEmpty else { return String(localized: "Geliştirme derlemesi") }
        var detail: [String] = []
        if let build, !build.isEmpty { detail.append(String(localized: "derleme \(build)")) }
        if let commit, !commit.isEmpty { detail.append(commit) }
        return String(localized: "Sürüm \(version)") + (detail.isEmpty ? "" : " (\(detail.joined(separator: " · ")))")
    }
}

/// Simgedeki sunucu ünitelerinin renkleri.
enum Brand {
    static let orange = Color(red: 0.96, green: 0.58, blue: 0.16)
    static let teal = Color(red: 0.12, green: 0.66, blue: 0.62)
    static let purple = Color(red: 0.62, green: 0.20, blue: 0.72)
    static let red = Color(red: 0.90, green: 0.20, blue: 0.24)
    static let night = LinearGradient(colors: [Color(red: 0.07, green: 0.11, blue: 0.27),
                                               Color(red: 0.06, green: 0.33, blue: 0.55)],
                                      startPoint: .topLeading, endPoint: .bottomTrailing)
}

/// Simgedeki üç ünitenin renkleriyle ince şerit.
struct BrandStripe: View {
    var height: CGFloat = 3

    var body: some View {
        HStack(spacing: 0) {
            Brand.orange
            Brand.teal
            Brand.purple
        }
        .frame(height: height)
    }
}

/// "MacZilla Hakkında" penceresi: kimlik, geliştirici, kısa kullanım ve sistem durumu.
struct AboutView: View {
    @Environment(SiteStore.self) private var sites

    private enum Tab: String, CaseIterable, Identifiable {
        case general = "Genel", usage = "Kullanım", system = "Sistem"
        var id: String { rawValue }

        var title: LocalizedStringKey {
            switch self {
            case .general: return "Genel"
            case .usage: return "Kullanım"
            case .system: return "Sistem"
            }
        }
    }

    @State private var tab: Tab = .general
    @State private var sshVersion: String?
    @State private var sshPath: String?

    init() {
        #if DEBUG
        if let name = ProcessInfo.processInfo.environment["MACZILLA_ABOUT"], let t = Tab(rawValue: name) {
            _tab = State(initialValue: t)
        }
        #endif
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 24)
            .padding(.vertical, 12)

            Divider()
            ScrollView {
                Group {
                    switch tab {
                    case .general: general
                    case .usage: usage
                    case .system: system
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            footer
        }
        .frame(width: 560, height: 790)
        .task { await probeSSH() }
    }

    // MARK: Üst bölüm

    private var header: some View {
        VStack(spacing: 6) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 104, height: 104)
                .shadow(color: .black.opacity(0.4), radius: 8, y: 4)
            Text(AppInfo.name)
                .font(.system(size: 30, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
            Text(AppInfo.versionDisplay)
                .font(.callout)
                .foregroundStyle(.white.opacity(0.75))
                .textSelection(.enabled)
            Text("macOS için FileZilla tarzı FTP, FTPS ve SFTP istemcisi")
                .font(.callout)
                .foregroundStyle(.white.opacity(0.85))

            HStack(spacing: 6) {
                Image(systemName: "person.crop.circle.fill").foregroundStyle(Brand.orange)
                Text("Geliştirici:").foregroundStyle(.white.opacity(0.7))
                Text(AppInfo.developer).fontWeight(.semibold).foregroundStyle(.white)
            }
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(Capsule().fill(.white.opacity(0.12)))
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 24)
        .padding(.bottom, 18)
        .background(Brand.night)
        .overlay(alignment: .bottom) { BrandStripe() }
    }

    // MARK: Genel

    private var general: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Dosyalarınızı Mac'iniz ile sunucularınız arasında iki panelli, sürükle-bırak destekli bir arayüzle aktarın. Tamamen Swift ile yazılmış, yerel bir macOS uygulamasıdır; Electron ya da ek kütüphane gerektirmez.")
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                feature("rectangle.split.2x1", "İki panel: bu Mac ve uzak sunucu; sıralama, süzme, gizli dosyalar")
                feature("square.on.square", "Sekmeler: aynı anda birden fazla sunucuya bağlanın")
                feature("lock.shield", "FTP, FTPES (açık TLS), FTPS (örtük TLS) ve SFTP")
                feature("arrow.up.arrow.down.circle", "Eşzamanlı aktarım kuyruğu, hız sınırı, Dock'ta ilerleme ve bildirimler")
                feature("arrow.triangle.2.circlepath", "Klasör karşılaştırma ve eşitleme")
                feature("pencil", "Uzak dosyaları düzenleyin; kaydedince otomatik yüklenir")
                feature("server.rack", "Site Yöneticisi: gruplar, yer imleri, FileZilla'dan aktarma; şifreler Anahtar Zinciri'nde")
                feature("key", "SSH anahtarları, ssh-agent ve ~/.ssh/config desteği")
            }

            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text("© \(AppInfo.year) \(AppInfo.developer)").font(.callout)
                Text("MacZilla özgür yazılımdır: GNU Genel Kamu Lisansı sürüm 3 ya da (isteğinize bağlı olarak) daha sonraki bir sürümünün (GPL-3.0-or-later) koşullarına göre kullanabilir, değiştirebilir ve yeniden dağıtabilirsiniz. Program hiçbir garanti olmaksızın sunulur.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 16) {
                    Link(destination: AppInfo.repositoryURL) {
                        Label("gitlab.com/freeware2/maczilla", systemImage: "link")
                    }
                    Link(destination: AppInfo.licenseURL) {
                        Label("Lisans metni (\(AppInfo.license))", systemImage: "doc.text")
                    }
                }
                .font(.callout)
            }
        }
    }

    private func feature(_ icon: String, _ text: LocalizedStringKey) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).frame(width: 22).foregroundStyle(Color.accentColor)
            Text(text)
        }
    }

    // MARK: Kullanım

    private var usage: some View {
        VStack(alignment: .leading, spacing: 16) {
            tip("bolt.fill", "Bağlanma",
                "Üstteki çubuktan protokolü seçip sunucu, kullanıcı ve şifreyi girin ya da Sunucu alanına doğrudan sftp://kullanici@sunucu gibi bir adres yazın. Sık kullandığınız sunucuları Site Yöneticisi'ne (⌘S) kaydedin.")
            tip("lock.fill", "Hangi protokol?",
                "Sunucu destekliyorsa SFTP ya da FTPES kullanın: şifreniz ve dosyalarınız şifreli gider. Düz FTP her şeyi açık metin gönderir. Kendinden imzalı sertifika kullanan sunucularda MacZilla parmak izini gösterip onayınızı ister.")
            tip("square.on.square", "Sekmeler",
                "Her sekme ayrı bir bağlantıdır. Bir sekme bağlıyken yeni bir sunucuya bağlanırsanız MacZilla yeni sekmede mi açacağını sorar (Ayarlar'dan değiştirilebilir). Aktarımlar hangi sunucudan başladıysa ona bağlı kalır.")
            tip("arrow.triangle.2.circlepath", "Karşılaştırma ve eşitleme",
                "Görüntü › Klasörleri Karşılaştır (⌥⌘C) iki paneldeki farkları renkle gösterir. Eşitle… eksik ya da değişmiş dosyaları karşı tarafa kopyalar; hiçbir şeyi silmez. Dosyaların tarihi aktarımda korunduğu için boyutu aynı kalan değişiklikler de yakalanır.")
            tip("pencil", "Düzenleme ve Hızlı Bakış",
                "Uzak bir dosyaya sağ tıklayıp Düzenle'yi seçin: dosya Mac'teki düzenleyicide açılır ve her kaydettiğinizde sunucuya yüklenir. Boşluk tuşu ya da ⌘Y seçili dosyayı Hızlı Bakış ile gösterir.")
            tip("arrow.left.arrow.right", "Aktarma",
                "Dosyaları paneller arasında sürükleyin, çift tıklayın ya da sağ tık menüsünü kullanın. Finder'dan uzak panele bırakılan dosyalar yüklenir. Kuyruktaki ayarlar düğmesinden eşzamanlı aktarım sayısını ve dosya zaten varsa ne yapılacağını seçebilirsiniz.")
            tip("key.fill", "SFTP ve anahtarlar",
                "SFTP, macOS'un kendi ssh aracını kullanır; Terminal'de çalışan anahtarlarınız, ssh-agent ve ~/.ssh/config ayarlarınız burada da çalışır. Şifre alanı, parola korumalı anahtarlar için anahtar parolası olarak da kullanılır.")

            VStack(alignment: .leading, spacing: 6) {
                Label("Klavye kısayolları", systemImage: "keyboard").font(.headline)
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                    shortcut("⌘T", "Yeni sekme")
                    shortcut("⌘W", "Sekmeyi kapat")
                    shortcut("⇧⌘] / ⇧⌘[", "Sonraki / önceki sekme")
                    shortcut("⌘S", "Site Yöneticisi")
                    shortcut("⌘B", "Yer imi ekle")
                    shortcut("⌘Y / Boşluk", "Hızlı Bakış")
                    shortcut("⌥⌘C", "Klasörleri karşılaştır")
                    shortcut("⌘R", "Her iki paneli yenile")
                    shortcut("⌘D", "Bağlantıyı kes")
                    shortcut("⇧⌘R", "Yeniden bağlan")
                    shortcut("⌥⌘↑", "Seçilenleri yükle")
                    shortcut("⌥⌘↓", "Seçilenleri indir")
                    shortcut("⌫", "Seçilenleri sil (onay ister)")
                    shortcut("⌥⌘L / ⌥⌘Q", "Günlüğü / kuyruğu göster-gizle")
                }
            }
        }
    }

    private func tip(_ icon: String, _ title: LocalizedStringKey, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).font(.title3).frame(width: 28).foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func shortcut(_ keys: LocalizedStringKey, _ what: LocalizedStringKey) -> some View {
        GridRow {
            Text(keys)
                .font(.system(.callout, design: .monospaced))
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.15)))
                .gridColumnAlignment(.trailing)
            Text(what).font(.callout)
        }
    }

    // MARK: Sistem

    private var system: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Label("Protokoller", systemImage: "network").font(.headline)
                status(true, "FTP / FTPES / FTPS", String(localized: "Yerleşik; TLS 1.2 (macOS SecureTransport)"))
                status(sshPath != nil, "SFTP",
                       sshPath.map { "\($0)  \(sshVersion ?? "")" } ?? String(localized: "ssh bulunamadı (/usr/bin/ssh). SFTP kullanılamaz."))
            }

            VStack(alignment: .leading, spacing: 8) {
                Label("Veriler", systemImage: "externaldrive").font(.headline)
                status(true, "Kayıtlı siteler", String(localized: "\(sites.sites.count) site · şifreler Anahtar Zinciri'nde (com.maczilla.sites)"))
                path(FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("MacZilla/sites.json").path)
            }

            VStack(alignment: .leading, spacing: 4) {
                Label("Ortam", systemImage: "desktopcomputer").font(.headline)
                Text("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)").font(.callout).foregroundStyle(.secondary)
                path(Bundle.main.bundleURL.path)
            }

            Button("Yenile") { Task { await probeSSH() } }
        }
    }

    private func status(_ ok: Bool, _ title: LocalizedStringKey, _ detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(ok ? .green : .red)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).fontWeight(.medium)
                Text(detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
    }

    private func path(_ p: String) -> some View {
        Text(p).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
    }

    // MARK: Alt bilgi

    private var footer: some View {
        Text("MacZilla FileZilla projesi ile bağlantılı değildir. SFTP bağlantısı macOS ile gelen OpenSSH istemcisi üzerinden kurulur.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
    }

    // MARK: Veri

    private func probeSSH() async {
        let url = URL(fileURLWithPath: "/usr/bin/ssh")
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            sshPath = nil
            return
        }
        sshPath = url.path
        sshVersion = await Task.detached {
            let p = Process()
            p.executableURL = url
            p.arguments = ["-V"]
            let pipe = Pipe()
            p.standardError = pipe
            p.standardOutput = pipe
            guard (try? p.run()) != nil else { return nil }
            p.waitUntilExit()
            let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            return text.split(separator: ",").first.map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        }.value
    }
}
