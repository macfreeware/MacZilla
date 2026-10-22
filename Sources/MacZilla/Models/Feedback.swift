import AppKit
import UserNotifications

/// Transfer progress on the Dock icon: a bar over the icon and a badge with
/// the number of transfers left.
@MainActor
final class DockProgress {
    static let shared = DockProgress()

    private let view = DockProgressView()
    private var timer: Timer?
    private var showing = false

    func start(queue: TransferQueue) {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.update(queue: queue) }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func update(queue: TransferQueue) {
        let tile = NSApp.dockTile
        guard UserDefaults.standard.bool(forKey: Prefs.dockProgress), queue.isBusy || queue.pendingCount > 0 else {
            if showing {
                tile.contentView = nil
                tile.badgeLabel = nil
                tile.display()
                showing = false
            }
            return
        }
        let (done, total) = queue.progress
        view.fraction = total > 0 ? Double(done) / Double(total) : 0
        if !showing {
            tile.contentView = view
            showing = true
        }
        tile.badgeLabel = String(queue.pendingCount)
        tile.display()
    }
}

private final class DockProgressView: NSView {
    var fraction = 0.0

    override func draw(_ dirtyRect: NSRect) {
        NSApp.applicationIconImage?.draw(in: bounds)
        let bar = NSRect(x: bounds.width * 0.12, y: bounds.height * 0.1,
                         width: bounds.width * 0.76, height: bounds.height * 0.1)
        let radius = bar.height / 2
        NSColor.black.withAlphaComponent(0.55).setFill()
        NSBezierPath(roundedRect: bar, xRadius: radius, yRadius: radius).fill()
        let inner = bar.insetBy(dx: 2, dy: 2)
        var fill = inner
        fill.size.width = max(inner.height, inner.width * min(1, max(0, fraction)))
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: fill, xRadius: inner.height / 2, yRadius: inner.height / 2).fill()
    }
}

/// A notification when the queue empties while MacZilla is in the background.
@MainActor
enum TransferNotifier {
    static func requestAuthorizationIfNeeded() {
        guard UserDefaults.standard.bool(forKey: Prefs.notifyTransfers) else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func notify(_ batch: TransferQueue.Batch) {
        guard !batch.isEmpty, UserDefaults.standard.bool(forKey: Prefs.notifyTransfers), !NSApp.isActive else { return }
        let content = UNMutableNotificationContent()
        if batch.failed == 0 {
            content.title = String(localized: "Aktarımlar tamamlandı")
            content.body = String(localized: "\(batch.done) dosya aktarıldı (\(Fmt.size(batch.bytes))).")
        } else {
            content.title = String(localized: "Bazı aktarımlar başarısız")
            content.body = String(localized: "\(batch.done) dosya aktarıldı, \(batch.failed) dosya aktarılamadı.")
        }
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString,
                                                                     content: content, trigger: nil))
        if batch.failed > 0 { NSApp.requestUserAttention(.informationalRequest) }
    }
}
