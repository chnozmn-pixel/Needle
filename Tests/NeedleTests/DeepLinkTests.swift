import XCTest
@testable import NeedleCore

final class DeepLinkTests: XCTestCase {
    func testQueryParameter() {
        let url = URL(string: "needle://search?q=annual%20report")!
        XCTAssertEqual(DeepLink.query(from: url), "annual report")
    }

    func testAlternateQueryParameterNames() {
        XCTAssertEqual(
            DeepLink.query(from: URL(string: "needle://search?query=invoice")!),
            "invoice"
        )
        XCTAssertEqual(
            DeepLink.query(from: URL(string: "needle://search?s=photo")!),
            "photo"
        )
    }

    func testHostFallback() {
        XCTAssertEqual(DeepLink.query(from: URL(string: "needle://budget")!), "budget")
        XCTAssertNil(DeepLink.query(from: URL(string: "needle://search")!))
    }

    func testEmptyQueryIsIgnored() {
        XCTAssertNil(DeepLink.query(from: URL(string: "needle://search?q=")!))
    }
}
