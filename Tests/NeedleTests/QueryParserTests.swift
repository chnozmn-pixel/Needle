import XCTest
@testable import NeedleCore

final class QueryParserTests: XCTestCase {

    func testPlainTerms() {
        let query = QueryParser.parse("rapor 2024")
        XCTAssertEqual(query.nameTerms, ["rapor", "2024"])
        XCTAssertTrue(query.isEmpty == false)
    }

    func testQuotedPhrase() {
        let query = QueryParser.parse("\"yıllık rapor\"")
        XCTAssertEqual(query.nameTerms, ["yıllık rapor"])
    }

    func testNegationAndExtensions() {
        let query = QueryParser.parse("!tmp ext:pdf;doc ext:!xls")
        XCTAssertEqual(query.excludedTerms, ["tmp"])
        XCTAssertEqual(query.allowedExtensions, ["pdf", "doc"])
        XCTAssertEqual(query.deniedExtensions, ["xls"])
    }

    func testTypeAndPath() {
        let query = QueryParser.parse("file path:projeler")
        XCTAssertFalse(query.includeFolders)
        XCTAssertTrue(query.includeFiles)
        XCTAssertEqual(query.pathTerms, ["projeler"])
    }

    func testSizeUnits() {
        XCTAssertEqual(QueryParser.parse("size:>10mb").minSize, 10 * 1024 * 1024)
        XCTAssertEqual(QueryParser.parse("size:<1kb").maxSize, 1024)
        let range = QueryParser.parse("size:1mb..2mb")
        XCTAssertEqual(range.minSize, 1_048_576)
        XCTAssertEqual(range.maxSize, 2_097_152)
    }

    func testDateRange() {
        let query = QueryParser.parse("dm:2024-01-01..2024-12-31")
        XCTAssertNotNil(query.modifiedAfter)
        XCTAssertNotNil(query.modifiedBefore)
        XCTAssertNotNil(QueryParser.parse("dc:today").createdAfter)
    }

    func testEmptyQuery() {
        XCTAssertTrue(QueryParser.parse("   ").isEmpty)
    }
}
