import Foundation

/// App-wide speed limits shared by every transfer, like FileZilla's global
/// limit: concurrent transfers split the allowance between them.
public final class TransferLimits: @unchecked Sendable {
    public static let shared = TransferLimits()

    private struct Bucket {
        var rate: Int64 = 0          // bytes per second; 0 means unlimited
        var tokens: Double = 0
        var last = Date()
    }

    private let lock = NSLock()
    private var download = Bucket()
    private var upload = Bucket()

    /// Limits in bytes per second; 0 turns a direction's limit off.
    public func set(download: Int64, upload: Int64) {
        lock.withLock {
            self.download = Bucket(rate: max(0, download), tokens: Double(max(0, download)))
            self.upload = Bucket(rate: max(0, upload), tokens: Double(max(0, upload)))
        }
    }

    public var downloadRate: Int64 { lock.withLock { download.rate } }
    public var uploadRate: Int64 { lock.withLock { upload.rate } }

    /// Smaller reads while limited, so progress stays smooth.
    func chunkSize(upload: Bool, default size: Int) -> Int {
        let rate = upload ? uploadRate : downloadRate
        return rate > 0 ? min(size, max(8 * 1024, Int(rate / 4))) : size
    }

    /// Waits until `bytes` more may pass. Throws CancellationError if the
    /// transfer is cancelled while waiting.
    func consume(_ bytes: Int, upload isUpload: Bool) async throws {
        let wait: Double = lock.withLock {
            var b = isUpload ? upload : download
            guard b.rate > 0 else { return 0 }
            let now = Date()
            b.tokens = min(Double(b.rate), b.tokens + now.timeIntervalSince(b.last) * Double(b.rate))
            b.last = now
            b.tokens -= Double(bytes)
            if isUpload { upload = b } else { download = b }
            return b.tokens < 0 ? -b.tokens / Double(b.rate) : 0
        }
        if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
    }
}
