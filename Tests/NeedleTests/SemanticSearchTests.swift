import XCTest
@testable import NeedleCore

final class SemanticSearchTests: XCTestCase {

    private func entry(_ path: String) -> IndexEntry {
        IndexEntry.make(
            path: path,
            isDirectory: false,
            size: 100,
            modifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
            createdAt: Date(timeIntervalSince1970: 1_600_000_000)
        )
    }

    private func names(_ paths: [String], _ query: String) -> Set<String> {
        let engine = SearchEngine()
        engine.rebuild(from: paths.map { entry($0) })
        return Set(engine.search(QueryParser.parse(query)).map(\.entry.name))
    }

    func testEmbeddingModelIsAvailableOnThisSystem() {
        XCTAssertTrue(SemanticSearch.isAvailable)
    }

    func testExpansionKeepsOriginalPhraseAndAddsRelatedWords() {
        let terms = SemanticSearch.expand("car")
        XCTAssertEqual(terms.first, "car")
        XCTAssertTrue(terms.contains("vehicle"), "Unexpected neighbours: \(terms)")
        XCTAssertEqual(Set(terms).count, terms.count, "Expansion must not contain duplicates")
        XCTAssertTrue(terms.allSatisfy { $0 == $0.lowercased() })
    }

    func testExpansionHandlesQuotedPhrases() {
        let terms = SemanticSearch.expand("annual report")
        XCTAssertEqual(terms.first, "annual report")
        XCTAssertGreaterThan(terms.count, 1)
    }

    func testSemanticQueryFindsRelatedNames() {
        let paths = [
            "/p/car.pdf", "/p/automobile.pdf", "/p/vehicle.jpg",
            "/p/invoice.pdf", "/p/recipe.txt"
        ]
        let found = names(paths, "semantic:car")
        XCTAssertTrue(found.contains("car.pdf"))
        XCTAssertTrue(found.contains("automobile.pdf"))
        XCTAssertTrue(found.contains("vehicle.jpg"))
        XCTAssertFalse(found.contains("invoice.pdf"))
        XCTAssertFalse(found.contains("recipe.txt"))
    }

    func testSemanticQueryCombinesWithOtherFilters() {
        let paths = [
            "/p/car.pdf", "/p/vehicle.pdf", "/p/vehicle.txt", "/p/invoice.pdf"
        ]
        let found = names(paths, "semantic:car ext:pdf")
        XCTAssertEqual(found, ["car.pdf", "vehicle.pdf"])
    }

    func testSemanticQuerySupportsQuotedValues() {
        let paths = [
            "/p/annual report 2025.pdf", "/p/invoice.pdf", "/p/notes.txt"
        ]
        let found = names(paths, "semantic:\"annual report\"")
        XCTAssertTrue(found.contains("annual report 2025.pdf"))
        XCTAssertFalse(found.contains("invoice.pdf"))
    }

    func testNegatedSemanticQuery() {
        let paths = ["/p/car.pdf", "/p/vehicle.jpg", "/p/invoice.pdf"]
        let found = names(paths, "!semantic:car")
        XCTAssertEqual(found, ["invoice.pdf"])
    }

    func testQuotedFunctionValueIsOneToken() {
        let query = QueryParser.parse("content:\"two words\" ext:pdf")
        XCTAssertFalse(query.nameTerms.contains("words"))
        XCTAssertEqual(query.allowedExtensions, ["pdf"])
    }
}
