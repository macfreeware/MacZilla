import Foundation

public struct RemoteFile: Identifiable, Hashable, Sendable {
    public var id: String { name }
    public let name: String
    public let isDirectory: Bool
    public let isLink: Bool
    public let size: Int64
    public let modified: Date
    public let permissions: String
    public let owner: String
    public let linkTarget: String?
    /// The time came with seconds in UTC (MLSD, SFTP). LIST times are only
    /// to the minute and in the server's own time zone.
    public let preciseTime: Bool

    public init(name: String, isDirectory: Bool, isLink: Bool = false, size: Int64 = 0,
                modified: Date = .distantPast, permissions: String = "", owner: String = "",
                linkTarget: String? = nil, preciseTime: Bool = false) {
        self.name = name
        self.isDirectory = isDirectory
        self.isLink = isLink
        self.size = size
        self.modified = modified
        self.permissions = permissions
        self.owner = owner
        self.linkTarget = linkTarget
        self.preciseTime = preciseTime
    }
}

/// FTP's "YYYYMMDDHHMMSS" UTC times (MLSD facts, MDTM and MFMT).
public enum FTPTime {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMddHHmmss"
        return f
    }()

    /// Accepts fractions ("20261021185500.123"), which are ignored.
    public static func parse(_ text: String) -> Date? {
        let digits = text.trimmingCharacters(in: .whitespaces).prefix(14)
        return digits.count == 14 ? formatter.date(from: String(digits)) : nil
    }

    public static func format(_ date: Date) -> String { formatter.string(from: date) }
}

public enum RemotePath {
    public static func join(_ dir: String, _ name: String) -> String {
        if name.hasPrefix("/") { return name }
        return dir.hasSuffix("/") ? dir + name : dir + "/" + name
    }

    public static func parent(_ path: String) -> String {
        var p = path
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        guard let slash = p.lastIndex(of: "/") else { return "/" }
        let parent = String(p[..<slash])
        return parent.isEmpty ? "/" : parent
    }

    public static func name(_ path: String) -> String {
        var p = path
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p.split(separator: "/").last.map(String.init) ?? p
    }

    /// Breadcrumb components: ["/", "/a", "/a/b"].
    public static func ancestors(_ path: String) -> [String] {
        var result = ["/"]
        var current = ""
        for part in path.split(separator: "/") {
            current += "/" + part
            result.append(current)
        }
        return result
    }
}

enum ListParser {
    static func parse(_ text: String, mlsd: Bool) -> [RemoteFile] {
        text.split(whereSeparator: \.isNewline)
            .compactMap { mlsd ? parseMLSD(String($0)) : parseLIST(String($0)) }
            .filter { $0.name != "." && $0.name != ".." }
    }

    // MARK: MLSD

    static func parseMLSD(_ line: String) -> RemoteFile? {
        guard let sp = line.firstIndex(of: " ") else { return nil }
        let name = String(line[line.index(after: sp)...])
        guard !name.isEmpty else { return nil }
        var facts: [String: String] = [:]
        for fact in line[..<sp].split(separator: ";") {
            let kv = fact.split(separator: "=", maxSplits: 1)
            if kv.count == 2 { facts[kv[0].lowercased()] = String(kv[1]) }
        }
        let type = facts["type"]?.lowercased() ?? "file"
        if type == "cdir" || type == "pdir" { return nil }
        let isLink = type.contains("slink") || type.contains("symlink")
        let size = Int64(facts["size"] ?? facts["sizd"] ?? "") ?? 0
        let modified = facts["modify"].flatMap(FTPTime.parse)
        let perms = facts["unix.mode"].map(modeString) ?? ""
        let owner = facts["unix.ownername"] ?? facts["unix.owner"] ?? ""
        return RemoteFile(name: name, isDirectory: type == "dir", isLink: isLink, size: size,
                          modified: modified ?? .distantPast, permissions: perms, owner: owner,
                          preciseTime: modified != nil)
    }

    static func modeString(_ octal: String) -> String {
        guard let mode = Int(octal, radix: 8) else { return octal }
        let chars = Array("rwxrwxrwx")
        return String((0..<9).map { mode & (1 << (8 - $0)) != 0 ? chars[$0] : "-" })
    }

    // MARK: LIST

    private static let months = ["jan", "feb", "mar", "apr", "may", "jun",
                                 "jul", "aug", "sep", "oct", "nov", "dec"]

    private struct Token {
        let text: Substring
        let end: String.Index
    }

    private static func tokenize(_ line: String) -> [Token] {
        var tokens: [Token] = []
        var i = line.startIndex
        while i < line.endIndex {
            while i < line.endIndex && line[i].isWhitespace { i = line.index(after: i) }
            let start = i
            while i < line.endIndex && !line[i].isWhitespace { i = line.index(after: i) }
            if start < i { tokens.append(Token(text: line[start..<i], end: i)) }
        }
        return tokens
    }

    static func parseLIST(_ line: String) -> RemoteFile? {
        guard let first = line.first else { return nil }
        if line.lowercased().hasPrefix("total ") { return nil }
        if first.isNumber, let dos = parseDOS(line) { return dos }
        guard "-dlbcpsDL".contains(first), line.count > 10 else { return nil }

        let tokens = tokenize(line)
        let perms = String(tokens.first?.text ?? "")
        let isDir = first == "d" || first == "D"
        let isLink = first == "l" || first == "L"

        var date: Date?
        var nameStart: String.Index?
        var size: Int64 = 0
        var owner = ""

        // Unix: ... <size> <Mon> <day> <HH:mm|yyyy> <name>
        if tokens.count >= 5 {
            for m in 1..<(tokens.count - 2) {
                guard let month = months.firstIndex(of: tokens[m].text.prefix(3).lowercased()),
                      tokens[m].text.count == 3,
                      let s = Int64(tokens[m - 1].text),
                      let day = Int(tokens[m + 1].text) else { continue }
                size = s
                date = unixDate(month: month + 1, day: day, timeOrYear: String(tokens[m + 2].text))
                nameStart = tokens[m + 2].end
                if m >= 3 { owner = String(tokens[2].text) }
                break
            }
        }
        // ISO style: ... <size> <yyyy-MM-dd> <HH:mm> <name>
        if nameStart == nil, tokens.count >= 4 {
            for k in 1..<(tokens.count - 1) where tokens[k].text.count == 10 && tokens[k].text.contains("-") {
                guard let s = Int64(tokens[k - 1].text) else { continue }
                size = s
                let f = DateFormatter()
                f.locale = Locale(identifier: "en_US_POSIX")
                f.dateFormat = "yyyy-MM-dd HH:mm"
                date = f.date(from: "\(tokens[k].text) \(tokens[k + 1].text.prefix(5))")
                nameStart = tokens[k + 1].end
                break
            }
        }
        guard let nameStart else { return nil }
        var name = String(line[nameStart...].drop(while: { $0 == " " || $0 == "\t" }))
        guard !name.isEmpty else { return nil }
        var target: String?
        if isLink, let r = name.range(of: " -> ") {
            target = String(name[r.upperBound...])
            name = String(name[..<r.lowerBound])
        }
        return RemoteFile(name: name, isDirectory: isDir, isLink: isLink, size: isDir ? 0 : size,
                          modified: date ?? .distantPast, permissions: perms, owner: owner, linkTarget: target)
    }

    private static func unixDate(month: Int, day: Int, timeOrYear: String) -> Date? {
        var comps = DateComponents()
        comps.month = month
        comps.day = day
        let cal = Calendar(identifier: .gregorian)
        let now = Date()
        if timeOrYear.contains(":") {
            let hm = timeOrYear.split(separator: ":")
            comps.hour = Int(hm[0])
            comps.minute = hm.count > 1 ? Int(hm[1]) : 0
            comps.year = cal.component(.year, from: now)
            if let d = cal.date(from: comps), d > now.addingTimeInterval(86400) {
                comps.year! -= 1
            }
        } else {
            comps.year = Int(timeOrYear)
        }
        return cal.date(from: comps)
    }

    // 01-31-24  10:15AM       <DIR>          folder
    private static let dosRegex = try! NSRegularExpression(
        pattern: #"^(\d{2})-(\d{2})-(\d{2,4})\s+(\d{1,2}):(\d{2})\s*(AM|PM)?\s+(<DIR>|\d+)\s+(.+)$"#,
        options: [.caseInsensitive])

    static func parseDOS(_ line: String) -> RemoteFile? {
        let ns = line as NSString
        guard let m = dosRegex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return nil }
        func g(_ i: Int) -> String? {
            let r = m.range(at: i)
            return r.location == NSNotFound ? nil : ns.substring(with: r)
        }
        var comps = DateComponents()
        comps.month = Int(g(1)!)
        comps.day = Int(g(2)!)
        var year = Int(g(3)!)!
        if year < 100 { year += year < 70 ? 2000 : 1900 }
        comps.year = year
        var hour = Int(g(4)!)!
        if let ampm = g(6)?.uppercased() {
            if ampm == "PM" && hour < 12 { hour += 12 }
            if ampm == "AM" && hour == 12 { hour = 0 }
        }
        comps.hour = hour
        comps.minute = Int(g(5)!)
        let isDir = g(7)!.uppercased() == "<DIR>"
        return RemoteFile(name: g(8)!, isDirectory: isDir, size: isDir ? 0 : Int64(g(7)!) ?? 0,
                          modified: Calendar(identifier: .gregorian).date(from: comps) ?? .distantPast)
    }
}
