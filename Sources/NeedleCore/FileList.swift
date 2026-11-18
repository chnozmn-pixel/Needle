import Foundation

// MARK: - Model

public struct FileListItem: Sendable, Equatable {
    public var path: String
    public var isDirectory: Bool
    public var size: Int64
    public var modifiedAt: Date?
    public var createdAt: Date?
    public var tags: [String]
    public var comment: String?

    public init(
        path: String,
        isDirectory: Bool = false,
        size: Int64 = 0,
        modifiedAt: Date? = nil,
        createdAt: Date? = nil,
        tags: [String] = [],
        comment: String? = nil
    ) {
        self.path = path
        self.isDirectory = isDirectory
        self.size = size
        self.modifiedAt = modifiedAt
        self.createdAt = createdAt
        self.tags = tags
        self.comment = comment
    }
}

// MARK: - EFU import / export

public enum FileList {

    private static let header = "Filename,Size,Date Modified,Date Created,Attributes,Tags,Comment"

    // Seconds between 1601-01-01 (Windows FILETIME epoch) and 1970-01-01.
    private static let filetimeEpochOffset: Double = 11_644_473_600
    private static let ticksPerSecond: Double = 10_000_000

    /// Parses Everything EFU CSV. Header line required and must contain Filename.
    /// Supports columns: Filename, Size, Date Modified, Date Created, Attributes, Tags, Comment.
    /// Dates may be ISO 8601 or Windows FILETIME ticks; attributes 16 => folder.
    /// Relative filenames resolve against baseURL directory when supplied; a leading / or \\ is root-relative.
    /// The last duplicate filename wins. Handles UTF-8 BOM and RFC4180-style quoted CSV with doubled quotes.
    public static func parseEFU(_ text: String, baseURL: URL? = nil) -> [FileListItem] {
        let rows = parseCSV(stripBOM(text))
        guard let headerRow = rows.first else { return [] }

        var columns: [String: Int] = [:]
        for (index, rawName) in headerRow.enumerated() {
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !name.isEmpty { columns[name] = index }
        }
        guard columns["filename"] != nil else { return [] }

        func field(_ name: String, in row: [String]) -> String? {
            guard let index = columns[name], index < row.count else { return nil }
            return row[index]
        }

        // Keep first-seen order, but let the last row for a given path supply the values.
        var orderedPaths: [String] = []
        var itemsByPath: [String: FileListItem] = [:]

        for row in rows.dropFirst() {
            guard row.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
                  let rawFilename = field("filename", in: row) else { continue }

            let filename = rawFilename.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !filename.isEmpty else { continue }

            let path = resolvePath(filename, baseURL: baseURL)
            let attributes = Int(field("attributes", in: row)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
            let size = Int64(field("size", in: row)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
            let tags = parseTags(field("tags", in: row))
            let comment = optionalText(field("comment", in: row))

            let item = FileListItem(
                path: path,
                isDirectory: attributes & 16 != 0,
                size: size,
                modifiedAt: parseDate(field("date modified", in: row)),
                createdAt: parseDate(field("date created", in: row)),
                tags: tags,
                comment: comment
            )

            if itemsByPath[path] == nil { orderedPaths.append(path) }
            itemsByPath[path] = item
        }

        return orderedPaths.compactMap { itemsByPath[$0] }
    }

    /// Produces a valid EFU CSV with header
    /// Filename,Size,Date Modified,Date Created,Attributes,Tags,Comment
    /// Dates must be ISO 8601. Tags are semicolon-separated inside one quoted CSV field.
    /// Attributes: 16 for directories, 32 for files.
    public static func encodeEFU(_ items: [FileListItem]) -> String {
        let formatter = isoFormatter(fractional: true)
        var lines = [header]

        for item in items {
            let tags = "\"" + item.tags.joined(separator: ";")
                .replacingOccurrences(of: "\"", with: "\"\"") + "\""
            let values = [
                csvField(item.path),
                String(item.size),
                item.modifiedAt.map { formatter.string(from: $0) } ?? "",
                item.createdAt.map { formatter.string(from: $0) } ?? "",
                item.isDirectory ? "16" : "32",
                tags,
                item.comment.map { csvField($0) } ?? ""
            ]
            lines.append(values.joined(separator: ","))
        }

        return lines.joined(separator: "\n") + "\n"
    }

    public static func items(from entries: [IndexEntry]) -> [FileListItem] {
        entries.map { entry in
            FileListItem(
                path: entry.path,
                isDirectory: entry.isDirectory,
                size: entry.size,
                modifiedAt: entry.modifiedAt,
                createdAt: entry.createdAt,
                tags: entry.tags,
                comment: entry.comment
            )
        }
    }

    // MARK: - CSV

    private static func stripBOM(_ text: String) -> String {
        text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
    }

    /// Minimal RFC 4180 parser: quoted fields, doubled quotes, commas and
    /// newlines inside quotes, and CRLF/LF/CR record separators.
    private static func parseCSV(_ text: String) -> [[String]] {
        let characters = Array(text)
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var index = 0

        while index < characters.count {
            let character = characters[index]

            if inQuotes {
                if character == "\"" {
                    if index + 1 < characters.count && characters[index + 1] == "\"" {
                        field.append("\"")
                        index += 2
                        continue
                    }
                    inQuotes = false
                    index += 1
                    continue
                }
                field.append(character)
                index += 1
                continue
            }

            switch character {
            case "\"":
                if field.isEmpty {
                    inQuotes = true
                } else {
                    field.append(character)
                }
                index += 1
            case ",":
                row.append(field)
                field = ""
                index += 1
            case "\r\n", "\n":
                // Swift treats CRLF as one Character grapheme cluster.
                row.append(field)
                field = ""
                rows.append(row)
                row = []
                index += 1
            case "\r":
                row.append(field)
                field = ""
                rows.append(row)
                row = []
                index += 1
                if index < characters.count && characters[index] == "\n" { index += 1 }
            default:
                field.append(character)
                index += 1
            }
        }

        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        return rows
    }

    private static func csvField(_ value: String) -> String {
        let needsQuoting = value.contains { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }
        return needsQuoting
            ? "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            : value
    }

    // MARK: - Values

    private static func optionalText(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func parseTags(_ raw: String?) -> [String] {
        guard let raw else { return [] }
        return raw.split(separator: ";", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func isoFormatter(fractional: Bool) -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        var options: ISO8601DateFormatter.Options = [.withInternetDateTime]
        if fractional { options.insert(.withFractionalSeconds) }
        formatter.formatOptions = options
        return formatter
    }

    private static func parseDate(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        // Windows FILETIME: 100-nanosecond ticks since 1601-01-01 UTC.
        if let ticks = Int64(value), ticks > 0 {
            let seconds = Double(ticks) / ticksPerSecond - filetimeEpochOffset
            return seconds.isFinite ? Date(timeIntervalSince1970: seconds) : nil
        }

        if let date = isoFormatter(fractional: true).date(from: value) { return date }
        if let date = isoFormatter(fractional: false).date(from: value) { return date }

        let hasTimeZone = value.range(of: "(Z|[+-]\\d{2}:?\\d{2})$", options: .regularExpression) != nil
        if !hasTimeZone {
            if let date = isoFormatter(fractional: true).date(from: value + "Z") { return date }
            if let date = isoFormatter(fractional: false).date(from: value + "Z") { return date }
        }

        let dateOnly = ISO8601DateFormatter()
        dateOnly.timeZone = TimeZone(secondsFromGMT: 0)
        dateOnly.formatOptions = [.withFullDate]
        if let date = dateOnly.date(from: value) { return date }

        let legacy = DateFormatter()
        legacy.dateFormat = "yyyy-MM-dd HH:mm:ss"
        legacy.locale = Locale(identifier: "en_US_POSIX")
        legacy.timeZone = TimeZone(secondsFromGMT: 0)
        return legacy.date(from: value)
    }

    // MARK: - Paths

    private static func resolvePath(_ filename: String, baseURL: URL?) -> String {
        let value = filename.replacingOccurrences(of: "\\", with: "/")
        guard !value.isEmpty else { return filename }

        let isRootRelative = value.hasPrefix("/")
            || value.range(of: "^[A-Za-z]:/", options: .regularExpression) != nil
        if isRootRelative || baseURL == nil { return value }

        let resolved = baseURL!.appendingPathComponent(value)
        return resolved.isFileURL ? resolved.standardizedFileURL.path : resolved.path
    }
}
