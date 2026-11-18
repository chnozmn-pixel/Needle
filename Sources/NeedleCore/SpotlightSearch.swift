import Foundation

/// Hybrid fallback: Spotlight results are merged with our own index. This
/// covers network shares and files that changed before FSEvents was attached.
public struct SpotlightHit: Sendable, Equatable, Identifiable {
    public let entry: IndexEntry
    public var id: UInt64 { entry.id }
}

public enum SpotlightSearch {

    public static func search(query: ParsedQuery, roots: [String], limit: Int = 300) async -> [SpotlightHit] {
        let terms = query.nameTerms + query.pathTerms
        guard !terms.isEmpty else { return [] }

        return await Task.detached(priority: .utility) {
            let expression = terms
                .map { "(kMDItemDisplayName == '*\(escape($0))'c || kMDItemPath == '*\(escape($0))'c)" }
                .joined(separator: " && ")

            var seen = Set<String>()
            var hits: [SpotlightHit] = []

            for root in roots.prefix(8) {
                guard let output = runMDQuery(expression, in: root, limit: limit) else { continue }
                for path in output.split(separator: "\n") {
                    let clean = String(path).trimmingCharacters(in: .whitespaces)
                    guard !clean.isEmpty, clean.hasPrefix("/"), seen.insert(clean).inserted else { continue }
                    guard let entry = FileSystem.entry(at: clean), matches(entry, query) else { continue }
                    hits.append(SpotlightHit(entry: entry))
                    if hits.count >= limit { break }
                }
                if hits.count >= limit { break }
            }
            return hits
        }.value
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func runMDQuery(_ expression: String, in root: String, limit: Int) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        process.arguments = ["-onlyin", root, "-maxCount", String(limit), expression]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }

    private static func matches(_ entry: IndexEntry, _ query: ParsedQuery) -> Bool {
        if entry.isDirectory && !query.includeFolders { return false }
        if !entry.isDirectory && !query.includeFiles { return false }
        if !query.allowedExtensions.isEmpty || !query.deniedExtensions.isEmpty {
            let ext = (entry.name as NSString).pathExtension.lowercased()
            if !query.allowedExtensions.isEmpty && !query.allowedExtensions.contains(ext) { return false }
            if query.deniedExtensions.contains(ext) { return false }
        }
        if let min = query.minSize, entry.size < min { return false }
        if let max = query.maxSize, entry.size > max { return false }

        let lowerName = entry.name.lowercased()
        let lowerPath = entry.path.lowercased()
        for term in query.excludedTerms where !term.isEmpty {
            let needle = term.lowercased()
            if lowerName.contains(needle) || lowerPath.contains(needle) { return false }
        }

        if let min = query.modifiedAfter, (entry.modifiedAt ?? .distantPast) < min { return false }
        if let max = query.modifiedBefore, (entry.modifiedAt ?? .distantFuture) > max { return false }
        if let min = query.createdAfter, (entry.createdAt ?? .distantPast) < min { return false }
        if let max = query.createdBefore, (entry.createdAt ?? .distantFuture) > max { return false }
        return true
    }
}
