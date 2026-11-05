import SwiftUI

/// MacZilla › Ayarlar (⌘,).
struct SettingsView: View {
    @State private var tab = "general"

    init() {
        #if DEBUG
        if let name = ProcessInfo.processInfo.environment["MACZILLA_SETTINGS_TAB"] { _tab = State(initialValue: name) }
        #endif
    }

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettings()
                .tabItem { Label("Genel", systemImage: "gearshape") }
                .tag("general")
            TransferSettings()
                .tabItem { Label("Aktarım", systemImage: "arrow.up.arrow.down") }
                .tag("transfer")
        }
        .frame(width: 580)
    }
}

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage(Prefs.appearance) private var appearance = Appearance.system.rawValue
    @AppStorage(Prefs.connectBehavior) private var connectBehavior = ConnectBehavior.ask.rawValue
    @AppStorage(Prefs.checkUpdates) private var checkUpdates = true
    @State private var language = AppLanguage(rawValue: UserDefaults.standard.string(forKey: Prefs.language) ?? "") ?? .system
    @State private var checking = false

    var body: some View {
        Form {
            Section {
                Picker("Görünüm", selection: $appearance) {
                    ForEach(Appearance.allCases) { a in
                        Label(a.title, systemImage: a.symbol).tag(a.rawValue)
                    }
                }
                .pickerStyle(.inline)
                .onChange(of: appearance) { _, new in (Appearance(rawValue: new) ?? .system).apply() }
            } footer: {
                Text("Sistem, macOS'un açık ya da koyu görünüm ayarını izler.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Picker("Dil", selection: $language) {
                    ForEach(AppLanguage.allCases) { (Text(verbatim: "\($0.flag)  ") + Text($0.title)).tag($0) }
                }
                .onChange(of: language) { _, new in new.save() }
                if languageChanged {
                    // In the chosen language: someone switching away from a
                    // language they cannot read must still find the button.
                    let next = language.bundle
                    HStack {
                        Text(String(localized: "Yeni dil MacZilla yeniden açıldığında geçerli olur.", bundle: next))
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button(String(localized: "Şimdi Yeniden Başlat", bundle: next)) { relaunch() }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }

            Section {
                Picker("Bir sekme bağlıyken yeni bağlantı", selection: $connectBehavior) {
                    ForEach(ConnectBehavior.allCases) { Text($0.title).tag($0.rawValue) }
                }
            }

            Section {
                Toggle("Güncellemeleri her gün otomatik denetle", isOn: $checkUpdates)
                HStack {
                    Button("Şimdi Denetle") {
                        checking = true
                        Task {
                            await model.checkForUpdates(manual: true)
                            checking = false
                        }
                    }
                    .disabled(checking)
                    if checking { ProgressView().controlSize(.small) }
                }
            } footer: {
                Text("Yeni sürümler gitlab.com/freeware2/maczilla adresinden denetlenir; güncelleme yalnızca siz onaylayınca kurulur.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var languageChanged: Bool { language != AppLanguage.atLaunch }

    private func relaunch() {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        let url = Bundle.main.bundleURL
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}

private struct TransferSettings: View {
    @AppStorage(Prefs.downloadLimit) private var downloadLimit = 0
    @AppStorage(Prefs.uploadLimit) private var uploadLimit = 0
    @AppStorage(Prefs.notifyTransfers) private var notify = true
    @AppStorage(Prefs.dockProgress) private var dock = true
    @AppStorage(Prefs.previewLimitMB) private var previewLimit = 50
    @AppStorage(Prefs.preserveTimes) private var preserveTimes = true

    var body: some View {
        Form {
            Section {
                limitRow("İndirme", value: $downloadLimit)
                limitRow("Yükleme", value: $uploadLimit)
            } header: {
                Text("Hız sınırı")
            } footer: {
                Text("Kutu boşsa hız sınırlanmaz. Sınır o anda süren bütün aktarımlar arasında paylaştırılır.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .onChange(of: downloadLimit) { Prefs.applySpeedLimits() }
            .onChange(of: uploadLimit) { Prefs.applySpeedLimits() }

            Section {
                Toggle("Aktarılan dosyaların değiştirilme tarihini koru", isOn: $preserveTimes)
            } footer: {
                Text("İndirilen dosya sunucudaki tarihini, yüklenen dosya Mac'teki tarihini alır; böylece tarihe göre karşılaştırma ve eşitleme doğru çalışır. FTP'de sunucunun MFMT komutunu desteklemesi gerekir.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Aktarımlar bitince bildirim göster", isOn: $notify)
                    .onChange(of: notify) { _, on in if on { TransferNotifier.requestAuthorizationIfNeeded() } }
                Toggle("Dock simgesinde ilerlemeyi göster", isOn: $dock)
            } footer: {
                Text("Bildirim yalnızca MacZilla arka plandayken gösterilir.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Hızlı Bakış'ta sormadan indir") {
                    HStack(spacing: 4) {
                        TextField("", value: $previewLimit, format: .number.grouping(.never))
                            .frame(width: 70)
                            .multilineTextAlignment(.trailing)
                        Text("MB'a kadar")
                    }
                }
            } footer: {
                Text("Daha büyük uzak dosyaları önizlemeden önce sorulur. 0 her zaman sormadan indirir.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
        .textFieldStyle(.roundedBorder)
    }

    /// 0 (no limit) shows as an empty box saying "Sınırsız".
    private func limitRow(_ title: LocalizedStringKey, value: Binding<Int>) -> some View {
        let limit = Binding<Int?>(get: { value.wrappedValue > 0 ? value.wrappedValue : nil },
                                  set: { value.wrappedValue = max(0, $0 ?? 0) })
        return LabeledContent(title) {
            HStack(spacing: 6) {
                TextField("", value: limit, format: .number.grouping(.never), prompt: Text("Sınırsız"))
                    .frame(width: 100)
                    .multilineTextAlignment(.trailing)
                Text("KB/sn")
            }
        }
    }
}
