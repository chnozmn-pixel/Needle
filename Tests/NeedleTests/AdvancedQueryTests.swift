import XCTest
@testable import NeedleCore

final class AdvancedQueryTests: XCTestCase {

    private func entry(
        _ path: String,
        isDirectory: Bool = false,
        size: Int64 = 100,
        modified: Date? = Date(timeIntervalSince1970: 1_700_000_000),
        created: Date? = Date(timeIntervalSince1970: 1_600_000_000)
    ) -> IndexEntry {
        IndexEntry.make(path: path, isDirectory: isDirectory, size: size,
                        modifiedAt: modified, createdAt: created)
    }

    private func names(_ paths: [String], _ query: String) -> Set<String> {
        let engine = SearchEngine()
        engine.rebuild(from: paths.map { entry($0) })
        return Set(engine.search(QueryParser.parse(query)).map(\.entry.name))
    }

    func testORAndGroups() {
        let paths = [
            "/p/apple.txt", "/p/banana.txt", "/p/orange.txt", "/p/apple banana.txt"
        ]
        XCTAssertEqual(names(paths, "apple | orange"),
                       ["apple.txt", "orange.txt", "apple banana.txt"])
        XCTAssertEqual(names(paths, "<apple banana> | orange"),
                       ["apple banana.txt", "orange.txt"])
    }

    func testNegationAndDefaultPrecedence() {
        let paths = ["/p/apple.txt", "/p/banana.txt", "/p/orange.txt", "/p/apple banana.txt"]
        XCTAssertEqual(names(paths, "!banana"), ["apple.txt", "orange.txt"])
        // Default: OR binds tighter than AND -> apple AND (banana OR orange).
        XCTAssertEqual(names(paths, "apple banana | orange"), ["apple banana.txt"])
        // and-precedence: (apple banana) OR orange.
        XCTAssertEqual(names(paths, "?and-precedence: apple banana | orange"),
                       ["apple banana.txt", "orange.txt"])
    }

    func testWildcardsAndRegex() {
        let paths = [
            "/p/photo.jpg", "/p/photo.png", "/p/photo2024.jpg", "/p/a1.txt"
        ]
        XCTAssertEqual(names(paths, "*.jpg"), ["photo.jpg", "photo2024.jpg"])
        XCTAssertEqual(names(paths, "photo????"), ["photo.jpg", "photo.png"])
        XCTAssertEqual(names(paths, "regex:^photo\\d{4}\\.jpg$"), ["photo2024.jpg"])
    }

    func testCaseWholeWordsAndPrefix() {
        let paths = ["/p/RAPOR.txt", "/p/Rapor.txt", "/p/raporlar.txt", "/p/rapor 2024.txt"]
        XCTAssertEqual(names(paths, "case:RAPOR"), ["RAPOR.txt"])
        XCTAssertEqual(names(paths, "wholewords:rapor"),
                       ["RAPOR.txt", "Rapor.txt", "rapor 2024.txt"])
        XCTAssertEqual(names(paths, "startwith:rapor"),
                       ["RAPOR.txt", "Rapor.txt", "raporlar.txt", "rapor 2024.txt"])
        XCTAssertEqual(names(paths, "endwith:.txt"),
                       ["RAPOR.txt", "Rapor.txt", "raporlar.txt", "rapor 2024.txt"])
    }

    func testFilenameFunctionsAndMacros() {
        let paths = [
            "/Users/me/Projects/rapor.pdf", "/Users/me/Photos/photo.JPG",
            "/Users/me/Photos/movie.mp4", "/Users/me/Notes/readme.md"
        ]
        XCTAssertEqual(names(paths, "image:"), ["photo.JPG"])
        XCTAssertEqual(names(paths, "video:"), ["movie.mp4"])
        XCTAssertEqual(names(paths, "ext:PDF;MD"), ["rapor.pdf", "readme.md"])
        XCTAssertEqual(names(paths, "stem:rapor"), ["rapor.pdf"])
        XCTAssertEqual(names(paths, "path:projects"), ["rapor.pdf"])
        XCTAssertEqual(names(paths, "location:photos"), ["photo.JPG", "movie.mp4"])
    }

    func testRelativeDatesAndLength() {
        let recent = entry("/p/recent.txt", modified: Date().addingTimeInterval(-60))
        let old = entry("/p/old.txt", modified: Date(timeIntervalSince1970: 0))
        let engine = SearchEngine()
        engine.rebuild(from: [recent, old])
        XCTAssertEqual(engine.search(QueryParser.parse("dm:10mins")).map(\.entry.name), ["recent.txt"])
        XCTAssertEqual(engine.search(QueryParser.parse("name-length:10")).map(\.entry.name), ["recent.txt"])
    }

    func testChildAndEmptyFolders() {
        let engine = SearchEngine()
        engine.rebuild(from: [
            entry("/p/full", isDirectory: true),
            entry("/p/full/song.mp3"),
            entry("/p/empty", isDirectory: true),
            entry("/p/mixed", isDirectory: true),
            entry("/p/mixed/note.txt")
        ])
        XCTAssertEqual(engine.search(QueryParser.parse("child:*.mp3")).map(\.entry.name), ["full"])
        XCTAssertEqual(engine.search(QueryParser.parse("empty:")).map(\.entry.name), ["empty"])
        XCTAssertEqual(engine.search(QueryParser.parse("!child:*.txt folder:")).map(\.entry.name),
                       ["full", "empty"])
    }

    func testDistinctAndCount() {
        let paths = ["/a/report.pdf", "/b/report.pdf", "/c/notes.txt"]
        XCTAssertEqual(names(paths, "distinct:name"), ["report.pdf", "notes.txt"])
        let query = QueryParser.parse("count:1")
        XCTAssertEqual(query.resultLimit, 1)
        let engine = SearchEngine()
        engine.rebuild(from: paths.map { entry($0) })
        XCTAssertEqual(engine.search(query).count, 1)
    }

    func testSingleSortSpecification() {
        let engine = SearchEngine()
        engine.rebuild(from: [
            entry("/p/b.txt", size: 10),
            entry("/p/a.txt", size: 30),
            entry("/p/c.txt", size: 20)
        ])
        XCTAssertEqual(engine.search(QueryParser.parse("sort:size-descending")).map(\.entry.name),
                       ["a.txt", "c.txt", "b.txt"])
        XCTAssertEqual(engine.search(QueryParser.parse("sort:name")).map(\.entry.name),
                       ["a.txt", "b.txt", "c.txt"])
    }

    func testMultipleSortSpecificationsApplyEveryLevel() {
        let engine = SearchEngine()
        engine.rebuild(from: [
            entry("/p/b.jpg", size: 10),
            entry("/p/a.jpg", size: 30),
            entry("/p/d.txt", size: 5),
            entry("/p/c.txt", size: 20)
        ])
        let query = QueryParser.parse("sort:ext;size-descending")
        XCTAssertEqual(query.sortSpecifications.count, 2)
        XCTAssertEqual(engine.search(query).map(\.entry.name),
                       ["a.jpg", "b.jpg", "c.txt", "d.txt"])
    }

    func testThreeSortSpecificationsUseLaterOnesAsTieBreakers() {
        let engine = SearchEngine()
        engine.rebuild(from: [
            entry("/p/b.jpg", size: 10),
            entry("/p/a.jpg", size: 10),
            entry("/p/c.jpg", size: 20),
            entry("/p/z.txt", size: 10)
        ])
        let query = QueryParser.parse("sort:size-descending;ext;name")
        XCTAssertEqual(query.sortSpecifications.count, 3)
        XCTAssertEqual(engine.search(query).map(\.entry.name),
                       ["c.jpg", "a.jpg", "b.jpg", "z.txt"])
    }

    func testGlobalModifiersFromOptions() {
        let paths = ["/Users/me/RAPOR.txt", "/Users/me/rapor.txt", "/Users/me/raporlar.txt"]
        XCTAssertEqual(names(paths, "?case: RAPOR"), ["RAPOR.txt"])
        XCTAssertEqual(names(paths, "?whole-words: rapor"), ["RAPOR.txt", "rapor.txt"])
        XCTAssertEqual(names(paths, "?path: Users"), Set(paths.map { ($0 as NSString).lastPathComponent }))
    }

    func testTypedFileAndFolderFunctions() {
        let paths = ["/p/rapor.pdf", "/p/klasor", "/p/notlar.txt"]
        XCTAssertEqual(names(paths, "file:rapor"), ["rapor.pdf"])
        XCTAssertEqual(names(paths, "folder:klasor"), ["klasor"])
    }

    func testCharacterEntities() {
        XCTAssertEqual(names(["/p/C Program Files.txt"], "C&sp:Program&sp:Files"),
                       ["C Program Files.txt"])
        XCTAssertEqual(names(["/p/!readme.txt"], "&excl:readme"), ["!readme.txt"])
    }

    func testContentAndDuplicatesFromDisk() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NeedleAdvancedTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let a = root.appendingPathComponent("a.txt")
        let b = root.appendingPathComponent("b.txt")
        let c = root.appendingPathComponent("c.txt")
        try "needle content".write(to: a, atomically: true, encoding: .utf8)
        try "needle content".write(to: b, atomically: true, encoding: .utf8)
        try "different".write(to: c, atomically: true, encoding: .utf8)

        let entries = [a, b, c].map {
            entry($0.path, size: Int64((try? Data(contentsOf: $0).count) ?? 0))
        }
        let engine = SearchEngine()
        engine.rebuild(from: entries)

        XCTAssertEqual(Set(engine.search(QueryParser.parse("content:needle")).map(\.entry.name)),
                       ["a.txt", "b.txt"])
        XCTAssertEqual(Set(engine.search(QueryParser.parse("dupe:size;content")).map(\.entry.name)),
                       ["a.txt", "b.txt"])
    }
}
