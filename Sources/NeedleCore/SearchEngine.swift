import Foundation

/// In-memory search index with Everything-style expression evaluation.
///
/// Search only touches memory for normal queries. N-gram posting lists provide
/// a coarse candidate set; every candidate is then verified against the full
/// expression. Content, duplicate, child and existence functions use a lazily
/// built snapshot context and never mutate the index.
private struct SearchSlot {
    var entry: IndexEntry
    var lowerName: String
    var lowerPath: String
    var foldedName: String
    var foldedPath: String
    var active: Bool
}

public final class SearchEngine: @unchecked Sendable {

    private let lock = NSLock()
    private var slots: [SearchSlot] = []
    private var freeSlots: [UInt32] = []
    private var idToSlot: [UInt64: UInt32] = [:]
    private var namePostings: [Int: [UInt32]] = [:]
    private var pathPostings: [Int: [UInt32]] = [:]
    private var activeCount = 0
    private var bulkMode = false

    public init() {}

    // MARK: - Public lifecycle

    public func rebuild(from entries: [IndexEntry]) {
        lock.lock()
        defer { lock.unlock() }
        clearLocked()
        bulkMode = true
        for entry in entries { appendLocked(entry) }
        sortPostingsLocked()
        bulkMode = false
    }

    /// Clears the engine and accepts unsorted appends until `finishBulk()`.
    public func beginBulk() {
        lock.lock()
        defer { lock.unlock() }
        clearLocked()
        bulkMode = true
    }

    public func finishBulk() {
        lock.lock()
        defer { lock.unlock() }
        sortPostingsLocked()
        bulkMode = false
    }

    public func apply(_ changes: [IndexChange]) {
        lock.lock()
        defer { lock.unlock() }

        for change in changes {
            switch change {
            case .delete(let path) where !bulkMode:
                removeLocked(id: EntryID.forPath(path))
            case .upsert(let entry) where !bulkMode:
                removeLocked(id: entry.id)
                let slotID = takeSlotLocked()
                slots[Int(slotID)] = makeSlot(from: entry)
                slots[Int(slotID)].active = true
                activeCount += 1
                idToSlot[entry.id] = slotID
                addPostingsLocked(for: entry, slotID: slotID)
            case .upsert(let entry):
                appendLocked(entry)
            case .delete:
                break
            }
        }
    }

    public func indexedCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return activeCount
    }

    // MARK: - Locked helpers

    private func clearLocked() {
        slots = []
        freeSlots = []
        idToSlot = [:]
        namePostings = [:]
        pathPostings = [:]
        activeCount = 0
    }

    private func appendLocked(_ entry: IndexEntry) {
        let slotID = UInt32(slots.count)
        slots.append(makeSlot(from: entry))
        idToSlot[entry.id] = slotID
        activeCount += 1
        appendPostingsLocked(for: entry, slotID: slotID)
    }

    private func takeSlotLocked() -> UInt32 {
        if let reused = freeSlots.popLast() { return reused }
        let slotID = UInt32(slots.count)
        slots.append(makeSlot(from: IndexEntry.make(
            path: "/__empty__\(slotID)", isDirectory: false, size: 0,
            modifiedAt: nil, createdAt: nil
        )))
        slots[Int(slotID)].active = false
        return slotID
    }

    private func sortPostingsLocked() {
        for key in Array(namePostings.keys) { namePostings[key]?.sort() }
        for key in Array(pathPostings.keys) { pathPostings[key]?.sort() }
    }

    private func makeSlot(from entry: IndexEntry) -> SearchSlot {
        let lowerName = entry.name.lowercased()
        let lowerPath = entry.path.lowercased()
        return SearchSlot(
            entry: entry,
            lowerName: lowerName,
            lowerPath: lowerPath,
            foldedName: Self.fold(lowerName),
            foldedPath: Self.fold(lowerPath),
            active: true
        )
    }

    private func removeLocked(id: UInt64) {
        guard let slotID = idToSlot.removeValue(forKey: id) else { return }
        let entry = slots[Int(slotID)].entry
        removePostingsLocked(for: entry, slotID: slotID)
        slots[Int(slotID)].active = false
        activeCount -= 1
        freeSlots.append(slotID)
    }

    private static func fold(_ value: String) -> String {
        value.folding(options: [.diacriticInsensitive], locale: nil)
    }

    private static func key(_ length: Int, _ bytes: ArraySlice<UInt8>) -> Int {
        var value = length << 24
        for (offset, byte) in bytes.enumerated() {
            value |= Int(byte) << (8 * offset)
        }
        return value
    }

    private static func trigrams(_ string: String) -> [Int] {
        let bytes = Array(string.utf8)
        if bytes.isEmpty { return [] }
        if bytes.count < 3 { return [key(bytes.count, ArraySlice(bytes))] }

        var result: [Int] = []
        result.reserveCapacity(bytes.count - 2)
        var seen = Set<Int>()
        for i in 0...(bytes.count - 3) {
            let value = key(3, bytes[i...i + 2])
            if seen.insert(value).inserted { result.append(value) }
        }
        return result
    }

    private static func queryKey(_ term: String) -> Int? {
        let bytes = Array(term.lowercased().utf8)
        guard !bytes.isEmpty else { return nil }
        let length = min(3, bytes.count)
        return key(length, bytes.prefix(length))
    }

    private func appendPostingsLocked(for entry: IndexEntry, slotID: UInt32) {
        for value in Self.trigrams(entry.name.lowercased()) {
            namePostings[value, default: []].append(slotID)
        }
        for value in Self.trigrams(entry.path.lowercased()) {
            pathPostings[value, default: []].append(slotID)
        }
    }

    private func addPostingsLocked(for entry: IndexEntry, slotID: UInt32) {
        for value in Self.trigrams(entry.name.lowercased()) {
            insertLocked(slotID, key: value, into: &namePostings)
        }
        for value in Self.trigrams(entry.path.lowercased()) {
            insertLocked(slotID, key: value, into: &pathPostings)
        }
    }

    private func removePostingsLocked(for entry: IndexEntry, slotID: UInt32) {
        for value in Self.trigrams(entry.name.lowercased()) {
            removeLocked(slotID, key: value, from: &namePostings)
        }
        for value in Self.trigrams(entry.path.lowercased()) {
            removeLocked(slotID, key: value, from: &pathPostings)
        }
    }

    private func insertLocked(_ value: UInt32, key: Int, into postings: inout [Int: [UInt32]]) {
        var list = postings[key] ?? []
        let position = lowerBound(list, value)
        if position < list.count && list[position] == value { return }
        list.insert(value, at: position)
        postings[key] = list
    }

    private func removeLocked(_ value: UInt32, key: Int, from postings: inout [Int: [UInt32]]) {
        guard var list = postings[key] else { return }
        let position = lowerBound(list, value)
        guard position < list.count, list[position] == value else { return }
        list.remove(at: position)
        if list.isEmpty { postings.removeValue(forKey: key) }
        else { postings[key] = list }
    }

    private func lowerBound(_ list: [UInt32], _ value: UInt32) -> Int {
        var low = 0
        var high = list.count
        while low < high {
            let mid = (low + high) / 2
            if list[mid] < value { low = mid + 1 } else { high = mid }
        }
        return low
    }

    // MARK: - Candidate pruning

    /// Returns a conservative candidate set, or nil when the expression cannot
    /// be narrowed safely (regex, wildcards, negations, cross-entry functions).
    private func candidateSet(for expression: QueryExpression) -> Set<UInt32>? {
        switch expression {
        case .text(let term):
            guard Self.canUsePostings(for: term) else { return nil }
            guard let value = Self.queryKey(term.text) else { return nil }
            let postings = (term.field == .path || term.field == .parentPath || term.field == .root)
                ? pathPostings : namePostings
            guard let list = postings[value] else { return Set() }
            return Set(list)

        case .and(let items):
            var result: Set<UInt32>?
            for item in items {
                guard let found = candidateSet(for: item) else { continue }
                result = result.map { $0.intersection(found) } ?? found
                if result?.isEmpty == true { return Set() }
            }
            return result

        case .or(let items):
            var result: Set<UInt32> = Set()
            for item in items {
                guard let found = candidateSet(for: item) else { return nil }
                result.formUnion(found)
            }
            return result

        case .not:
            return nil

        default:
            return nil
        }
    }

    private static func canUsePostings(for term: TextTerm) -> Bool {
        guard term.field != .content else { return false }
        guard term.mode != .regex, term.mode != .wildcard else { return false }
        guard !term.options.caseSensitive else { return false }
        guard term.options.diacritics || term.text.utf8.allSatisfy({ $0 < 128 }) else { return false }
        guard !term.options.ignorePunctuation, !term.options.ignoreWhitespace else { return false }
        return term.text.utf8.count >= 3
    }

    // MARK: - Search

    public func search(_ query: ParsedQuery, limit: Int = 10_000) -> [SearchResult] {
        let effectiveLimit = min(limit, query.resultLimit ?? limit)

        lock.lock()
        let snapshot = slots
        let candidates = candidateSet(for: query.expression)
        lock.unlock()

        let context = EvaluationContext(slots: snapshot)
        let indices: [Int]
        if let candidates {
            indices = candidates.compactMap { slot in
                Int(slot) < snapshot.count && snapshot[Int(slot)].active ? Int(slot) : nil
            }.sorted()
        } else {
            indices = snapshot.indices.filter { snapshot[$0].active }
        }

        var results: [SearchResult] = []
        results.reserveCapacity(min(effectiveLimit, 4096))

        for index in indices {
            let slot = snapshot[index]
            if evaluate(query.expression, slot: slot, context: context) {
                results.append(SearchResult(entry: slot.entry, source: .index))
                if results.count >= effectiveLimit { break }
            }
        }

        if !query.distinctFields.isEmpty {
            results = applyDistinct(results, fields: query.distinctFields)
        }
        return results
    }

    // MARK: - Expression evaluation

    private func evaluate(
        _ expression: QueryExpression,
        slot: SearchSlot,
        context: EvaluationContext
    ) -> Bool {
        switch expression {
        case .all:
            return true
        case .none:
            return false

        case .text(let term):
            let value = Self.value(for: term.field, slot: slot, context: context)
            return Self.matches(term: term, value: value)

        case .ext(let values, let negated):
            guard !slot.entry.isDirectory else { return negated }
            let ext = (slot.entry.name as NSString).pathExtension.lowercased()
            let match = values.contains { pattern in
                Self.matchesWildcard(pattern: pattern, value: ext, separators: false)
            }
            return negated ? !match : match

        case .type(let files, let folders):
            return slot.entry.isDirectory ? folders : files

        case .numeric(let comparison):
            return Self.matchesNumeric(comparison, slot: slot, context: context)

        case .date(let comparison):
            return Self.matchesDate(comparison, slot: slot)

        case .empty:
            guard slot.entry.isDirectory else { return false }
            return context.children[slot.entry.id]?.isEmpty ?? true

        case .child(let term, let kind, let recursive):
            guard slot.entry.isDirectory else { return false }
            return context.hasChild(
                of: slot.entry.id,
                matching: term,
                kind: kind,
                recursive: recursive
            )

        case .exists(let term):
            return context.hasExistingPath(term.text, for: slot.entry)

        case .duplicate(let fields, let min, let max):
            let count = context.duplicateCount(for: slot.entry, fields: fields)
            if let min, count < min { return false }
            if let max, count > max { return false }
            return count > 1

        case .kind(let value):
            let token = Self.kind(of: slot.entry)
            let localized = L(Self.kindLocalizationKey(for: token)).lowercased()
            let query = value.lowercased()
            return token.lowercased().contains(query) || localized.contains(query)

        case .and(let items):
            for item in items where !evaluate(item, slot: slot, context: context) { return false }
            return true

        case .or(let items):
            if items.isEmpty { return false }
            for item in items where evaluate(item, slot: slot, context: context) { return true }
            return false

        case .not(let item):
            return !evaluate(item, slot: slot, context: context)
        }
    }

    // MARK: - Text matching

    private static func value(for field: QueryField, slot: SearchSlot, context: EvaluationContext) -> String {
        switch field {
        case .name:
            return slot.entry.name
        case .stem:
            let name = (slot.entry.name as NSString).deletingPathExtension
            return name
        case .`extension`:
            return (slot.entry.name as NSString).pathExtension
        case .path:
            return slot.entry.path
        case .parentPath:
            return slot.entry.parentPath
        case .root:
            let components = slot.entry.path.split(separator: "/", omittingEmptySubsequences: true)
            return components.first.map(String.init) ?? "/"
        case .content:
            return context.content(for: slot.entry) ?? ""
        }
    }

    private static func normalized(_ value: String, options: TextOptions) -> String {
        var result = options.caseSensitive ? value : value.lowercased()
        if !options.diacritics { result = fold(result) }

        if options.ignorePunctuation {
            result = String(result.map { $0.isLetter || $0.isNumber || $0.isWhitespace ? $0 : " " })
        }
        if options.ignoreWhitespace {
            result = result.filter { !$0.isWhitespace }
        }
        return result
    }

    fileprivate static func matches(term: TextTerm, value rawValue: String) -> Bool {
        let value = normalized(rawValue, options: term.options)
        let needle = normalized(term.text, options: term.options)
        guard !needle.isEmpty else { return true }

        switch term.mode {
        case .contains:
            return value.contains(needle)
        case .whole:
            return value == needle
        case .prefix:
            return value.hasPrefix(needle)
        case .suffix:
            return value.hasSuffix(needle)
        case .wholeWords:
            var start = value.startIndex
            while let range = value.range(of: needle, range: start..<value.endIndex) {
                let beforeOK = range.lowerBound == value.startIndex
                    || !isWordCharacter(value[value.index(before: range.lowerBound)])
                let afterOK = range.upperBound == value.endIndex
                    || !isWordCharacter(value[range.upperBound])
                if beforeOK && afterOK { return true }
                start = range.upperBound
                if start == value.endIndex { break }
            }
            return false
        case .wildcard:
            return matchesWildcard(pattern: needle, value: value, separators: true)
        case .regex:
            return matchesRegex(pattern: term.text, value: rawValue, options: term.options)
        }
    }

    private static func isWordCharacter(_ ch: Character) -> Bool {
        ch.isLetter || ch.isNumber || ch == "_"
    }

    private static func matchesRegex(pattern: String, value: String, options: TextOptions) -> Bool {
        var regexOptions: NSRegularExpression.Options = []
        if !options.caseSensitive { regexOptions.insert(.caseInsensitive) }
        guard let regex = try? NSRegularExpression(pattern: pattern, options: regexOptions) else { return false }
        let range = NSRange(value.startIndex..., in: value)
        return regex.firstMatch(in: value, range: range) != nil
    }

    /// Wildcard matcher with Everything semantics: `*` skips separators, `**`
    /// crosses separators, `?` matches one non-separator character.
    private static func matchesWildcard(pattern: String, value: String, separators: Bool) -> Bool {
        let p = Array(pattern.lowercased())
        let v = Array(value.lowercased())
        var pIndex = 0
        var vIndex = 0
        var star: Int?
        var starCrosses = false
        var starMatch = 0

        func isSeparator(_ ch: Character) -> Bool { ch == "/" || ch == "\\" }

        while vIndex < v.count {
            if pIndex < p.count, p[pIndex] == "?" {
                if separators && isSeparator(v[vIndex]) {
                    if let star { pIndex = star + (starCrosses ? 2 : 1); vIndex = starMatch + 1; starMatch = vIndex }
                    else { return false }
                    continue
                }
                pIndex += 1
                vIndex += 1
            } else if pIndex < p.count, p[pIndex] == "*" {
                let double = pIndex + 1 < p.count && p[pIndex + 1] == "*"
                star = pIndex
                starCrosses = double || !separators
                starMatch = vIndex
                pIndex += double ? 2 : 1
            } else if pIndex < p.count, p[pIndex] == v[vIndex] {
                pIndex += 1
                vIndex += 1
            } else if let star {
                let crosses = starCrosses || (pIndex < p.count && p[pIndex] == "*")
                if !crosses, isSeparator(v[vIndex]) { return false }
                starMatch += 1
                vIndex = starMatch
                pIndex = star + (starCrosses ? 2 : 1)
            } else {
                return false
            }
        }
        while pIndex < p.count, p[pIndex] == "*" { pIndex += 1 }
        return pIndex == p.count
    }

    // MARK: - Numeric / date / kind

    private static func matchesNumeric(
        _ comparison: NumericComparison,
        slot: SearchSlot,
        context: EvaluationContext
    ) -> Bool {
        let value: Int64
        switch comparison.property {
        case .size:
            value = slot.entry.size
        case .nameLength:
            value = Int64(slot.entry.name.utf16.count)
        case .pathLength:
            value = Int64(slot.entry.path.utf16.count)
        case .childCount:
            value = Int64(context.children[slot.entry.id]?.count ?? 0)
        case .childFileCount:
            value = Int64(context.children[slot.entry.id]?.filter { !$0.isDirectory }.count ?? 0)
        case .childFolderCount:
            value = Int64(context.children[slot.entry.id]?.filter { $0.isDirectory }.count ?? 0)
        case .parentCount:
            value = Int64(max(0, slot.entry.path.split(separator: "/", omittingEmptySubsequences: true).count - 1))
        }

        if let min = comparison.min {
            if comparison.inclusiveMin ? value < min : value <= min { return false }
        }
        if let max = comparison.max {
            if comparison.inclusiveMax ? value > max : value >= max { return false }
        }
        return true
    }

    private static func matchesDate(_ comparison: DateComparison, slot: SearchSlot) -> Bool {
        let date: Date?
        switch comparison.property {
        case .modified: date = slot.entry.modifiedAt
        case .created: date = slot.entry.createdAt
        case .accessed: date = slot.entry.modifiedAt
        }
        guard let date else { return comparison.min == nil && comparison.max == nil }
        if let min = comparison.min, date < min { return false }
        if let max = comparison.max, date > max { return false }
        return true
    }

    /// Stable, language-neutral token used by `kind:` queries and sorting.
    private static func kind(of entry: IndexEntry) -> String {
        if entry.isDirectory { return "folder" }
        switch (entry.name as NSString).pathExtension.lowercased() {
        case "jpg", "jpeg", "png", "gif", "bmp", "tiff", "webp", "heic", "svg", "psd": return "image"
        case "mp4", "mov", "avi", "mkv", "wmv", "webm", "m4v", "mpg": return "video"
        case "mp3", "wav", "flac", "aac", "m4a", "ogg", "wma": return "audio"
        case "zip", "rar", "7z", "tar", "gz", "xz", "iso": return "archive"
        case "exe", "app", "dmg", "pkg", "sh", "command": return "application"
        case "pdf", "doc", "docx", "txt", "md", "rtf", "odt", "pages", "xls", "xlsx", "ppt", "pptx": return "document"
        default: return "file"
        }
    }

    /// Turkish source key used to resolve the localized alias for a kind token.
    private static func kindLocalizationKey(for token: String) -> String {
        switch token {
        case "folder": return "Klasör"
        case "image": return "görsel"
        case "video": return "video"
        case "audio": return "ses"
        case "archive": return "arşiv"
        case "application": return "uygulama"
        case "document": return "belge"
        default: return "Dosya"
        }
    }

    // MARK: - Distinct

    private func applyDistinct(_ results: [SearchResult], fields: [String]) -> [SearchResult] {
        let normalized = fields.map { $0.lowercased() }
        var seen = Set<String>()
        var output: [SearchResult] = []
        for result in results {
            let key = normalized.map { field in
                switch field {
                case "name": return result.entry.name.lowercased()
                case "stem": return (result.entry.name as NSString).deletingPathExtension.lowercased()
                case "ext", "extension": return (result.entry.name as NSString).pathExtension.lowercased()
                case "path", "full-path": return result.entry.path.lowercased()
                case "parent", "location": return result.entry.parentPath.lowercased()
                case "size": return String(result.entry.size)
                default: return ""
                }
            }.joined(separator: "\u{1}")
            if seen.insert(key).inserted { output.append(result) }
        }
        return output
    }
}

// MARK: - Evaluation context

private final class EvaluationContext {
    private let slots: [SearchSlot]
    let children: [UInt64: [IndexEntry]]

    private var contentCache: [UInt64: String?] = [:]
    private var hashCache: [UInt64: String] = [:]
    private var duplicateCache: [String: Int] = [:]
    private var pathIndex: [String: IndexEntry]?

    init(slots: [SearchSlot]) {
        self.slots = slots
        var grouped: [UInt64: [IndexEntry]] = [:]
        for slot in slots where slot.active {
            grouped[slot.entry.parentID, default: []].append(slot.entry)
        }
        self.children = grouped
    }

    func content(for entry: IndexEntry) -> String? {
        if let cached = contentCache[entry.id] { return cached }
        let value: String?
        if !entry.isDirectory,
           let data = try? Data(contentsOf: entry.url, options: .mappedIfSafe),
           data.count <= 8 * 1024 * 1024 {
            value = String(data: data, encoding: .utf8)
                ?? String(decoding: data, as: UTF8.self)
        } else {
            value = nil
        }
        contentCache[entry.id] = value
        return value
    }

    func hasChild(
        of parentID: UInt64,
        matching term: TextTerm,
        kind: ChildKind,
        recursive: Bool
    ) -> Bool {
        guard let direct = children[parentID] else { return false }
        for child in direct {
            if kind == .file && child.isDirectory { continue }
            if kind == .folder && !child.isDirectory { continue }
            if SearchEngine.matches(term: term, value: child.name) { return true }
        }
        if recursive {
            for child in direct where child.isDirectory {
                if hasChild(of: child.id, matching: term, kind: kind, recursive: true) { return true }
            }
        }
        return false
    }

    func hasExistingPath(_ pattern: String, for entry: IndexEntry) -> Bool {
        let stem = (entry.name as NSString).deletingPathExtension
        let ext = (entry.name as NSString).pathExtension
        var substituted = pattern
        for (token, value) in [
            ("$stem:", stem), ("$name:", entry.name), ("$ext:", ext),
            ("$extension:", ext), ("$path:", entry.parentPath), ("$parent:", entry.parentPath)
        ] {
            substituted = substituted.replacingOccurrences(of: token, with: value)
        }
        let target: String
        if substituted.hasPrefix("/") {
            target = substituted
        } else {
            target = (entry.parentPath as NSString).appendingPathComponent(substituted)
        }
        return entryIndex()[target.lowercased()] != nil
    }

    func duplicateCount(for entry: IndexEntry, fields: [DuplicateField]) -> Int {
        let key = duplicateKey(for: entry, fields: fields)
        if let cached = duplicateCache[key] { return cached }
        var count = 0
        for slot in slots where slot.active {
            if duplicateKey(for: slot.entry, fields: fields) == key { count += 1 }
        }
        duplicateCache[key] = count
        return count
    }

    private func duplicateKey(for entry: IndexEntry, fields: [DuplicateField]) -> String {
        var parts: [String] = []
        for field in fields {
            switch field {
            case .name: parts.append(entry.name.lowercased())
            case .stem: parts.append((entry.name as NSString).deletingPathExtension.lowercased())
            case .`extension`: parts.append((entry.name as NSString).pathExtension.lowercased())
            case .path: parts.append(entry.path.lowercased())
            case .parent: parts.append(entry.parentPath.lowercased())
            case .size: parts.append(String(entry.size))
            case .content:
                parts.append(String(entry.size))
                parts.append(contentHash(for: entry))
            }
        }
        return parts.joined(separator: "\u{1}")
    }

    private func contentHash(for entry: IndexEntry) -> String {
        if let cached = hashCache[entry.id] { return cached }
        guard !entry.isDirectory,
              let data = try? Data(contentsOf: entry.url, options: .mappedIfSafe),
              data.count <= 8 * 1024 * 1024 else {
            hashCache[entry.id] = ""
            return ""
        }
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in data {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        let value = String(hash, radix: 16)
        hashCache[entry.id] = value
        return value
    }

    private func entryIndex() -> [String: IndexEntry] {
        if let pathIndex { return pathIndex }
        var index: [String: IndexEntry] = [:]
        for slot in slots where slot.active { index[slot.entry.path.lowercased()] = slot.entry }
        pathIndex = index
        return index
    }
}
