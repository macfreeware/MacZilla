import FTPKit
import SwiftUI

/// Asks whether to trust a server certificate macOS could not verify.
/// There is deliberately no default (Return) button: accepting takes a click.
struct TrustSheet: View {
    @Environment(AppModel.self) private var model
    let request: TrustRequest

    var body: some View {
        let info = request.info
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "lock.trianglebadge.exclamationmark.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Sertifika doğrulanamadı").font(.title3.bold())
                    Text("\(info.host) sunucusunun TLS sertifikasına macOS güvenmiyor.")
                        .foregroundStyle(.secondary)
                }
            }

            Text("Kendinden imzalı sertifika kullanan sunucularda bu normaldir. Devam etmeden önce aşağıdaki parmak izini sunucu yöneticinizin verdiğiyle karşılaştırın. Parmak izi beklenmedik biçimde değiştiyse bağlanmayın.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text("Sertifika").foregroundStyle(.secondary)
                    Text(info.subject).textSelection(.enabled)
                }
                GridRow {
                    Text("Sorun").foregroundStyle(.secondary)
                    Text(info.problem.isEmpty ? String(localized: "Bilinmiyor") : info.problem)
                        .fixedSize(horizontal: false, vertical: true)
                }
                GridRow {
                    Text("SHA-256").foregroundStyle(.secondary)
                    Text(info.fingerprint)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .font(.callout)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.1)))

            HStack {
                Button("Bağlanma", role: .cancel) { model.resolveTrust(request, .reject) }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Yalnızca Bu Oturum") { model.resolveTrust(request, .once) }
                Button("Her Zaman Güven") { model.resolveTrust(request, .always) }
            }
        }
        .padding(22)
        .frame(width: 500)
    }
}
