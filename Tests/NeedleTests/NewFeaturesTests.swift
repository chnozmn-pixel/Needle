import XCTest
@testable import NeedleCore

final class NewFeaturesTests: XCTestCase {

    // MARK: - Tags and comments

    func testTagAndCommentSearch() {
        let entries = [
            IndexEntry.make(path: "/p/one.txt", isDirectory: false, size: 10,
                            modifiedAt: nil, createdAt: nil,
                            tags: ["Önemli", "İş"], comment: "taslak notu"),
            IndexEntry.make(path: "/p/two.txt", isDirectory: false, size: 10,
                            modifiedAt: nil, createdAt: nil,
                            tags: ["Kişisel"], comment: "final sürüm")
        ]
        let engine = SearchEngine()
        engine.rebuild(from: entries)

        let important = engine.search(QueryParser.parse("tag:önemli"))
        XCTAssertEqual(important.map(\.entry.name), ["one.txt"])

        let draft = engine.search(QueryParser.parse("comment:taslak"))
        XCTAssertEqual(draft.map(\.entry.name), ["one.txt"])

        let combined = engine.search(QueryParser.parse("tag:iş comment:taslak"))
        XCTAssertEqual(combined.map(\.entry.name), ["one.txt"])

        let missing = engine.search(QueryParser.parse("tag:olmayan"))
        XCTAssertTrue(missing.isEmpty)
    }

    func testFilterSummaryIncludesTagAndComment() {
        let summary = QueryParser.parse("tag:Önemli comment:taslak").filterSummary
        XCTAssertTrue(summary.contains(L("etiket: %@", "Önemli")))
        XCTAssertTrue(summary.contains(L("yorum: %@", "taslak")))
    }

    // MARK: - Persistence

    func testRootSettingsFileListsAndJournalPersist() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NeedleDBTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("index.sqlite").path

        let database = IndexDatabase(path: path)
        try database.open()
        try database.setRoots([
            IndexRoot(path: "/Volumes/Archive", kind: .network,
                      isEnabled: false, excludedPaths: ["/Volumes/Archive/cache"]),
            IndexRoot(path: "/Users/test/Documents", kind: .local)
        ])
        try database.addFileList(id: "list-1", name: "backup.efu", items: [
            FileListItem(path: "/mnt/backup/photo.jpg", size: 42,
                         tags: ["Seyahat"], comment: "yedek")
        ])
        database.appendJournal(path: "backup.efu", action: "fileList")
        let entries = try database.loadAllEntries()
        XCTAssertTrue(entries.contains { $0.path == "/mnt/backup/photo.jpg" && $0.tags == ["Seyahat"] })

        let reopened = IndexDatabase(path: path)
        try reopened.open()
        let roots = reopened.loadRoots()
        XCTAssertEqual(roots.count, 2)
        XCTAssertEqual(roots.first { $0.path == "/Volumes/Archive" }?.isEnabled, false)
        XCTAssertEqual(roots.first { $0.path == "/Volumes/Archive" }?.excludedPaths,
                       ["/Volumes/Archive/cache"])
        XCTAssertEqual(reopened.loadFileLists().map(\.name), ["backup.efu"])
        XCTAssertEqual(reopened.loadJournal(limit: 10).first?.action, "fileList")
        XCTAssertTrue(try reopened.loadAllEntries().contains { $0.path == "/mnt/backup/photo.jpg" })

        try reopened.removeFileList(id: "list-1")
        XCTAssertTrue(try reopened.loadAllEntries().isEmpty)
        try reopened.clearJournal()
        XCTAssertTrue(reopened.loadJournal(limit: 10).isEmpty)
    }

    // MARK: - EFU import through the store

    func testStoreImportsEFUIntoSearchableIndex() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NeedleEFUTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = IndexStore(
            databasePath: directory.appendingPathComponent("index.sqlite").path,
            cancellation: CancellationFlag(),
            initialRoots: [IndexRoot(path: directory.path, kind: .local)]
        )
        await store.start()

        let error = await store.importFileList(name: "offline.efu", items: [
            FileListItem(path: "/offline/movie.mkv", size: 1024,
                         tags: ["Film"], comment: "blu-ray")
        ])
        XCTAssertNil(error)
        let lists = await store.fileLists()
        XCTAssertEqual(lists.map(\.name), ["offline.efu"])

        let tagged = await store.search(QueryParser.parse("tag:film"), limit: 10)
        XCTAssertEqual(tagged.map(\.entry.name), ["movie.mkv"])

        await store.removeFileList(id: lists.first!.identifier)
        let afterRemoval = await store.search(QueryParser.parse("movie.mkv"), limit: 10)
        XCTAssertTrue(afterRemoval.isEmpty)
    }
}
