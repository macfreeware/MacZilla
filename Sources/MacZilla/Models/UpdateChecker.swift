import Foundation

/// Asks GitLab for the latest MacZilla release.
enum UpdateChecker {
    struct Release: Identifiable {
        var id: String { version }
        let version: String
        let url: URL
    }

    enum Outcome {
        case newer(Release), upToDate(String), failed(String)
    }

    static let apiURL = URL(string: "https://gitlab.com/api/v4/projects/freeware2%2Fmaczilla/releases/permalink/latest")!

    static func check() async -> Outcome {
        var request = URLRequest(url: apiURL, timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                return .failed(String(localized: "GitLab yanıtı: HTTP \(String(code))"))
            }
            struct Payload: Decodable {
                let tag_name: String
                let _links: Links?
                struct Links: Decodable { let `self`: String? }
            }
            let p = try JSONDecoder().decode(Payload.self, from: data)
            let version = p.tag_name.hasPrefix("v") ? String(p.tag_name.dropFirst()) : p.tag_name
            let page = p._links?.`self`.flatMap(URL.init(string:))
                ?? AppInfo.repositoryURL.appendingPathComponent("-/releases/\(p.tag_name)")
            let mine = AppInfo.version ?? "0"
            return isNewer(version, than: mine) ? .newer(Release(version: version, url: page)) : .upToDate(mine)
        } catch {
            return .failed(error.localizedDescription)
        }
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
}
