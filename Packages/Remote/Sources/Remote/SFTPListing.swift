import Foundation
import FSCore

public struct SFTPEntry: Sendable, Hashable {
    public var name: String
    public var permissions: String
    public var links: Int?
    public var owner: String
    public var group: String
    public var size: Int64
    public var modified: Date?
    public var linkTarget: String?

    public var isDirectory: Bool { permissions.hasPrefix("d") }
    public var isSymlink: Bool { permissions.hasPrefix("l") }
}

public enum SFTPListingParser {
    static let months = ["jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6, "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12]

    public static func parse(_ text: String, now: Date = Date(), calendar: Calendar = .current) -> [SFTPEntry] {
        text.split(separator: "\n", omittingEmptySubsequences: true).compactMap { parseLine(String($0), now: now, calendar: calendar) }
    }

    public static func parseLine(_ raw: String, now: Date = Date(), calendar: Calendar = .current) -> SFTPEntry? {
        let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
        guard let first = line.first, "-dlcbps".contains(first) else { return nil }
        let chars = Array(line)
        var i = 0
        var fields: [String] = []
        while fields.count < 8 {
            while i < chars.count, chars[i] == " " || chars[i] == "\t" { i += 1 }
            guard i < chars.count else { return nil }
            var j = i
            while j < chars.count, chars[j] != " " && chars[j] != "\t" { j += 1 }
            fields.append(String(chars[i..<j]))
            i = j
        }
        guard i < chars.count, chars[i] == " " || chars[i] == "\t" else { return nil }
        i += 1
        var name = String(chars[i...])
        let perms = fields[0]
        guard perms.count >= 10, let size = Int64(fields[4]) else { return nil }
        let links = Int(fields[1])
        var target: String?
        if perms.hasPrefix("l"), let r = name.range(of: " -> ") {
            target = String(name[r.upperBound...])
            name = String(name[..<r.lowerBound])
        }
        if let slash = name.lastIndex(of: "/"), name.count > 1 {
            name = String(name[name.index(after: slash)...])
        }
        guard !name.isEmpty else { return nil }
        let date = parseDate(month: fields[5], day: fields[6], timeOrYear: fields[7], now: now, calendar: calendar)
        return SFTPEntry(name: name, permissions: perms, links: links, owner: fields[2], group: fields[3], size: size, modified: date, linkTarget: target)
    }

    static func parseDate(month: String, day: String, timeOrYear: String, now: Date, calendar: Calendar) -> Date? {
        guard let m = months[month.lowercased().prefix(3).description], let d = Int(day) else { return nil }
        var c = DateComponents()
        c.month = m
        c.day = d
        if timeOrYear.contains(":") {
            let hm = timeOrYear.split(separator: ":")
            guard hm.count == 2, let h = Int(hm[0]), let mi = Int(hm[1]) else { return nil }
            c.hour = h
            c.minute = mi
            let year = calendar.component(.year, from: now)
            c.year = year
            if let candidate = calendar.date(from: c), candidate.timeIntervalSince(now) > 86400 * 2 {
                c.year = year - 1
            }
        } else {
            guard let y = Int(timeOrYear) else { return nil }
            c.year = y
        }
        return calendar.date(from: c)
    }
}
