import Foundation
import SwiftUI
import NeedleCore

struct SavedSearch: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String
    var query: String
}

struct RunHistoryEntry: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var path: String
    var query: String
    var date: Date
}

enum AppTheme: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return L("Sistem")
        case .light: return L("Açık")
        case .dark: return L("Koyu")
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// User-facing preferences that are not part of the index database.
@MainActor
final class Preferences: ObservableObject {

    @Published var searchHistory: [String] {
        didSet { defaults.set(Array(searchHistory.prefix(100)), forKey: Keys.searchHistory) }
    }
    @Published var savedSearches: [SavedSearch] {
        didSet { encode(savedSearches, forKey: Keys.savedSearches) }
    }
    @Published var runHistory: [RunHistoryEntry] {
        didSet { encode(Array(runHistory.prefix(200)), forKey: Keys.runHistory) }
    }

    @Published var matchCase: Bool {
        didSet { defaults.set(matchCase, forKey: Keys.matchCase) }
    }
    @Published var wholeWords: Bool {
        didSet { defaults.set(wholeWords, forKey: Keys.wholeWords) }
    }
    @Published var matchPath: Bool {
        didSet { defaults.set(matchPath, forKey: Keys.matchPath) }
    }
    @Published var matchDiacritics: Bool {
        didSet { defaults.set(matchDiacritics, forKey: Keys.matchDiacritics) }
    }
    @Published var ignorePunctuation: Bool {
        didSet { defaults.set(ignorePunctuation, forKey: Keys.ignorePunctuation) }
    }
    @Published var wildcardsEnabled: Bool {
        didSet { defaults.set(wildcardsEnabled, forKey: Keys.wildcardsEnabled) }
    }
    @Published var regexEnabled: Bool {
        didSet { defaults.set(regexEnabled, forKey: Keys.regexEnabled) }
    }
    @Published var resultLimit: Int {
        didSet { defaults.set(resultLimit, forKey: Keys.resultLimit) }
    }
    @Published var theme: AppTheme {
        didSet { defaults.set(theme.rawValue, forKey: Keys.theme) }
    }
    @Published var viewMode: ResultViewMode {
        didSet { defaults.set(viewMode.rawValue, forKey: Keys.viewMode) }
    }
    @Published var visibleColumns: Set<String> {
        didSet { defaults.set(Array(visibleColumns).sorted(), forKey: Keys.visibleColumns) }
    }
    @Published var requireAuthForSettings: Bool {
        didSet { defaults.set(requireAuthForSettings, forKey: Keys.requireAuthForSettings) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        searchHistory = defaults.stringArray(forKey: Keys.searchHistory) ?? []
        savedSearches = Self.decode(for: defaults, key: Keys.savedSearches) ?? []
        runHistory = Self.decode(for: defaults, key: Keys.runHistory) ?? []
        matchCase = defaults.bool(forKey: Keys.matchCase)
        wholeWords = defaults.bool(forKey: Keys.wholeWords)
        matchPath = defaults.bool(forKey: Keys.matchPath)
        matchDiacritics = defaults.bool(forKey: Keys.matchDiacritics)
        ignorePunctuation = defaults.bool(forKey: Keys.ignorePunctuation)
        wildcardsEnabled = defaults.object(forKey: Keys.wildcardsEnabled) as? Bool ?? true
        regexEnabled = defaults.bool(forKey: Keys.regexEnabled)
        resultLimit = defaults.object(forKey: Keys.resultLimit) as? Int ?? 3_000
        theme = AppTheme(rawValue: defaults.string(forKey: Keys.theme) ?? "") ?? .system
        viewMode = ResultViewMode(rawValue: defaults.string(forKey: Keys.viewMode) ?? "") ?? .list
        let columns = defaults.stringArray(forKey: Keys.visibleColumns) ?? []
        visibleColumns = columns.isEmpty ? Set(SortField.allCases.map(\.rawValue)) : Set(columns)
        requireAuthForSettings = defaults.object(forKey: Keys.requireAuthForSettings) as? Bool ?? false
    }

    func rememberSearch(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        searchHistory.removeAll { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
        searchHistory.insert(trimmed, at: 0)
        if searchHistory.count > 100 { searchHistory = Array(searchHistory.prefix(100)) }
    }

    func clearSearchHistory() {
        searchHistory = []
    }

    func addSavedSearch(name: String, query: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !trimmedQuery.isEmpty else { return }
        if let index = savedSearches.firstIndex(where: { $0.name.caseInsensitiveCompare(trimmedName) == .orderedSame }) {
            savedSearches[index].query = trimmedQuery
        } else {
            savedSearches.append(SavedSearch(name: trimmedName, query: trimmedQuery))
        }
    }

    func removeSavedSearch(_ item: SavedSearch) {
        savedSearches.removeAll { $0.id == item.id }
    }

    func recordRun(path: String, query: String) {
        runHistory.removeAll { $0.path == path }
        runHistory.insert(RunHistoryEntry(path: path, query: query, date: Date()), at: 0)
        if runHistory.count > 200 { runHistory = Array(runHistory.prefix(200)) }
    }

    func clearRunHistory() {
        runHistory = []
    }

    /// Everything-style global modifier prefix derived from the Options menu.
    var queryPrefix: String {
        var parts: [String] = []
        if matchCase { parts.append("?case:") }
        if wholeWords { parts.append("?whole-words:") }
        if matchPath { parts.append("?path:") }
        if matchDiacritics { parts.append("?diacritics:") }
        if ignorePunctuation { parts.append("?ignore-punctuation:") }
        if !wildcardsEnabled { parts.append("?nowildcards:") }
        if regexEnabled { parts.append("?regex:") }
        return parts.joined(separator: " ")
    }

    private func encode<T: Encodable>(_ value: T, forKey key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }

    private static func decode<T: Decodable>(for defaults: UserDefaults, key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private enum Keys {
        static let searchHistory = "needle.searchHistory"
        static let savedSearches = "needle.savedSearches"
        static let runHistory = "needle.runHistory"
        static let matchCase = "needle.matchCase"
        static let wholeWords = "needle.wholeWords"
        static let matchPath = "needle.matchPath"
        static let matchDiacritics = "needle.matchDiacritics"
        static let ignorePunctuation = "needle.ignorePunctuation"
        static let wildcardsEnabled = "needle.wildcardsEnabled"
        static let regexEnabled = "needle.regexEnabled"
        static let resultLimit = "needle.resultLimit"
        static let theme = "needle.theme"
        static let viewMode = "needle.resultViewMode"
        static let visibleColumns = "needle.visibleColumns"
        static let requireAuthForSettings = "needle.requireAuthForSettings"
    }
}
