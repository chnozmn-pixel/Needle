import XCTest
@testable import NeedleCore

final class IndexStoreTests: XCTestCase {

    func testScanPersistsAndSearches() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NeedleTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try "hello".write(to: root.appendingPathComponent("rapor.txt"), atomically: true, encoding: .utf8)
        try "hello".write(to: root.appendingPathComponent("notlar.md"), atomically: true, encoding: .utf8)
        let nested = root.appendingPathComponent("Alt Klasor", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try "hello".write(to: nested.appendingPathComponent("proje.pdf"), atomically: true, encoding: .utf8)

        let database = root.appendingPathComponent("index.sqlite").path
        let store = IndexStore(
            databasePath: database,
            cancellation: CancellationFlag(),
            initialRoots: [IndexRoot(path: root.path, kind: .local)]
        )

        let ready = expectation(description: "index ready")
        ready.assertForOverFulfill = false
        await store.setStatusHandler { status in
            if status.phase == .watching && status.totalEntries >= 4 {
                ready.fulfill()
            }
        }
        await store.start()
        await fulfillment(of: [ready], timeout: 30)

        let all = await store.search(ParsedQuery(), limit: 100)
        XCTAssertGreaterThanOrEqual(all.count, 4)

        let pdf = await store.search(QueryParser.parse("ext:pdf"), limit: 100)
        XCTAssertEqual(pdf.map(\.entry.name), ["proje.pdf"])

        let pathFiltered = await store.search(QueryParser.parse("path:alt klasor"), limit: 100)
        XCTAssertGreaterThanOrEqual(pathFiltered.count, 1)

        // Reopen the database to verify persistence.
        let reopened = IndexStore(
            databasePath: database,
            cancellation: CancellationFlag(),
            initialRoots: [IndexRoot(path: root.path, kind: .local)]
        )
        let reopenedReady = expectation(description: "reopened index ready")
        reopenedReady.assertForOverFulfill = false
        await reopened.setStatusHandler { status in
            if status.phase == .watching && status.totalEntries >= 4 {
                reopenedReady.fulfill()
            }
        }
        await reopened.start()
        await fulfillment(of: [reopenedReady], timeout: 30)
        let persisted = await reopened.search(QueryParser.parse("rapor"), limit: 10)
        XCTAssertEqual(persisted.count, 1)
    }
}
