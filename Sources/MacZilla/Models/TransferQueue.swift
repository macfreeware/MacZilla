import Foundation
import FTPKit
import Observation
import SwiftUI

enum TransferDirection {
    case upload, download
}

enum TransferStatus: Equatable {
    case queued, running, done, skipped, cancelled
    case failed(String)

    var isFinished: Bool {
        switch self {
        case .queued, .running: return false
        default: return true
        }
    }
}

enum ExistsPolicy: String, CaseIterable, Identifiable {
    case overwrite, skip, ifDifferent, ifNewer
    var id: String { rawValue }
    var title: LocalizedStringKey {
        switch self {
        case .overwrite: return "Üzerine yaz"
        case .skip: return "Atla"
        case .ifDifferent: return "Boyut farklıysa yaz"
        case .ifNewer: return "Kaynak daha yeniyse yaz"
        }
    }

    /// Whether a file replaces an existing one. `sourceIsNewer` is nil when
    /// the times cannot be compared; sizes decide then.
    func shouldReplace(sourceSize: Int64, destinationSize: Int64, sourceIsNewer: Bool?) -> Bool {
        switch self {
        case .overwrite: return true
        case .skip: return false
        case .ifDifferent: return sourceSize != destinationSize
        case .ifNewer: return sourceIsNewer ?? (sourceSize != destinationSize)
        }
    }
}

/// Comparing modification times taken on two machines.
enum FileTime {
    /// Times with seconds may still differ a little (rounding, FAT disks);
    /// minute-only LIST times by up to a minute.
    static func tolerance(precise: Bool) -> TimeInterval { precise ? 2 : 60 }

    /// nil when either time is unknown.
    static func isNewer(_ a: Date?, than b: Date?, precise: Bool) -> Bool? {
        guard let a, let b, a != .distantPast, b != .distantPast else { return nil }
        return a.timeIntervalSince(b) > tolerance(precise: precise)
    }
}

@Observable
@MainActor
final class TransferItem: Identifiable {
    let id = UUID()
    let direction: TransferDirection
    /// The server this transfer belongs to; retries always go back to it.
    let config: FTPConfig
    /// The tab that queued it, if it is still open.
    let sessionID: UUID?
    let localURL: URL
    let remotePath: String
    let isDirectory: Bool
    /// Overrides the queue's "file exists" rule (used by synchronize).
    let policy: ExistsPolicy?
    /// Downloads: the remote file's time from the listing, and whether it had seconds in UTC.
    let sourceDate: Date?
    let sourcePrecise: Bool
    var size: Int64
    var transferred: Int64 = 0
    var status: TransferStatus = .queued
    var startDate: Date?
    var endDate: Date?

    init(direction: TransferDirection, config: FTPConfig, sessionID: UUID?, localURL: URL, remotePath: String,
         isDirectory: Bool, size: Int64, policy: ExistsPolicy? = nil, sourceDate: Date? = nil, sourcePrecise: Bool = false) {
        self.direction = direction
        self.config = config
        self.sessionID = sessionID
        self.localURL = localURL
        self.remotePath = remotePath
        self.isDirectory = isDirectory
        self.size = size
        self.policy = policy
        self.sourceDate = sourceDate
        self.sourcePrecise = sourcePrecise
    }

    /// A transfer for something inside this (directory) item.
    func child(localURL: URL, remotePath: String, isDirectory: Bool, size: Int64,
               sourceDate: Date? = nil, sourcePrecise: Bool = false) -> TransferItem {
        TransferItem(direction: direction, config: config, sessionID: sessionID, localURL: localURL,
                     remotePath: remotePath, isDirectory: isDirectory, size: size, policy: policy,
                     sourceDate: sourceDate, sourcePrecise: sourcePrecise)
    }

    var name: String { localURL.lastPathComponent }
    var source: String { direction == .upload ? localURL.path : remotePath }
    var destination: String { direction == .upload ? remotePath : localURL.path }

    var fraction: Double {
        if status == .done || status == .skipped { return 1 }
        guard size > 0 else { return 0 }
        return min(1, Double(transferred) / Double(size))
    }

    var bytesPerSecond: Double {
        // Read `transferred` first so views showing the speed keep observing it,
        // even when the first look comes right after the transfer started.
        let done = transferred
        guard let start = startDate else { return 0 }
        let elapsed = (endDate ?? Date()).timeIntervalSince(start)
        return elapsed > 0.2 ? Double(done) / elapsed : 0
    }
}

@Observable
@MainActor
final class TransferQueue {
    var items: [TransferItem] = []
    var maxConcurrent = UserDefaults.standard.object(forKey: "maxConcurrent") as? Int ?? 2 {
        didSet { UserDefaults.standard.set(maxConcurrent, forKey: "maxConcurrent"); pump() }
    }
    var policy = ExistsPolicy(rawValue: UserDefaults.standard.string(forKey: "existsPolicy") ?? "") ?? .overwrite {
        didSet { UserDefaults.standard.set(policy.rawValue, forKey: "existsPolicy") }
    }

    /// What finished since the queue was last idle; reported to `onIdle`.
    struct Batch {
        var done = 0, failed = 0, bytes: Int64 = 0
        var isEmpty: Bool { done == 0 && failed == 0 }
    }

    @ObservationIgnored var trust: TrustHandler?
    /// A transfer connection's log, given its name and the tab it works for.
    @ObservationIgnored var makeLogger: (String, UUID?) -> @Sendable (LogKind, String) -> Void = { _, _ in { _, _ in } }
    @ObservationIgnored var onFinished: ((TransferItem) -> Void)?
    @ObservationIgnored var onIdle: ((Batch) -> Void)?
    @ObservationIgnored private var activeWorkers = 0
    @ObservationIgnored private var workerSeq = 0
    @ObservationIgnored private var tasks: [UUID: Task<Void, Error>] = [:]
    @ObservationIgnored private var batch = Batch()

    var pendingCount: Int { items.filter { $0.status == .queued || $0.status == .running }.count }
    var failedCount: Int { items.filter { if case .failed = $0.status { return true } else { return false } }.count }
    var doneCount: Int { items.filter { $0.status == .done }.count }
    var totalSpeed: Double { items.filter { $0.status == .running }.reduce(0) { $0 + $1.bytesPerSecond } }
    var remainingBytes: Int64 {
        items.filter { $0.status == .queued || $0.status == .running }.reduce(0) { $0 + max(0, $1.size - $1.transferred) }
    }

    func enqueue(_ new: [TransferItem], after parent: TransferItem? = nil) {
        guard !new.isEmpty else { return }
        if let parent, let i = items.firstIndex(where: { $0 === parent }) {
            items.insert(contentsOf: new, at: i + 1)
        } else {
            items.append(contentsOf: new)
        }
        pump()
    }

    func cancel(_ ids: Set<UUID>) {
        for item in items where ids.contains(item.id) && !item.status.isFinished {
            tasks[item.id]?.cancel()
            item.status = .cancelled
        }
    }

    func cancelAll() { cancel(Set(items.map(\.id))) }

    /// Stops the transfers a tab queued (when it disconnects or closes).
    func cancel(session: UUID) { cancel(Set(items.filter { $0.sessionID == session }.map(\.id))) }

    var isBusy: Bool { items.contains { $0.status == .running } }

    /// Bytes done and total of the unfinished work, for the Dock tile.
    var progress: (done: Int64, total: Int64) {
        let open = items.filter { !$0.isDirectory && ($0.status == .queued || $0.status == .running) }
        return (open.reduce(0) { $0 + $1.transferred }, open.reduce(0) { $0 + $1.size })
    }

    func retry(_ ids: Set<UUID>) {
        for item in items where ids.contains(item.id) {
            switch item.status {
            case .failed, .cancelled:
                item.status = .queued
                item.transferred = 0
                item.startDate = nil
                item.endDate = nil
            default: break
            }
        }
        pump()
    }

    func retryFailed() {
        retry(Set(items.filter { if case .failed = $0.status { return true } else { return false } }.map(\.id)))
    }

    func remove(_ ids: Set<UUID>) {
        cancel(ids)
        items.removeAll { ids.contains($0.id) }
    }

    func clearFinished() {
        items.removeAll { $0.status == .done || $0.status == .skipped }
    }

    private func pump() {
        let pending = items.filter { $0.status == .queued }.count
        while activeWorkers < maxConcurrent && activeWorkers < pending {
            activeWorkers += 1
            workerSeq += 1
            let n = workerSeq
            Task { await runWorker(n) }
        }
    }

    private func runWorker(_ n: Int) async {
        let prefix = String(localized: "Aktarım \(n)")
        var client: (any RemoteClient)?
        var clientSession: UUID?
        while activeWorkers <= maxConcurrent, let item = items.first(where: { $0.status == .queued }) {
            // A worker keeps its connection while consecutive items share a server
            // and a tab, so the connection's log stays in that tab.
            if client?.config != item.config || clientSession != item.sessionID {
                await client?.disconnect()
                client = makeRemoteClient(config: item.config, log: makeLogger(prefix, item.sessionID), trust: trust)
                clientSession = item.sessionID
            }
            guard let client else { break }
            item.status = .running
            item.startDate = Date()
            item.endDate = nil
            item.transferred = 0
            let task = Task { try await self.process(item, client) }
            tasks[item.id] = task
            do {
                try await task.value
                if item.status == .running { item.status = .done }
            } catch {
                if item.status != .cancelled {
                    item.status = error is CancellationError ? .cancelled : .failed(error.localizedDescription)
                    if case .failed(let msg) = item.status {
                        makeLogger(prefix, item.sessionID)(.error, "\(item.name): \(msg)")
                    }
                }
            }
            item.endDate = Date()
            if item.size == 0 && item.status == .done { item.size = item.transferred }
            tasks[item.id] = nil
            if !item.isDirectory {
                switch item.status {
                case .done: batch.done += 1; batch.bytes += item.transferred
                case .failed: batch.failed += 1
                default: break
                }
            }
            onFinished?(item)
        }
        activeWorkers -= 1
        await client?.disconnect()
        if activeWorkers == 0 && !items.contains(where: { $0.status == .queued || $0.status == .running }) {
            let finished = batch
            batch = Batch()
            onIdle?(finished)
        }
    }

    private func process(_ item: TransferItem, _ client: any RemoteClient) async throws {
        if !client.isConnected { try await client.connect() }
        let fm = FileManager.default
        let progress: @Sendable (Int64) -> Void = { [weak item] n in
            DispatchQueue.main.async { MainActor.assumeIsolated { item?.transferred = n } }
        }

        switch item.direction {
        case .download:
            if item.isDirectory {
                try fm.createDirectory(at: item.localURL, withIntermediateDirectories: true)
                let (_, files) = try await client.list(item.remotePath)
                enqueue(files.map {
                    item.child(localURL: item.localURL.appendingPathComponent($0.name),
                               remotePath: RemotePath.join(item.remotePath, $0.name),
                               isDirectory: $0.isDirectory, size: $0.size,
                               sourceDate: $0.modified, sourcePrecise: $0.preciseTime)
                }, after: item)
                return
            }
            let policy = item.policy ?? policy
            let preserve = UserDefaults.standard.bool(forKey: Prefs.preserveTimes)
            var remoteDate = item.sourceDate == .distantPast ? nil : item.sourceDate
            var precise = item.sourcePrecise && remoteDate != nil
            // LIST times are minute-only and in the server's time zone: ask for the exact one when it matters.
            if !precise && (preserve || policy == .ifNewer), let exact = try? await client.modified(item.remotePath) {
                remoteDate = exact
                precise = true
            }
            if fm.fileExists(atPath: item.localURL.path) {
                let attrs = try? fm.attributesOfItem(atPath: item.localURL.path)
                let newer = FileTime.isNewer(remoteDate, than: attrs?[.modificationDate] as? Date, precise: precise)
                if !policy.shouldReplace(sourceSize: item.size, destinationSize: attrs?[.size] as? Int64 ?? -1,
                                         sourceIsNewer: newer) {
                    item.status = .skipped
                    return
                }
            }
            try fm.createDirectory(at: item.localURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try await client.download(item.remotePath, to: item.localURL, progress: progress)
            if preserve, precise, let remoteDate {
                try? fm.setAttributes([.modificationDate: remoteDate], ofItemAtPath: item.localURL.path)
            }

        case .upload:
            if item.isDirectory {
                do { try await client.makeDirectory(item.remotePath) }
                catch let e as FTPError { if case .server = e {} else { throw e } } // already exists
                let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey]
                let urls = try fm.contentsOfDirectory(at: item.localURL, includingPropertiesForKeys: keys)
                enqueue(urls.filter { $0.lastPathComponent != ".DS_Store" }.map { url in
                    let v = try? url.resourceValues(forKeys: Set(keys))
                    return item.child(localURL: url, remotePath: RemotePath.join(item.remotePath, url.lastPathComponent),
                                      isDirectory: v?.isDirectory ?? false, size: Int64(v?.fileSize ?? 0))
                }, after: item)
                return
            }
            let policy = item.policy ?? policy
            let preserve = UserDefaults.standard.bool(forKey: Prefs.preserveTimes)
            let local = try? item.localURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let localDate = local?.contentModificationDate
            if policy != .overwrite, let remoteSize = try await client.size(item.remotePath) {
                var remoteDate: Date?
                if policy == .ifNewer { remoteDate = try? await client.modified(item.remotePath) }
                let newer = FileTime.isNewer(localDate, than: remoteDate, precise: true)
                if !policy.shouldReplace(sourceSize: local?.fileSize.map(Int64.init) ?? item.size,
                                         destinationSize: remoteSize, sourceIsNewer: newer) {
                    item.status = .skipped
                    return
                }
            }
            try await client.upload(item.localURL, to: item.remotePath, progress: progress)
            // Keep the file's own time on the server (needs MFMT on FTP servers).
            if preserve, let localDate { _ = try? await client.setModified(item.remotePath, to: localDate) }
        }
    }
}
