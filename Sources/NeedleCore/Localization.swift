import Foundation
import Combine

/// Languages offered in Settings. `.system` follows the macOS preferred
/// language list and is resolved on every launch.
public enum AppLanguage: String, CaseIterable, Sendable, Identifiable {
    case system
    case turkish
    case english
    case german
    case spanish
    case french
    case italian
    case portuguese
    case japanese
    case chinese
    case korean
    case russian
    case arabic
    case hindi

    public var id: String { rawValue }

    /// Name shown in the picker, written in the language itself.
    public var displayName: String {
        switch self {
        case .system: return "Sistem dili"
        case .turkish: return "Türkçe"
        case .english: return "English"
        case .german: return "Deutsch"
        case .spanish: return "Español"
        case .french: return "Français"
        case .italian: return "Italiano"
        case .portuguese: return "Português"
        case .japanese: return "日本語"
        case .chinese: return "简体中文"
        case .korean: return "한국어"
        case .russian: return "Русский"
        case .arabic: return "العربية"
        case .hindi: return "हिन्दी"
        }
    }

    /// Key used to look up the language in `TranslationTables.tables`.
    public var translationKey: String {
        switch self {
        case .system: return "en"
        case .turkish: return "tr"
        case .english: return "en"
        case .german: return "de"
        case .spanish: return "es"
        case .french: return "fr"
        case .italian: return "it"
        case .portuguese: return "pt"
        case .japanese: return "ja"
        case .chinese: return "zh"
        case .korean: return "ko"
        case .russian: return "ru"
        case .arabic: return "ar"
        case .hindi: return "hi"
        }
    }

    /// Stable locale identifier used by the translation tables and formatters.
    public var localeIdentifier: String {
        switch self {
        case .system: return Locale.current.identifier
        case .turkish: return "tr_TR"
        case .english: return "en_US"
        case .german: return "de_DE"
        case .spanish: return "es_ES"
        case .french: return "fr_FR"
        case .italian: return "it_IT"
        case .portuguese: return "pt_BR"
        case .japanese: return "ja_JP"
        case .chinese: return "zh_Hans_CN"
        case .korean: return "ko_KR"
        case .russian: return "ru_RU"
        case .arabic: return "ar_SA"
        case .hindi: return "hi_IN"
        }
    }

    /// Resolves the concrete language when `.system` is selected.
    public var resolved: AppLanguage {
        guard self == .system else { return self }
        for identifier in Locale.preferredLanguages {
            let lower = identifier.lowercased()
            if lower.hasPrefix("tr") { return .turkish }
            if lower.hasPrefix("ja") { return .japanese }
            if lower.hasPrefix("ko") { return .korean }
            if lower.hasPrefix("zh") { return .chinese }
            if lower.hasPrefix("ru") { return .russian }
            if lower.hasPrefix("ar") { return .arabic }
            if lower.hasPrefix("hi") { return .hindi }
            if lower.hasPrefix("de") { return .german }
            if lower.hasPrefix("es") { return .spanish }
            if lower.hasPrefix("fr") { return .french }
            if lower.hasPrefix("it") { return .italian }
            if lower.hasPrefix("pt") { return .portuguese }
        }
        return .english
    }
}

/// Holds the selected language and resolves UI strings at runtime.
/// Changing `language` immediately invalidates every SwiftUI view that uses `L`.
public final class LocalizationManager: ObservableObject {

    public static let shared = LocalizationManager()

    /// Fresh installations start in English. Users can still select
    /// `.system` or any supported language in Settings.
    public static let defaultLanguage: AppLanguage = .english

    private static let languageKey = "needle.language"
    private static let languageSchemaKey = "needle.language.schema.v2"

    @Published public var language: AppLanguage {
        didSet {
            UserDefaults.standard.set(language.rawValue, forKey: Self.languageKey)
        }
    }

    private init() {
        let defaults = UserDefaults.standard
        let saved = defaults.string(forKey: Self.languageKey) ?? ""

        // Existing installations that never chose a concrete language (or
        // were left on `.system`) move to the new English default once.
        // An explicit non-system choice is preserved.
        if defaults.string(forKey: Self.languageSchemaKey) == nil {
            if saved.isEmpty || saved == AppLanguage.system.rawValue {
                defaults.set(Self.defaultLanguage.rawValue, forKey: Self.languageKey)
            }
            defaults.set("2", forKey: Self.languageSchemaKey)
        }

        let resolved = defaults.string(forKey: Self.languageKey) ?? ""
        language = AppLanguage(rawValue: resolved) ?? Self.defaultLanguage
    }

    public var activeLanguage: AppLanguage { language.resolved }
    public var locale: Locale { Locale(identifier: activeLanguage.localeIdentifier) }

    /// Looks up `key` in the active language, falling back to English and
    /// finally to the source string so the UI is never blank.
    public func string(_ key: String) -> String {
        let language = activeLanguage
        if language == .turkish { return key }
        let raw = language.translationKey
        if let translated = TranslationTables.tables[raw]?[key], !translated.isEmpty {
            return translated
        }
        return TranslationTables.english[key] ?? key
    }

    public func string(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: string(key), arguments: arguments)
    }
}

/// Short helper used from UI code: `Text(L("Ayarlar"))`.
public func L(_ key: String) -> String {
    LocalizationManager.shared.string(key)
}

public func L(_ key: String, _ arguments: CVarArg...) -> String {
    LocalizationManager.shared.string(key, arguments)
}
