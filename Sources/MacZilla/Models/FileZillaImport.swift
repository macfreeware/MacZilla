import FTPKit
import Foundation

/// Reads FileZilla's Site Manager file (sitemanager.xml, or a File > Export
/// file): sites, folders, plain or base64 passwords and bookmarks.
enum FileZillaImport {
    struct Result {
        var sites: [(site: Site, password: String)] = []
        var bookmarks: [Site.ID: [Bookmark]] = [:]
        /// Sites whose password is protected by a FileZilla master password.
        var encryptedPasswords = 0
        /// Servers using a protocol MacZilla does not speak (S3, WebDAV…).
        var unsupported = 0
    }

    /// Where FileZilla keeps its sites on macOS.
    static var defaultFile: URL? {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/filezilla/sitemanager.xml")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static func read(_ url: URL) throws -> Result {
        let doc = try XMLDocument(contentsOf: url, options: [])
        var result = Result()
        let roots = try doc.nodes(forXPath: "/FileZilla3/Servers")
        guard let root = roots.first as? XMLElement else {
            throw FTPError.local(String(localized: "Bu dosyada FileZilla sitesi bulunamadı."))
        }
        walk(root, folder: [], into: &result)
        return result
    }

    private static func walk(_ element: XMLElement, folder: [String], into result: inout Result) {
        for child in element.children ?? [] {
            guard let el = child as? XMLElement else { continue }
            switch el.name {
            case "Folder":
                // A folder's name is its own text, outside the child elements.
                let name = (el.children ?? []).filter { $0.kind == .text }
                    .compactMap(\.stringValue).joined().trimmingCharacters(in: .whitespacesAndNewlines)
                walk(el, folder: folder + [name.isEmpty ? "FileZilla" : name], into: &result)
            case "Server":
                server(el, folder: folder, into: &result)
            default:
                break
            }
        }
    }

    private static func server(_ el: XMLElement, folder: [String], into result: inout Result) {
        func text(_ name: String) -> String {
            el.elements(forName: name).first?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        let proto: ServerProtocol
        switch Int(text("Protocol")) ?? 0 {
        case 0, 6: proto = .ftp    // FTP (6: "insecure" plain FTP)
        case 1: proto = .sftp
        case 3: proto = .ftps      // implicit TLS
        case 4: proto = .ftpes     // explicit TLS
        default:
            result.unsupported += 1
            return
        }
        var site = Site(name: text("Name"))
        if site.name.isEmpty {
            // Older files keep the name as the element's trailing text.
            site.name = (el.children ?? []).filter { $0.kind == .text }.compactMap(\.stringValue).joined()
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        site.host = text("Host")
        if site.name.isEmpty { site.name = site.host }
        site.serverProtocol = proto
        site.port = Int(text("Port")) ?? Int(proto.defaultPort)
        site.anonymous = text("Logontype") == "0" && proto != .sftp
        site.user = site.anonymous ? "" : text("User")
        site.keyFile = text("Keyfile")
        site.remoteDirectory = remotePath(text("RemoteDir"))
        site.localDirectory = text("LocalDir")
        site.notes = text("Comments")
        site.folder = folder.joined(separator: " / ")

        var password = ""
        if let pass = el.elements(forName: "Pass").first {
            let value = pass.stringValue ?? ""
            switch pass.attribute(forName: "encoding")?.stringValue {
            case "base64": password = Data(base64Encoded: value).flatMap { String(data: $0, encoding: .utf8) } ?? ""
            case "crypt": result.encryptedPasswords += 1
            default: password = value
            }
        }
        result.sites.append((site, site.anonymous ? "" : password))

        let marks = el.elements(forName: "Bookmark").map { b in
            Bookmark(name: b.elements(forName: "Name").first?.stringValue ?? "",
                     localPath: b.elements(forName: "LocalDir").first?.stringValue ?? "",
                     remotePath: remotePath(b.elements(forName: "RemoteDir").first?.stringValue ?? ""))
        }
        if !marks.isEmpty { result.bookmarks[site.id] = marks }
    }

    /// FileZilla writes remote paths as "<type> <prefix length> [<prefix>] <len> <segment> …",
    /// e.g. "1 0 4 home 8 user/www" for a Unix server. Plain paths are returned as they are.
    static func remotePath(_ encoded: String) -> String {
        guard !encoded.isEmpty, !encoded.hasPrefix("/") else { return encoded }
        var rest = Substring(encoded)
        func number() -> Int? {
            let digits = rest.prefix { $0.isNumber }
            guard !digits.isEmpty, let n = Int(digits) else { return nil }
            rest = rest.dropFirst(digits.count)
            if rest.first == " " { rest = rest.dropFirst() }
            return n
        }
        guard number() != nil, let prefixLength = number() else { return encoded }
        rest = rest.dropFirst(prefixLength)
        if rest.first == " " { rest = rest.dropFirst() }
        var segments: [String] = []
        while let len = number(), rest.count >= len {
            segments.append(String(rest.prefix(len)))
            rest = rest.dropFirst(len)
            if rest.first == " " { rest = rest.dropFirst() }
        }
        return segments.isEmpty ? "/" : "/" + segments.joined(separator: "/")
    }
}
