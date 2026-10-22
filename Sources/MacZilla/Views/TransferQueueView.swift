import SwiftUI

struct TransferQueueView: View {
    @Environment(AppModel.self) private var model
    @State private var filter: QueueFilter = .all
    @State private var selection = Set<UUID>()

    enum QueueFilter: String, CaseIterable, Identifiable {
        case all, active, failed, done
        var id: String { rawValue }
    }

    var body: some View {
        let queue = model.queue
        @Bindable var bq = queue
        let items = filtered(queue.items)

        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("", selection: $filter) {
                    Text("Tümü (\(queue.items.count))").tag(QueueFilter.all)
                    Text("Kuyrukta (\(queue.pendingCount))").tag(QueueFilter.active)
                    Text("Başarısız (\(queue.failedCount))").tag(QueueFilter.failed)
                    Text("Tamamlanan (\(queue.doneCount))").tag(QueueFilter.done)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()

                Spacer()

                if queue.pendingCount > 0 {
                    Label("\(Fmt.size(Int64(queue.totalSpeed)))/sn · \(Fmt.size(queue.remainingBytes)) kaldı",
                          systemImage: "speedometer")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                Menu {
                    Picker("Dosya zaten varsa", selection: $bq.policy) {
                        ForEach(ExistsPolicy.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.inline)
                    Picker("Eşzamanlı aktarım", selection: $bq.maxConcurrent) {
                        ForEach(1...6, id: \.self) { Text("\($0) aktarım").tag($0) }
                    }
                } label: {
                    Image(systemName: "gearshape")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Aktarım ayarları")

                Button { queue.retryFailed() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Başarısızları yeniden dene")
                    .disabled(queue.failedCount == 0)
                Button { queue.cancelAll() } label: { Image(systemName: "stop.circle") }
                    .help("Tümünü durdur")
                    .disabled(queue.pendingCount == 0)
                Button { queue.clearFinished() } label: { Image(systemName: "trash") }
                    .help("Tamamlananları temizle")
                    .disabled(queue.doneCount == 0)
            }
            .controlSize(.small)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            Table(items, selection: $selection) {
                TableColumn("") { item in
                    Image(systemName: item.direction == .upload ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                        .foregroundStyle(item.direction == .upload ? .orange : .blue)
                }
                .width(18)
                TableColumn("Dosya") { item in
                    HStack(spacing: 4) {
                        if item.isDirectory { Image(systemName: "folder").foregroundStyle(.secondary) }
                        Text(item.name).lineLimit(1).truncationMode(.middle)
                    }
                    .help(item.source)
                }
                .width(min: 120, ideal: 200)
                TableColumn("Sunucu") { item in
                    Text(item.config.label).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        .help("\(item.config.serverProtocol.shortName) · \(item.config.label)")
                }
                .width(min: 80, ideal: 140)
                TableColumn("Hedef") { item in
                    Text(item.destination).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                        .help(item.destination)
                }
                .width(min: 120, ideal: 300)
                TableColumn("Boyut") { item in
                    Text(item.isDirectory ? "—" : Fmt.size(item.size)).foregroundStyle(.secondary).monospacedDigit()
                }
                .width(min: 50, ideal: 70)
                TableColumn("İlerleme") { item in
                    ProgressCell(item: item)
                }
                .width(min: 120, ideal: 200)
                TableColumn("Durum") { item in
                    StatusCell(status: item.status)
                }
                .width(min: 80, ideal: 140)
            }
            .contextMenu(forSelectionType: UUID.self) { ids in
                Button("Durdur") { queue.cancel(ids) }
                Button("Yeniden Dene") { queue.retry(ids) }
                Divider()
                Button("Kuyruktan Kaldır") { queue.remove(ids) }
                if ids.count == 1, let item = queue.items.first(where: { ids.contains($0.id) }), item.direction == .download {
                    Button("Finder'da Göster") { NSWorkspace.shared.activateFileViewerSelecting([item.localURL]) }
                }
            }
            .onDeleteCommand { queue.remove(selection) }
            .overlay {
                if items.isEmpty {
                    Text(queue.items.isEmpty ? "Aktarım kuyruğu boş — dosyaları paneller arasında sürükleyip bırakın"
                                             : "Bu görünümde öğe yok")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func filtered(_ items: [TransferItem]) -> [TransferItem] {
        switch filter {
        case .all: return items
        case .active: return items.filter { !$0.status.isFinished }
        case .failed: return items.filter { if case .failed = $0.status { return true }; return $0.status == .cancelled }
        case .done: return items.filter { $0.status == .done || $0.status == .skipped }
        }
    }
}

private struct ProgressCell: View {
    let item: TransferItem

    var body: some View {
        if item.isDirectory {
            Text(item.status == .running ? "Listeleniyor…" : "").font(.caption).foregroundStyle(.secondary)
        } else {
            HStack(spacing: 6) {
                ProgressView(value: item.fraction)
                    .progressViewStyle(.linear)
                    .tint(item.status == .done ? .green : .accentColor)
                Text(detail).font(.caption).foregroundStyle(.secondary).monospacedDigit().frame(width: 76, alignment: .trailing)
            }
        }
    }

    private var percent: String { item.fraction.formatted(.percent.precision(.fractionLength(0))) }

    private var detail: String {
        switch item.status {
        case .running:
            let s = item.bytesPerSecond
            return s > 0 ? String(localized: "\(Fmt.size(Int64(s)))/sn") : percent
        default:
            return percent
        }
    }
}

private struct StatusCell: View {
    let status: TransferStatus

    var body: some View {
        switch status {
        case .queued: Label("Bekliyor", systemImage: "clock").foregroundStyle(.secondary)
        case .running: Label("Aktarılıyor", systemImage: "arrow.left.arrow.right").foregroundStyle(.blue)
        case .done: Label("Tamamlandı", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .skipped: Label("Atlandı", systemImage: "forward.circle").foregroundStyle(.secondary)
        case .cancelled: Label("Durduruldu", systemImage: "stop.circle").foregroundStyle(.orange)
        case .failed(let msg): Label("Hata", systemImage: "xmark.octagon.fill").foregroundStyle(.red).help(msg)
        }
    }
}
