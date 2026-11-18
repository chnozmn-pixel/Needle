import XCTest
@testable import NeedleCore

final class FileListTests: XCTestCase {

    private func assertDate(
        _ actual: Date?,
        _ expected: Date,
        accuracy: TimeInterval = 0.001,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let actual else {
            XCTFail("Expected a date, got nil", file: file, line: line)
            return
        }
        XCTAssertEqual(
            actual.timeIntervalSince1970,
            expected.timeIntervalSince1970,
            accuracy: accuracy,
            file: file,
            line: line
        )
    }

    // MARK: - CSV parsing

    func testQuotedCommasAndDoubledQuotes() {
        let csv = "Filename,Size,Attributes,Tags,Comment\n" +
            "\"docs/report, final.txt\",123,32,\"alpha;beta\",\"He said \"\"hello, world\"\"\"\n" +
            "\"quote \"\"inside\"\" name.txt\",5,32,,\n"

        let items = FileList.parseEFU(csv)

        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].path, "docs/report, final.txt")
        XCTAssertEqual(items[0].size, 123)
        XCTAssertFalse(items[0].isDirectory)
        XCTAssertEqual(items[0].tags, ["alpha", "beta"])
        XCTAssertEqual(items[0].comment, "He said \"hello, world\"")
        XCTAssertEqual(items[1].path, "quote \"inside\" name.txt")
        XCTAssertEqual(items[1].size, 5)
        XCTAssertNil(items[1].comment)
    }

    func testQuotedNewlineAndCRLFRecords() {
        let csv = "Filename,Comment,Size\r\n\"a.txt\",\"first line\nsecond line\",\r\nfolder\\file.txt,,7\r\n"

        let items = FileList.parseEFU(csv)

        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].path, "a.txt")
        XCTAssertEqual(items[0].comment, "first line\nsecond line")
        XCTAssertEqual(items[1].path, "folder/file.txt")
        XCTAssertEqual(items[1].size, 7)
    }

    func testBOMAndRequiredHeader() {
        let withBOM = "\u{FEFF}Filename,Size\nfile.txt,9\n"
        let items = FileList.parseEFU(withBOM)

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].path, "file.txt")
        XCTAssertEqual(items[0].size, 9)

        XCTAssertTrue(FileList.parseEFU("Size,Tags\n9,alpha\n").isEmpty, "Header without Filename must be rejected")
        XCTAssertTrue(FileList.parseEFU("").isEmpty)
        XCTAssertTrue(FileList.parseEFU("Filename,Size\n").isEmpty)
    }

    // MARK: - Dates

    func testISODates() {
        let csv = "Filename,Date Modified,Date Created\n" +
            "iso.txt,2024-03-05T06:07:08Z,2024-03-05T06:07:08.123Z\n" +
            "day.txt,2024-03-06,\n"

        let items = FileList.parseEFU(csv)
        XCTAssertEqual(items.count, 2)

        let wholeSeconds = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let modified = wholeSeconds.date(from: "2024-03-05T06:07:08Z")!
        let created = fractional.date(from: "2024-03-05T06:07:08.123Z")!

        assertDate(items[0].modifiedAt, modified)
        assertDate(items[0].createdAt, created)

        let dayFormatter = ISO8601DateFormatter()
        dayFormatter.formatOptions = [.withFullDate]
        let day = dayFormatter.date(from: "2024-03-06")!
        assertDate(items[1].modifiedAt, day)
        XCTAssertNil(items[1].createdAt)
    }

    func testFILETICKTicks() {
        let seconds: Int64 = 1_700_000_000 + 11_644_473_600
        let ticks = seconds * 10_000_000

        let csv = "Filename,Date Modified,Date Created\n" +
            "clock.txt,\(ticks),\(ticks)\n" +
            "broken.txt,0,-1\n"

        let items = FileList.parseEFU(csv)
        XCTAssertEqual(items.count, 2)
        let expected = Date(timeIntervalSince1970: 1_700_000_000)
        assertDate(items[0].modifiedAt, expected)
        assertDate(items[0].createdAt, expected)
        XCTAssertNil(items[1].modifiedAt)
        XCTAssertNil(items[1].createdAt)
    }

    // MARK: - Attributes and duplicates

    func testFolderAttribute() {
        let csv = "Filename,Attributes\nfolder,16\nfile.txt,32\nboth,48\n"

        let items = FileList.parseEFU(csv)

        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(items.map(\.path), ["folder", "file.txt", "both"])
        XCTAssertEqual(items.map(\.isDirectory), [true, false, true])
    }

    func testDuplicateFilenameLastWins() {
        let csv = "Filename,Size,Tags\n" +
            "a.txt,1,first\n" +
            "b.txt,2,keep\n" +
            "a.txt,3,last\n"

        let items = FileList.parseEFU(csv)

        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items.map(\.path), ["a.txt", "b.txt"])
        XCTAssertEqual(items[0].size, 3)
        XCTAssertEqual(items[0].tags, ["last"])
        XCTAssertEqual(items[1].size, 2)
        XCTAssertEqual(items[1].tags, ["keep"])
    }

    // MARK: - Paths

    func testRelativePathResolution() {
        let base = URL(fileURLWithPath: "/Volumes/Data/Export")
        let csv = "Filename,Size\n" +
            "notes.txt,1\n" +
            "sub/inside.txt,2\n" +
            "other\\windows\\path.txt,3\n" +
            "/absolute/root.txt,4\n" +
            "\\\\server\\share\\file.txt,5\n" +
            "C:\\Users\\me\\file.txt,6\n"

        let items = FileList.parseEFU(csv, baseURL: base)

        XCTAssertEqual(items.map(\.path), [
            "/Volumes/Data/Export/notes.txt",
            "/Volumes/Data/Export/sub/inside.txt",
            "/Volumes/Data/Export/other/windows/path.txt",
            "/absolute/root.txt",
            "//server/share/file.txt",
            "C:/Users/me/file.txt"
        ])

        let withoutBase = FileList.parseEFU("Filename,Size\nsub/a.txt,1\n")
        XCTAssertEqual(withoutBase.first?.path, "sub/a.txt")
    }

    // MARK: - Encoding

    func testEncodeRoundTrip() {
        let modified = Date(timeIntervalSince1970: 1_700_000_000)
        let created = Date(timeIntervalSince1970: 1_600_000_000.5)
        let items: [FileListItem] = [
            FileListItem(
                path: "docs/report, final.txt",
                isDirectory: false,
                size: 42,
                modifiedAt: modified,
                createdAt: created,
                tags: ["alpha", "beta"],
                comment: "He said \"hi, there\""
            ),
            FileListItem(path: "Empty Folder", isDirectory: true)
        ]

        let csv = FileList.encodeEFU(items)

        XCTAssertTrue(csv.hasPrefix("Filename,Size,Date Modified,Date Created,Attributes,Tags,Comment\n"))
        XCTAssertTrue(csv.contains("\"alpha;beta\""))
        XCTAssertTrue(csv.contains(",32,"))
        XCTAssertTrue(csv.contains(",16,"))
        XCTAssertEqual(FileList.parseEFU(csv), items)
    }

    func testEncodeEmptyListStillWritesHeader() {
        XCTAssertEqual(
            FileList.encodeEFU([]),
            "Filename,Size,Date Modified,Date Created,Attributes,Tags,Comment\n"
        )
    }

    // MARK: - Index entries

    func testItemsFromIndexEntries() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let entry = IndexEntry.make(
            path: "/tmp/Needle/file.txt",
            isDirectory: false,
            size: 12,
            modifiedAt: date,
            createdAt: nil
        )

        let mapped = FileList.items(from: [entry])

        XCTAssertEqual(mapped.count, 1)
        XCTAssertEqual(mapped[0].path, entry.path)
        XCTAssertEqual(mapped[0].size, entry.size)
        XCTAssertEqual(mapped[0].isDirectory, entry.isDirectory)
        XCTAssertEqual(mapped[0].modifiedAt, entry.modifiedAt)
        XCTAssertEqual(mapped[0].createdAt, entry.createdAt)
        XCTAssertEqual(mapped[0].tags, entry.tags)
        XCTAssertEqual(mapped[0].comment, entry.comment)
    }
}
