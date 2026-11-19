import XCTest
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
@testable import NeedleCore

final class SearchETPServerTests: XCTestCase {

    func testLoopbackETPControlPlane() throws {
        let file = IndexEntry.make(
            path: "/tmp/needle-etp-a.txt",
            isDirectory: false,
            size: 12,
            modifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
            createdAt: nil
        )
        let folder = IndexEntry.make(
            path: "/tmp/needle-etp-folder",
            isDirectory: true,
            size: 0,
            modifiedAt: nil,
            createdAt: nil
        )
        let server = SearchETPServer(port: 0) { query, _ in
            query == "needle"
                ? [SearchResult(entry: file, source: .index), SearchResult(entry: folder, source: .index)]
                : []
        }
        try server.start()
        defer { server.stop() }
        let port = server.listeningPort
        XCTAssertGreaterThan(port, 0)

        let client = try XCTUnwrap(openConnection(port: port))
        defer { close(client) }

        XCTAssertEqual(readLine(client), "220 Welcome to Needle ETP")

        writeLine(client, "USER tester")
        XCTAssertEqual(readLine(client), "331 Password required")
        writeLine(client, "PASS secret")
        XCTAssertEqual(readLine(client), "230 Logged on.")

        writeLine(client, "FEAT")
        XCTAssertEqual(readLine(client), "211-Features:")
        var features: [String] = []
        while let line = readLine(client), line != "211 End" { features.append(line) }
        XCTAssertEqual(features, [
            " MDTM", " REST STREAM", " SIZE", " MLST type*;size*;modify*;",
            " MLSD", " UTF8", " EVERYTHING"
        ])

        writeLine(client, "SITE EVERYTHING SEARCH needle")
        XCTAssertEqual(readLine(client), "200 Search set to (needle).")
        writeLine(client, "SITE EVERYTHING COUNT 1")
        XCTAssertEqual(readLine(client), "200 Count set to (1).")
        writeLine(client, "SITE EVERYTHING QUERY")
        XCTAssertEqual(readLine(client), "200-Query results")
        XCTAssertEqual(readLine(client), " RESULT_COUNT 2")
        XCTAssertEqual(readLine(client), " PATH /tmp/needle-etp-a.txt")
        XCTAssertEqual(readLine(client), " FILE needle-etp-a.txt")
        XCTAssertEqual(readLine(client), "200 End.")

        writeLine(client, "SITE EVERYTHING COUNT 10")
        XCTAssertEqual(readLine(client), "200 Count set to (10).")
        writeLine(client, "EVERYTHING QUERY")
        XCTAssertEqual(readLine(client), "200-Query results")
        XCTAssertEqual(readLine(client), " RESULT_COUNT 2")
        var rows: [String] = []
        while let line = readLine(client), line != "200 End." { rows.append(line) }
        XCTAssertEqual(rows, [
            " PATH /tmp/needle-etp-a.txt", " FILE needle-etp-a.txt",
            " PATH /tmp/needle-etp-folder", " FOLDER needle-etp-folder"
        ])

        writeLine(client, "QUIT")
        XCTAssertEqual(readLine(client), "221 Goodbye.")
    }

    func testColumnsFiletimeAndFTPInfoCommands() throws {
        let modified = Date(timeIntervalSince1970: 1_700_000_000)
        let file = IndexEntry.make(
            path: "/tmp/needle-etp-info.txt", isDirectory: false, size: 42,
            modifiedAt: modified, createdAt: modified
        )
        let folder = IndexEntry.make(
            path: "/tmp/needle-etp-info-dir", isDirectory: true, size: 99,
            modifiedAt: modified, createdAt: nil
        )
        let server = SearchETPServer(port: 0) { _, _ in
            [SearchResult(entry: file, source: .index), SearchResult(entry: folder, source: .index)]
        }
        try server.start()
        defer { server.stop() }

        let client = try XCTUnwrap(openConnection(port: server.listeningPort))
        defer { close(client) }
        XCTAssertEqual(readLine(client), "220 Welcome to Needle ETP")

        for command in [
            "SITE EVERYTHING SEARCH needle", "ATTRIBUTES_COLUMN 1", "SIZE_COLUMN 1",
            "DATE_MODIFIED_COLUMN 1", "DATE_CREATED_COLUMN 1", "QUERY"
        ] {
            writeLine(client, command)
        }
        _ = readLine(client) // search acknowledgement
        for expected in [
            "200 ATTRIBUTES_COLUMN set to (1).", "200 SIZE_COLUMN set to (1).",
            "200 DATE_MODIFIED_COLUMN set to (1).", "200 DATE_CREATED_COLUMN set to (1)."
        ] {
            XCTAssertEqual(readLine(client), expected)
        }

        let filetime = "133444736000000000" // 1700000000 + FILETIME epoch, in 100ns ticks
        XCTAssertEqual(readLine(client), "200-Query results")
        XCTAssertEqual(readLine(client), " RESULT_COUNT 2")
        XCTAssertEqual(readLine(client), " PATH /tmp/needle-etp-info.txt")
        XCTAssertEqual(readLine(client), " ATTRIBUTES 0")
        XCTAssertEqual(readLine(client), " SIZE 42")
        XCTAssertEqual(readLine(client), " DATE_MODIFIED \(filetime)")
        XCTAssertEqual(readLine(client), " DATE_CREATED \(filetime)")
        XCTAssertEqual(readLine(client), " FILE needle-etp-info.txt")
        XCTAssertEqual(readLine(client), " PATH /tmp/needle-etp-info-dir")
        XCTAssertEqual(readLine(client), " ATTRIBUTES 16")
        XCTAssertEqual(readLine(client), " SIZE 0")
        XCTAssertEqual(readLine(client), " DATE_MODIFIED \(filetime)")
        XCTAssertEqual(readLine(client), " DATE_CREATED 0")
        XCTAssertEqual(readLine(client), " FOLDER needle-etp-info-dir")
        XCTAssertEqual(readLine(client), "200 End.")

        writeLine(client, "SIZE /tmp/needle-etp-info.txt")
        XCTAssertEqual(readLine(client), "200 42")
        writeLine(client, "MDTM /tmp/needle-etp-info.txt")
        XCTAssertEqual(readLine(client), "213 20231114221320")
        writeLine(client, "MLST /tmp/needle-etp-info-dir")
        XCTAssertEqual(readLine(client), "250-Listing /tmp/needle-etp-info-dir")
        XCTAssertEqual(readLine(client), " type=dir; modify=20231114221320; size=0; /tmp/needle-etp-info-dir")
        XCTAssertEqual(readLine(client), "250 End.")

        writeLine(client, "PASV")
        XCTAssertEqual(readLine(client), "502 Command not implemented.")
        writeLine(client, "BOGUS")
        XCTAssertEqual(readLine(client), "500 Unknown command.")
    }

    // MARK: - Raw socket helpers

    private func openConnection(port: UInt16) -> Int32? {
        let fd = socket(AF_INET, Int32(SOCK_STREAM), 0)
        guard fd >= 0 else { return nil }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            close(fd)
            return nil
        }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        _ = withUnsafePointer(to: &timeout) {
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, $0, socklen_t(MemoryLayout<timeval>.size))
        }
        return fd
    }

    private func writeLine(_ fd: Int32, _ line: String) {
        let data = Data((line + "\r\n").utf8)
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let written = send(fd, base.advanced(by: offset), raw.count - offset, 0)
                if written <= 0 { return }
                offset += written
            }
        }
    }

    private func readLine(_ fd: Int32) -> String? {
        var bytes: [UInt8] = []
        while bytes.count < 8_192 {
            var byte: UInt8 = 0
            let count = withUnsafeMutablePointer(to: &byte) { recv(fd, $0, 1, 0) }
            guard count > 0 else { return nil }
            if byte == 0x0A {
                if bytes.last == 0x0D { bytes.removeLast() }
                return String(decoding: bytes, as: UTF8.self)
            }
            bytes.append(byte)
        }
        return nil
    }
}
