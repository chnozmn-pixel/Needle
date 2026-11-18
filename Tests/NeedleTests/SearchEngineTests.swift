import XCTest
@testable import NeedleCore

final class SearchEngineTests: XCTestCase {

    private func makeEntry(_ path: String, isDirectory: Bool = false, size: Int64 = 100) -> IndexEntry {
        IndexEntry.make(
            path: path,
            isDirectory: isDirectory,
            size: size,
            modifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
            createdAt: Date(timeIntervalSince1970: 1_600_000_000)
        )
    }

    func testSubstringSearchIsCaseInsensitive() {
        let engine = SearchEngine()
        let entries = [
            makeEntry("/Users/me/Projeler/Rapor2024.pdf"),
            makeEntry("/Users/me/Projeler/Taslak.txt"),
            makeEntry("/Users/me/Projeler/Rapor-notlar.docx")
        ]
        engine.rebuild(from: entries)

        let results = engine.search(QueryParser.parse("RAPOR"))
        XCTAssertEqual(Set(results.map(\.entry.name)), ["Rapor2024.pdf", "Rapor-notlar.docx"])
    }

    func testPrefixAndSuffixGrams() {
        let engine = SearchEngine()
        engine.rebuild(from: [
            makeEntry("/tmp/abc.md"),
            makeEntry("/tmp/bcd.md"),
            makeEntry("/tmp/zabc.md")
        ])

        let starts = engine.search(QueryParser.parse("abc"))
        XCTAssertEqual(starts.count, 2)
        let suffix = engine.search(QueryParser.parse("bcd"))
        XCTAssertEqual(suffix.count, 1)
        XCTAssertEqual(suffix.first?.entry.name, "bcd.md")
    }

    func testFilters() {
        let engine = SearchEngine()
        engine.rebuild(from: [
            makeEntry("/p/kucuk.pdf", size: 10),
            makeEntry("/p/buyuk.pdf", size: 20 * 1024 * 1024),
            makeEntry("/p/klasor", isDirectory: true)
        ])

        let big = engine.search(QueryParser.parse("file size:>10mb"))
        XCTAssertEqual(big.map(\.entry.name), ["buyuk.pdf"])

        let folders = engine.search(QueryParser.parse("folder"))
        XCTAssertEqual(folders.map(\.entry.name), ["klasor"])

        let byExt = engine.search(QueryParser.parse("ext:pdf"))
        XCTAssertEqual(byExt.count, 2)
    }

    func testIncrementalUpsertAndDelete() {
        let engine = SearchEngine()
        let original = makeEntry("/p/eski.txt")
        engine.rebuild(from: [original])

        let renamed = makeEntry("/p/yeni.txt")
        engine.apply([.delete(path: original.path), .upsert(renamed)])

        let old = engine.search(QueryParser.parse("eski"))
        XCTAssertTrue(old.isEmpty)
        let new = engine.search(QueryParser.parse("yeni"))
        XCTAssertEqual(new.count, 1)
        XCTAssertEqual(engine.indexedCount(), 1)
    }

    func testBulkModeLiveSearch() {
        let engine = SearchEngine()
        engine.beginBulk()
        engine.apply([.upsert(makeEntry("/p/alpha.txt"))])
        XCTAssertEqual(engine.search(QueryParser.parse("alpha")).count, 1)
        engine.apply([.upsert(makeEntry("/p/beta.txt"))])
        XCTAssertEqual(engine.search(QueryParser.parse("beta")).count, 1)
        engine.finishBulk()
        XCTAssertEqual(engine.indexedCount(), 2)
    }
}
