import Foundation
import Darwin

/// Reads and writes Finder tags and comments through extended attributes.
/// Foundation's URL resource-value setters for these keys are not available on
/// macOS 13, so the xattr representation used by Finder is handled directly.
public enum FileMetadata {
    private static let tagsKey = "com.apple.metadata:_kMDItemUserTags"
    private static let commentKey = "com.apple.metadata:kMDItemComment"

    // MARK: - Reading

    public static func readTags(at path: String) -> [String] {
        guard let data = readXattr(tagsKey, from: path),
              let values = try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil
              ) as? [String] else { return [] }
        return values.compactMap { raw in
            // Finder stores a color suffix after a newline, e.g. "Work\n4".
            let name = raw.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? raw
            return name.isEmpty ? nil : name
        }
    }

    public static func readComment(at path: String) -> String? {
        guard let data = readXattr(commentKey, from: path),
              let value = try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil
              ) as? String else { return nil }
        return value
    }

    // MARK: - Writing

    /// Replaces the complete tag list on every path.
    public static func setTags(_ tags: [String], for paths: [String]) {
        let cleaned = tags
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        for path in paths { writeXattr(tagsKey, value: cleaned, at: path) }
    }

    public static func addTags(_ tags: [String], to paths: [String]) {
        let additions = tags
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        for path in paths {
            var merged = readTags(at: path)
            for tag in additions where !merged.contains(tag) { merged.append(tag) }
            guard !merged.isEmpty else { continue }
            writeXattr(tagsKey, value: merged, at: path)
        }
    }

    public static func removeTags(_ tags: [String], from paths: [String]) {
        let removal = Set(tags)
        for path in paths {
            let remaining = readTags(at: path).filter { !removal.contains($0) }
            if remaining.isEmpty { removeXattr(tagsKey, at: path) }
            else { writeXattr(tagsKey, value: remaining, at: path) }
        }
    }

    /// Pass nil to clear the Finder comment.
    public static func setComment(_ comment: String?, for paths: [String]) {
        let cleaned = comment?.trimmingCharacters(in: .whitespacesAndNewlines)
        for path in paths { writeXattr(commentKey, value: cleaned, at: path) }
    }

    // MARK: - xattr helpers

    private static func readXattr(_ key: String, from path: String) -> Data? {
        let size = path.withCString { filePath in
            key.withCString { name in getxattr(filePath, name, nil, 0, 0, 0) }
        }
        guard size > 0 else { return nil }
        var data = Data(count: Int(size))
        let read = data.withUnsafeMutableBytes { buffer in
            path.withCString { filePath in
                key.withCString { name in
                    getxattr(filePath, name, buffer.baseAddress, Int(size), 0, 0)
                }
            }
        }
        guard read >= 0 else { return nil }
        return data
    }

    private static func writeXattr(_ key: String, value: Any?, at path: String) {
        guard let value else {
            removeXattr(key, at: path)
            return
        }
        guard let data = try? PropertyListSerialization.data(
            fromPropertyList: value, format: .binary, options: 0
        ) else { return }
        _ = path.withCString { filePath in
            key.withCString { name in
                data.withUnsafeBytes { buffer in
                    setxattr(filePath, name, buffer.baseAddress, data.count, 0, 0)
                }
            }
        }
    }

    private static func removeXattr(_ key: String, at path: String) {
        _ = path.withCString { filePath in
            key.withCString { name in removexattr(filePath, name, 0) }
        }
    }
}
