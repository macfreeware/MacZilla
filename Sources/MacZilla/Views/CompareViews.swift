import SwiftUI

/// The small status icon in front of a name while comparing.
struct CompareMark: View {
    let status: CompareStatus?

    var body: some View {
        if let status, status != .same {
            Image(systemName: status.symbol)
                .font(.system(size: 10))
                .foregroundStyle(status.color)
                .help(status.help)
        }
    }
}

/// Shown above the panes while comparing: legend, options and Synchronize.
struct CompareBar: View {
    @Environment(AppModel.self) private var app
    @Environment(Session.self) private var session

    var body: some View {
        @Bindable var s = session
        let differences = session.comparison?.differences ?? 0
        HStack(spacing: 14) {
            Label("Karşılaştırma açık", systemImage: "rectangle.split.2x1").fontWeight(.medium)
            legend(.onlyHere, "Yalnızca bir tarafta")
            legend(.different, "Boyut farklı")
            if session.compare.useDates {
                legend(.newer, "Daha yeni")
                legend(.older, "Daha eski")
            }
            Spacer()
            Text(differences == 0 ? "Fark yok" : "\(differences) fark").foregroundStyle(.secondary).monospacedDigit()
            Toggle("Tarihleri de karşılaştır", isOn: $s.compare.useDates)
            Toggle("Yalnızca farklılar", isOn: $s.compare.hideIdentical)
            Button("Eşitle…") { app.showSync = true }
            Button { session.compare.enabled = false } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Karşılaştırmayı kapat")
        }
        .toggleStyle(.checkbox)
        .controlSize(.small)
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(Color.accentColor.opacity(0.08))
    }

    private func legend(_ status: CompareStatus, _ title: LocalizedStringKey) -> some View {
        Label { Text(title) } icon: {
            Image(systemName: status.symbol).foregroundStyle(status.color)
        }
        .foregroundStyle(.secondary)
    }
}

/// Copies what is missing or different from one pane to the other.
struct SyncSheet: View {
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var direction: Session.SyncDirection = .upload
    @State private var subfolders = true
    @AppStorage(Prefs.syncPolicy) private var policyName = ExistsPolicy.ifNewer.rawValue

    private var policy: ExistsPolicy { ExistsPolicy(rawValue: policyName) == .ifDifferent ? .ifDifferent : .ifNewer }

    var body: some View {
        let counts = session.syncCandidates(direction, subfolders: subfolders, policy: policy)
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 28))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Klasörleri eşitle").font(.title3.bold())
                    Text("Eksik ya da değişmiş dosyalar karşı tarafa kopyalanır. Hiçbir dosya silinmez.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Picker("Yön", selection: $direction) {
                Text("Bu Mac → Sunucu (yükle)").tag(Session.SyncDirection.upload)
                Text("Sunucu → Bu Mac (indir)").tag(Session.SyncDirection.download)
            }
            .pickerStyle(.radioGroup)

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 6) {
                GridRow {
                    Text(direction == .upload ? "Kaynak" : "Hedef").foregroundStyle(.secondary)
                    Text(session.local.path.path).textSelection(.enabled)
                }
                GridRow {
                    Text(direction == .upload ? "Hedef" : "Kaynak").foregroundStyle(.secondary)
                    Text("\(session.config?.label ?? ""):\(session.remote.path)").textSelection(.enabled)
                }
            }
            .font(.callout)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.1)))

            Picker("Değişmiş sayılan", selection: $policyName) {
                Text("Kaynaktaki dosya daha yeniyse").tag(ExistsPolicy.ifNewer.rawValue)
                Text("Yalnızca boyutu farklıysa (eski davranış)").tag(ExistsPolicy.ifDifferent.rawValue)
            }
            .pickerStyle(.radioGroup)
            Text(policy == .ifNewer
                 ? "Değiştirilme tarihine bakar: içeriği değişip boyutu aynı kalan dosyalar da aktarılır. Karşı taraftaki daha yeniyse dokunulmaz; tarih bilinmiyorsa boyuta bakılır."
                 : "Boyutu aynı olan dosyalar, içerikleri farklı olsa bile aktarılmaz.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Alt klasörleri de eşitle", isOn: $subfolders)
            Text(subfolders
                 ? "Bu klasördeki \(counts.files) dosya ve \(counts.folders) klasör kuyruğa eklenecek. Klasörlerin içindeki dosyalar aktarım sırasında tek tek denetlenir; değişmemiş olanlar atlanır."
                 : "Bu klasördeki \(counts.files) dosya kuyruğa eklenecek.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("İptal", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Eşitle") {
                    session.synchronize(direction, subfolders: subfolders, policy: policy)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(counts.files + counts.folders == 0 || !session.isConnected)
            }
        }
        .padding(22)
        .frame(width: 520)
    }
}
