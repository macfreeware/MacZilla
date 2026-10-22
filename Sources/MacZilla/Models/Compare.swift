import FTPKit
import Foundation
import SwiftUI

/// Directory comparison settings of a tab.
struct CompareOptions {
    var enabled = false
    /// Also mark same-size files whose modification times differ.
    var useDates = false
    var hideIdentical = false
}

/// How an entry relates to the entry of the same name in the other pane.
enum CompareStatus {
    case same, onlyHere, different, newer, older

    var color: Color {
        switch self {
        case .same: return .secondary
        case .onlyHere: return .green
        case .different: return .orange
        case .newer: return .blue
        case .older: return .purple
        }
    }

    var symbol: String {
        switch self {
        case .same: return "equal.circle"
        case .onlyHere: return "plus.circle.fill"
        case .different: return "exclamationmark.circle.fill"
        case .newer: return "arrow.up.circle.fill"
        case .older: return "arrow.down.circle"
        }
    }

    var help: LocalizedStringKey {
        switch self {
        case .same: return "İki tarafta aynı"
        case .onlyHere: return "Yalnızca bu tarafta var"
        case .different: return "Boyutu farklı"
        case .newer: return "Bu taraftaki daha yeni"
        case .older: return "Bu taraftaki daha eski"
        }
    }
}

/// The comparison of the two panes, computed once per render.
struct Comparison {
    var local: [String: CompareStatus] = [:]
    var remote: [String: CompareStatus] = [:]

    var differences: Int { local.values.filter { $0 != .same }.count + remote.values.filter { $0 == .onlyHere }.count }
}

extension Session {
    /// The comparison while comparing is switched on.
    var comparison: Comparison? { compare.enabled ? makeComparison() : nil }

    func makeComparison() -> Comparison? {
        guard isConnected else { return nil }
        struct Entry { let isDir: Bool; let size: Int64; let date: Date; let precise: Bool }
        let localEntries = Dictionary(local.files.filter { local.showHidden || !$0.isHidden }.map {
            ($0.name, Entry(isDir: $0.isDirectory && !$0.isPackage, size: $0.size, date: $0.modified, precise: true))
        }, uniquingKeysWith: { a, _ in a })
        let remoteEntries = Dictionary(remote.files.filter { remote.showHidden || !$0.name.hasPrefix(".") }.map {
            ($0.name, Entry(isDir: $0.isDirectory, size: $0.size, date: $0.modified, precise: $0.preciseTime))
        }, uniquingKeysWith: { a, _ in a })

        func status(_ mine: Entry, _ other: Entry?) -> CompareStatus {
            guard let other, other.isDir == mine.isDir else { return .onlyHere }
            if mine.isDir { return .same }
            if mine.size != other.size { return .different }
            if compare.useDates {
                let precise = mine.precise && other.precise
                if FileTime.isNewer(mine.date, than: other.date, precise: precise) == true { return .newer }
                if FileTime.isNewer(other.date, than: mine.date, precise: precise) == true { return .older }
            }
            return .same
        }
        var c = Comparison()
        for (name, e) in localEntries { c.local[name] = status(e, remoteEntries[name]) }
        for (name, e) in remoteEntries { c.remote[name] = status(e, localEntries[name]) }
        return c
    }

    enum SyncDirection: String, CaseIterable, Identifiable {
        case upload, download
        var id: String { rawValue }
    }

    /// What a synchronize run queues. Files are picked with the rule the queue
    /// applies again before each transfer; with subfolders every folder is
    /// queued and its contents are checked file by file.
    private func syncPicks(_ direction: SyncDirection, subfolders: Bool,
                           policy: ExistsPolicy) -> (local: [LocalFile], remote: [RemoteFile]) {
        let locals = local.files.filter { local.showHidden || !$0.isHidden }
        let remotes = remote.files.filter { remote.showHidden || !$0.name.hasPrefix(".") }
        let localByName = Dictionary(locals.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        let remoteByName = Dictionary(remotes.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        switch direction {
        case .upload:
            return (locals.filter { f in
                if f.isDirectory && !f.isPackage { return subfolders }
                guard let r = remoteByName[f.name], !r.isDirectory else { return true }
                // Minute-only listing times are left to the queue, which asks the server (MDTM).
                if policy == .ifNewer && !r.preciseTime { return true }
                return policy.shouldReplace(sourceSize: f.size, destinationSize: r.size,
                                            sourceIsNewer: FileTime.isNewer(f.modified, than: r.modified, precise: true))
            }, [])
        case .download:
            return ([], remotes.filter { r in
                if r.isDirectory { return subfolders }
                guard let l = localByName[r.name], !(l.isDirectory && !l.isPackage) else { return true }
                if policy == .ifNewer && !r.preciseTime { return true }
                return policy.shouldReplace(sourceSize: r.size, destinationSize: l.size,
                                            sourceIsNewer: FileTime.isNewer(r.modified, than: l.modified, precise: true))
            })
        }
    }

    func syncCandidates(_ direction: SyncDirection, subfolders: Bool, policy: ExistsPolicy) -> (files: Int, folders: Int) {
        guard isConnected else { return (0, 0) }
        let picks = syncPicks(direction, subfolders: subfolders, policy: policy)
        let folders = picks.local.filter { $0.isDirectory && !$0.isPackage }.count + picks.remote.filter(\.isDirectory).count
        return (picks.local.count + picks.remote.count - folders, folders)
    }

    func synchronize(_ direction: SyncDirection, subfolders: Bool, policy: ExistsPolicy) {
        guard isConnected else { return }
        let picks = syncPicks(direction, subfolders: subfolders, policy: policy)
        switch direction {
        case .upload: upload(picks.local.map(\.url), policy: policy)
        case .download: download(picks.remote, policy: policy)
        }
        log(.status, String(localized: "Eşitleme kuyruğa eklendi: \(local.path.path) ↔ \(remote.path)"))
    }
}
