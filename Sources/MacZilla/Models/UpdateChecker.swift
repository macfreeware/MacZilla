import Foundation

/// Asks GitLab for the latest MacZilla release.
enum UpdateChecker {
    struct Release: Identifiable {
        var id: String { version }
        let version: String
        /// The release notes as published, in both languages.
        let notes: String
        let url: URL
        /// `MacZilla.zip` and its SHA-256 file; missing on releases older than the updater.
        let archive: URL?
        let checksum: URL?
    }

    enum Outcome {
        case newer(Release), upToDate(String), failed(String)
    }

    static let archiveName = "MacZilla.zip"
    static let checksumName = "MacZilla.zip.sha256"

    static var apiURL: URL {
        #if DEBUG
        if let text = ProcessInfo.processInfo.environment["MACZILLA_UPDATE_URL"], let url = URL(string: text) { return url }
        #endif
        return URL(string: "https://gitlab.com/api/v4/projects/freeware2%2Fmaczilla/releases/permalink/latest")!
    }

    static func check() async -> Outcome {
        var request = URLRequest(url: apiURL, timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                return .failed(String(localized: "GitLab yanıtı: HTTP \(String(http.statusCode))"))
            }
            let release = try parse(data)
            let mine = AppInfo.version ?? "0"
            return isNewer(release.version, than: mine) ? .newer(release) : .upToDate(mine)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    static func parse(_ data: Data) throws -> Release {
        struct Payload: Decodable {
            let tag_name: String
            let description: String?
            let _links: Links?
            let assets: Assets?
            struct Links: Decodable { let `self`: String? }
            struct Assets: Decodable { let links: [Link]? }
            struct Link: Decodable { let name: String; let url: String; let direct_asset_url: String? }
        }
        let p = try JSONDecoder().decode(Payload.self, from: data)
        let version = p.tag_name.hasPrefix("v") ? String(p.tag_name.dropFirst()) : p.tag_name
        func asset(_ name: String) -> URL? {
            guard let link = p.assets?.links?.first(where: { $0.name == name }) else { return nil }
            return trusted(URL(string: link.direct_asset_url ?? link.url))
        }
        return Release(version: version, notes: p.description ?? "",
                       url: trusted(p._links?.`self`.flatMap(URL.init(string:)))
                           ?? AppInfo.repositoryURL.appendingPathComponent("-/releases/\(p.tag_name)"),
                       archive: asset(archiveName), checksum: asset(checksumName))
    }

    /// Only gitlab.com is opened or downloaded from, whatever the release says.
    private static func trusted(_ url: URL?) -> URL? {
        guard let url else { return nil }
        if url.scheme == "https", url.host == "gitlab.com" { return url }
        #if DEBUG
        if url.isFileURL { return url }
        #endif
        return nil
    }

    /// Numeric comparison of dotted versions: 1.10 > 1.9.
    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }
        let y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    /// The digest in `shasum -a 256` output ("abc…  MacZilla.zip"), lowercased.
    static func parseChecksum(_ text: String) -> String? {
        guard let first = text.split(whereSeparator: \.isWhitespace).first else { return nil }
        let hex = first.lowercased()
        return hex.count == 64 && hex.allSatisfy(\.isHexDigit) ? hex : nil
    }

    /// The "what's new" part of the notes in the interface language, as plain text;
    /// the whole notes if they have no such heading.
    static func whatsNew(in notes: String) -> String {
        let turkish = Bundle.main.preferredLocalizations.first == "tr"
        let lines = notes.components(separatedBy: .newlines)
        let start = lines.firstIndex {
            $0.hasPrefix("#") && $0.localizedCaseInsensitiveContains(turkish ? "yenilikler" : "what's new")
        }
        guard let start else { return notes }
        let rest = lines[(start + 1)...]
        let end = rest.firstIndex { $0.hasPrefix("#") || $0.hasPrefix("---") } ?? rest.endIndex
        return rest[..<end].joined(separator: "\n")
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "`", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
