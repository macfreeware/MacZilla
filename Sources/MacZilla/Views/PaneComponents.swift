import SwiftUI

struct PaneHeader<Trailing: View>: View {
    let title: String
    let systemImage: String
    let tint: Color
    var subtitle: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(tint.gradient, in: RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.headline)
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }
}

struct PathBar: View {
    @Binding var text: String
    let canGoBack: Bool
    let canGoUp: Bool
    let onBack: () -> Void
    let onUp: () -> Void
    let onRefresh: () -> Void
    let onSubmit: (String) -> Void
    var leading: AnyView?

    var body: some View {
        HStack(spacing: 4) {
            ControlGroup {
                Button(action: onBack) { Image(systemName: "chevron.left") }
                    .disabled(!canGoBack)
                    .help("Geri")
                Button(action: onUp) { Image(systemName: "arrow.up") }
                    .disabled(!canGoUp)
                    .help("Üst klasör")
            }
            .controlSize(.small)
            .fixedSize()
            if let leading { leading }
            TextField("Yol", text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.system(.callout, design: .monospaced))
                .onSubmit { onSubmit(text) }
            Button(action: onRefresh) { Image(systemName: "arrow.clockwise") }
                .controlSize(.small)
                .help("Yenile")
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }
}

struct FilterField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "line.3.horizontal.decrease").foregroundStyle(.secondary)
            TextField("Süz", text: $text)
                .textFieldStyle(.plain)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
        .frame(width: 140)
    }
}

struct PaneFooter: View {
    let dirs: Int
    let files: Int
    let bytes: Int64
    let selected: Int

    var body: some View {
        HStack {
            Text("\(dirs) klasör, \(files) dosya · \(Fmt.size(bytes))")
            Spacer()
            if selected > 0 { Text("\(selected) seçili") }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.bar)
    }
}

struct DropHighlight: ViewModifier {
    let active: Bool
    let label: LocalizedStringKey

    func body(content: Content) -> some View {
        content.overlay {
            if active {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        Label(label, systemImage: "arrow.down.doc")
                            .font(.headline)
                            .padding(10)
                            .background(.regularMaterial, in: Capsule())
                    }
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
    }
}

/// Covers an empty file list so a right-click still opens the folder menu:
/// a Table only offers its context menu when it has rows.
struct EmptyFolderArea<Items: View>: View {
    let message: LocalizedStringKey
    @ViewBuilder var menu: Items

    var body: some View {
        Text(message)
            .font(.callout)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .contextMenu { menu }
            .padding(.top, 28) // leave the column headers clickable
    }
}
