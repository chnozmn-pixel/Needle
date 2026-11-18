import XCTest
@testable import NeedleCore

final class LocalizationTests: XCTestCase {

    func testTranslationsAndFallbacks() {
        let manager = LocalizationManager.shared
        let original = manager.language
        defer { manager.language = original }

        manager.language = .english
        XCTAssertEqual(L("Ayarlar"), "Settings")
        XCTAssertEqual(L("%@ sonuç", "12"), "12 results")

        manager.language = .german
        XCTAssertEqual(L("Ayarlar"), "Einstellungen")
        // Keys without a German translation fall back to English.
        XCTAssertEqual(L("Arama sözdizimi"), "Search syntax")

        manager.language = .turkish
        XCTAssertEqual(L("Ayarlar"), "Ayarlar")
        XCTAssertEqual(L("this key does not exist"), "this key does not exist")
    }

    func testLanguageMetadata() {
        XCTAssertEqual(LocalizationManager.defaultLanguage, .english)
        XCTAssertEqual(AppLanguage.english.resolved, .english)
        XCTAssertEqual(AppLanguage.japanese.resolved, .japanese)
        XCTAssertFalse(AppLanguage.system.displayName.isEmpty)
        XCTAssertEqual(AppLanguage.chinese.localeIdentifier, "zh_Hans_CN")
    }

    func testReportedStringsFollowSelectedLanguage() {
        let manager = LocalizationManager.shared
        let original = manager.language
        defer { manager.language = original }

        manager.language = .english
        XCTAssertEqual(NetworkScanSchedule.daily.displayName, "Daily")
        XCTAssertEqual(NetworkScanSchedule.idle.displayName, "When computer is idle")
        XCTAssertEqual(
            NetworkScanConfiguration(schedule: .daily, hour: 2, minute: 0).summary,
            "Daily at 02:00"
        )
        XCTAssertEqual(L("Koyu"), "Dark")
        XCTAssertEqual(L("⌘ ⇧ Boşluk"), "⌘ ⇧ Space")
        XCTAssertEqual(L("path:projeler"), "path:projects")
        XCTAssertEqual(L("sadece klasörler"), "folders only")
        XCTAssertEqual(L("SQLite hatası: %@", "boom"), "SQLite error: boom")

        manager.language = .german
        XCTAssertEqual(NetworkScanSchedule.daily.displayName, "Täglich")
        XCTAssertEqual(L("Koyu"), "Dunkel")
    }

    func testEnglishTableHasNoTurkishSourceLeak() {
        let turkish = CharacterSet(charactersIn: "ğüşıöçĞÜŞİÖÇ")
        for (key, value) in TranslationTables.english {
            XCTAssertNil(
                value.rangeOfCharacter(from: turkish),
                "English translation for \(key) still contains Turkish text: \(value)"
            )
        }
    }

    func testAllLiteralLocalizationKeysHaveEnglishTranslations() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // NeedleTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // package root
        let sources = root.appendingPathComponent("Sources")
        let enumerator = try XCTUnwrap(
            FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        )
        let pattern = #"\bL\("((?:[^"\\]|\\.)*)""#
        let regex = try NSRegularExpression(pattern: pattern)
        var missing: [String] = []

        while let url = enumerator.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let source = try String(contentsOf: url, encoding: .utf8)
            let ns = source as NSString
            let range = NSRange(location: 0, length: ns.length)
            for match in regex.matches(in: source, range: range) {
                let raw = ns.substring(with: match.range(at: 1))
                let key = raw
                    .replacingOccurrences(of: "\\\"", with: "\"")
                    .replacingOccurrences(of: "\\\\", with: "\\")
                if TranslationTables.english[key] == nil {
                    missing.append("\(url.lastPathComponent): \(key)")
                }
            }
        }

        XCTAssertTrue(
            missing.isEmpty,
            "Missing English translations: \(missing.joined(separator: ", "))"
        )
    }
}
