import AppKit
import CryptoKit

/// Installs a release over the running app: downloads `MacZilla.zip`, checks it against
/// `MacZilla.zip.sha256`, checks the app inside, swaps it in and relaunches. MacZilla is not
/// notarized, so the signature only shows that the app is intact, not who built it.
enum Updater {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static var canReplaceApp: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    /// On return the new app is in place; the old one keeps running until `relaunch()`.
    static func install(_ release: UpdateChecker.Release) async throws {
        guard let archive = release.archive, let checksum = release.checksum else {
            throw Failure(message: String(localized: "Bu sürümde MacZilla.zip ya da özet dosyası yok."))
        }
        let (checksumFile, checksumResponse) = try await URLSession.shared.data(from: checksum)
        try requireSuccess(checksumResponse)
        guard let expected = UpdateChecker.parseChecksum(String(decoding: checksumFile, as: UTF8.self)) else {
            throw Failure(message: String(localized: "Özet dosyası okunamadı."))
        }
        let (downloaded, response) = try await URLSession.shared.download(from: archive)
        try requireSuccess(response)
        try Task.checkCancellation()

        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("MacZilla-update-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        let zip = work.appendingPathComponent(UpdateChecker.archiveName)
        try fm.moveItem(at: downloaded, to: zip)

        let app = try verified(zip, expected: expected, version: release.version, in: work)
        try Task.checkCancellation()
        let current = Bundle.main.bundleURL
        do {
            _ = try fm.replaceItemAt(current, withItemAt: app)
        } catch {
            let folder = current.deletingLastPathComponent().path
            throw Failure(message: String(localized: "\(folder) klasörüne yazılamadı: \(error.localizedDescription)"))
        }
    }

    private static func requireSuccess(_ response: URLResponse) throws {
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw Failure(message: String(localized: "GitLab yanıtı: HTTP \(String(http.statusCode))"))
        }
    }

    /// Unpacks the zip and returns the app inside it, ready to install.
    private static func verified(_ zip: URL, expected: String, version: String, in work: URL) throws -> URL {
        let digest = SHA256.hash(data: try Data(contentsOf: zip, options: .mappedIfSafe))
        guard digest.map({ String(format: "%02x", $0) }).joined() == expected else {
            throw Failure(message: String(localized: "İndirilen dosyanın özeti tutmuyor; dosya bozuk ya da değiştirilmiş olabilir."))
        }
        let unpacked = work.appendingPathComponent("unpacked", isDirectory: true)
        guard run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path]) else {
            throw Failure(message: String(localized: "Arşiv açılamadı."))
        }
        // The zip holds a MacZilla folder with the app and the license text.
        let app = unpacked.appendingPathComponent("MacZilla/MacZilla.app", isDirectory: true)
        guard let bundle = Bundle(url: app), bundle.bundleIdentifier == Bundle.main.bundleIdentifier,
              bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == version else {
            throw Failure(message: String(localized: "Arşivdeki uygulama beklenen MacZilla sürümü değil."))
        }
        guard run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path]) else {
            throw Failure(message: String(localized: "Uygulamanın imzası doğrulanamadı."))
        }
        // The user has just approved this update; macOS need not ask again.
        _ = run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.path])
        return app
    }

    private static func run(_ tool: String, _ arguments: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = arguments
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    /// Leaves a small shell job that opens the new app once this one has quit, then quits.
    @MainActor
    static func relaunch() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"",
                       Bundle.main.bundleURL.path]
        try? p.run()
        NSApp.terminate(nil)
    }

    #if DEBUG
    /// MACZILLA_UPDATE_TEST=1: checks and installs without a window, prints the result and
    /// exits. Runs before the app starts, so nothing appears on screen.
    static func runSelfTestIfRequested() {
        guard ProcessInfo.processInfo.environment["MACZILLA_UPDATE_TEST"] != nil else { return }
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            let result: String
            switch await UpdateChecker.check() {
            case .newer(let release):
                do {
                    try await install(release)
                    result = "installed \(release.version)\nwhatsNew: \(UpdateChecker.whatsNew(in: release.notes))"
                } catch {
                    result = "refused \(release.version): \(error.localizedDescription)"
                }
            case .upToDate(let version): result = "upToDate \(version)"
            case .failed(let reason): result = "failed: \(reason)"
            }
            FileHandle.standardError.write(Data("update test: \(result)\n".utf8))
            done.signal()
        }
        done.wait()
        exit(0)
    }
    #endif
}
