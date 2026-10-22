import FTPKit
import SwiftUI

/// The server log of the tab in front.
struct LogView: View {
    @Environment(Session.self) private var session

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(session.logs) { entry in
                        LogRow(entry: entry).id(entry.id)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: session.logs.last?.id) { _, id in
                if let id { proxy.scrollTo(id, anchor: .bottom) }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .overlay {
            if session.logs.isEmpty {
                Text("Sunucu günlüğü burada görünecek").font(.callout).foregroundStyle(.tertiary)
            }
        }
        .contextMenu {
            Button("Günlüğü Kopyala") {
                let text = session.logs.map { e in "\(Fmt.time.string(from: e.date)) \(e.text)" }.joined(separator: "\n")
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
            Button("Günlüğü Temizle") { session.logs.removeAll() }
        }
    }
}

private struct LogRow: View {
    let entry: LogEntry

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(Fmt.time.string(from: entry.date)).foregroundStyle(.tertiary)
            Text(label).foregroundStyle(color).frame(width: 52, alignment: .leading)
            Text(entry.text)
                .foregroundStyle(entry.kind == .error ? Color.red : Color.primary)
                .textSelection(.enabled)
        }
        .font(.system(size: 11, design: .monospaced))
    }

    private var label: LocalizedStringKey {
        switch entry.kind {
        case .status: return "Durum"
        case .command: return "Komut"
        case .response: return "Yanıt"
        case .error: return "Hata"
        }
    }

    private var color: Color {
        switch entry.kind {
        case .status: return .secondary
        case .command: return .blue
        case .response: return .green
        case .error: return .red
        }
    }
}
