import XCTest
import Foundation
@testable import NeedleCore

final class SearchHTTPServerTests: XCTestCase {

    func testLoopbackJSONEndpoint() async throws {
        let entry = IndexEntry.make(
            path: "/tmp/needle-http-test.txt",
            isDirectory: false,
            size: 12,
            modifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
            createdAt: nil
        )
        let server = SearchHTTPServer(port: 0) { query, limit in
            query == "needle" ? [SearchResult(entry: entry, source: .index)] : []
        }
        try server.start()
        defer { server.stop() }
        XCTAssertGreaterThan(server.listeningPort, 0)

        let url = URL(string: "http://127.0.0.1:\(server.listeningPort)/?s=needle&format=json")!
        let (data, response) = try await URLSession.shared.data(from: url)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)

        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["query"] as? String, "needle")
        XCTAssertEqual(object["count"] as? Int, 1)
        let results = try XCTUnwrap(object["results"] as? [[String: Any]])
        XCTAssertEqual(results.first?["path"] as? String, entry.path)
    }
}
