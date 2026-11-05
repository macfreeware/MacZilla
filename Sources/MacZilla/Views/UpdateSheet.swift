import SwiftUI

/// A new release: what changed, and update now, later or never.
struct UpdateSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let release: UpdateChecker.Release

    private enum Phase { case ask, installing, failed(String) }
    @State private var phase = Phase.ask
    @State private var work: Task<Void, Never>?

    private var canInstall: Bool { release.archive != nil && release.checksum != nil && Updater.canReplaceApp }
    private var busy: Bool { model.queue.pendingCount > 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 2) {
                    Text("MacZilla \(release.version) yayımlandı").font(.headline)
                    Text("Kullandığınız sürüm: \(AppInfo.version ?? "—")").foregroundStyle(.secondary)
                }
            }
            switch phase {
            case .ask: ask
            case .installing: installing
            case .failed(let reason): failed(reason)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private var ask: some View {
        VStack(alignment: .leading, spacing: 14) {
            ScrollView {
                Text(UpdateChecker.whatsNew(in: release.notes))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(height: 170)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            if canInstall && busy {
                Text("Aktarımlar sürerken güncellenemez. Aktarımlar bitince buradan devam edebilirsiniz.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Bu Sürümü Atla") {
                    UserDefaults.standard.set(release.version, forKey: Prefs.skippedUpdateVersion)
                    dismiss()
                }
                Spacer()
                Button("Sonra") { dismiss() }.keyboardShortcut(.cancelAction)
                if canInstall {
                    Button("Şimdi Güncelle") { install() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(busy)
                } else {
                    openPage.keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    private var installing: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Sürüm \(release.version) indiriliyor ve doğrulanıyor. Bitince MacZilla yeniden açılır.")
            ProgressView().progressViewStyle(.linear)
            HStack {
                Spacer()
                Button("İptal") { work?.cancel() }.keyboardShortcut(.cancelAction)
            }
        }
    }

    private func failed(_ reason: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Güncelleme kurulamadı").font(.headline)
            Text(reason).textSelection(.enabled)
            Text("İsterseniz yeni sürümü indirme sayfasından elle kurabilirsiniz.").foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Sonra") { dismiss() }.keyboardShortcut(.cancelAction)
                openPage.keyboardShortcut(.defaultAction)
            }
        }
    }

    private var openPage: some View {
        Button("İndirme Sayfasını Aç") {
            NSWorkspace.shared.open(release.url)
            dismiss()
        }
    }

    private func install() {
        phase = .installing
        work = Task {
            do {
                try await Updater.install(release)
                // AppKit ignores terminate while a sheet is open; ContentView relaunches once it has closed.
                model.updateInstalled = true
                dismiss()
            } catch {
                if Task.isCancelled { phase = .ask } else { phase = .failed(error.localizedDescription) }
            }
        }
    }
}
