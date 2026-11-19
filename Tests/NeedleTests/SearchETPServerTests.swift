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

        // Active mode stays rejected; passive mode is covered by the data-channel tests.
        writeLine(client, "PORT 127,0,0,1,0,80")
        XCTAssertEqual(readLine(client), "502 Command not implemented.")
        writeLine(client, "EPRT |1|127.0.0.1|1234|")
        XCTAssertEqual(readLine(client), "502 Command not implemented.")
        writeLine(client, "BOGUS")
        XCTAssertEqual(readLine(client), "500 Unknown command.")
    }

    func testPassiveListAndMlsdDataChannel() throws {
        let modified = Date(timeIntervalSince1970: 1_700_000_000)
        let file = IndexEntry.make(
            path: "/tmp/needle-etp-data-file.txt", isDirectory: false, size: 12,
            modifiedAt: modified, createdAt: nil
        )
        let folder = IndexEntry.make(
            path: "/tmp/needle-etp-data-folder", isDirectory: true, size: 0,
            modifiedAt: modified, createdAt: nil
        )
        let child = IndexEntry.make(
            path: "/tmp/needle-etp-data-folder/child.txt", isDirectory: false, size: 5,
            modifiedAt: modified, createdAt: nil
        )
        let server = SearchETPServer(port: 0) { query, _ in
            switch query {
            case "needle": return [file, folder, child].map { SearchResult(entry: $0, source: .index) }
            case "needle-etp-data-folder": return [SearchResult(entry: folder, source: .index)]
            case "/tmp/needle-etp-data-folder": return [SearchResult(entry: child, source: .index)]
            default: return []
            }
        }
        try server.start()
        defer { server.stop() }

        let client = try XCTUnwrap(openConnection(port: server.listeningPort))
        defer { close(client) }
        XCTAssertEqual(readLine(client), "220 Welcome to Needle ETP")

        writeLine(client, "SITE EVERYTHING SEARCH needle")
        XCTAssertEqual(readLine(client), "200 Search set to (needle).")

        writeLine(client, "LIST")
        XCTAssertEqual(readLine(client), "425 Use PASV or EPSV first.")

        // PASV advertises an ephemeral loopback port in the classic format.
        writeLine(client, "PASV")
        let pasvReply = try XCTUnwrap(readLine(client))
        XCTAssertTrue(pasvReply.hasPrefix("227 Entering Passive Mode (127,0,0,1,"), pasvReply)
        XCTAssertTrue(pasvReply.hasSuffix(")."), pasvReply)
        let pasvPort = try XCTUnwrap(parsePassivePort(pasvReply))
        XCTAssertGreaterThan(pasvPort, 0)

        let listData = try XCTUnwrap(openDataConnection(port: pasvPort))
        writeLine(client, "LIST")
        XCTAssertEqual(readLine(client), "150 Opening data connection.")
        let listing = String(decoding: readAll(listData), as: UTF8.self)
        close(listData)
        XCTAssertEqual(readLine(client), "226 Transfer complete.")
        XCTAssertTrue(listing.contains("needle-etp-data-file.txt"), listing)
        XCTAssertTrue(listing.contains("-rw-r--r-- 1 owner staff 12"), listing)
        XCTAssertTrue(listing.contains("drwxr-xr-x 1 owner staff 0"), listing)

        // EPSV replaces the pending socket and uses the extended format.
        writeLine(client, "EPSV")
        let epsvReply = try XCTUnwrap(readLine(client))
        XCTAssertTrue(epsvReply.hasPrefix("229 Entering Extended Passive Mode (|||"), epsvReply)
        let epsvPort = try XCTUnwrap(parseExtendedPassivePort(epsvReply))
        XCTAssertGreaterThan(epsvPort, 0)

        let mlsdData = try XCTUnwrap(openDataConnection(port: epsvPort))
        writeLine(client, "MLSD /tmp/needle-etp-data-folder")
        XCTAssertEqual(readLine(client), "150 Opening data connection.")
        let mlsd = String(decoding: readAll(mlsdData), as: UTF8.self)
        close(mlsdData)
        XCTAssertEqual(readLine(client), "226 Transfer complete.")
        XCTAssertTrue(mlsd.contains("type=file;size=5;"), mlsd)
        XCTAssertTrue(mlsd.contains("child.txt"), mlsd)
    }

    func testPassiveRetrieveStreamsExactBytes() throws {
        let payload = Data("needle-etp-retr-payload-0123456789".utf8)
        let fileName = "needle-etp-retr.bin"
        let filePath = (NSTemporaryDirectory() as NSString).appendingPathComponent(fileName)
        try payload.write(to: URL(fileURLWithPath: filePath))
        defer { try? FileManager.default.removeItem(atPath: filePath) }

        let entry = IndexEntry.make(
            path: filePath, isDirectory: false, size: Int64(payload.count),
            modifiedAt: Date(timeIntervalSince1970: 1_700_000_000), createdAt: nil
        )
        let server = SearchETPServer(port: 0) { query, _ in
            query == fileName ? [SearchResult(entry: entry, source: .index)] : []
        }
        try server.start()
        defer { server.stop() }

        let client = try XCTUnwrap(openConnection(port: server.listeningPort))
        defer { close(client) }
        XCTAssertEqual(readLine(client), "220 Welcome to Needle ETP")

        writeLine(client, "RETR \(filePath)")
        XCTAssertEqual(readLine(client), "425 Use PASV or EPSV first.")

        writeLine(client, "PASV")
        let missingPort = try XCTUnwrap(parsePassivePort(try XCTUnwrap(readLine(client))))
        let missingData = try XCTUnwrap(openDataConnection(port: missingPort))
        writeLine(client, "RETR /tmp/needle-etp-missing.bin")
        XCTAssertEqual(readLine(client), "550 File not found.")
        close(missingData)

        writeLine(client, "PASV")
        let port = try XCTUnwrap(parsePassivePort(try XCTUnwrap(readLine(client))))
        let data = try XCTUnwrap(openDataConnection(port: port))
        writeLine(client, "RETR \(filePath)")
        XCTAssertEqual(readLine(client), "150 Opening data connection.")
        let received = readAll(data)
        close(data)
        XCTAssertEqual(readLine(client), "226 Transfer complete.")
        XCTAssertEqual(received, payload)
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

    private func openDataConnection(port: UInt16) -> Int32? {
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

    private func readAll(_ fd: Int32) -> Data {
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 8_192)
        while true {
            let count = buffer.withUnsafeMutableBytes { raw in
                recv(fd, raw.baseAddress, raw.count, 0)
            }
            guard count > 0 else { break }
            result.append(contentsOf: buffer.prefix(count))
        }
        return result
    }

    private func parsePassivePort(_ reply: String) -> UInt16? {
        guard reply.hasPrefix("227 "),
              let open = reply.firstIndex(of: "("),
              let close = reply.lastIndex(of: ")") else { return nil }
        let parts = reply[reply.index(after: open)..<close].split(separator: ",").map(String.init)
        guard parts.count == 6, let high = UInt16(parts[4]), let low = UInt16(parts[5]) else { return nil }
        return (high << 8) | low
    }

    private func parseExtendedPassivePort(_ reply: String) -> UInt16? {
        guard reply.hasPrefix("229 "),
              let start = reply.range(of: "|||")?.upperBound,
              let end = reply[start...].firstIndex(of: "|") else { return nil }
        return UInt16(reply[start..<end])
    }
}
