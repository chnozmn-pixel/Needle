import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Minimal loopback-only implementation of voidtools Everything's ETP control
/// plane (plain-text FTP commands on a single TCP connection).
///
/// There is deliberately no data channel, no TLS and no file transfer: `SIZE`,
/// `MDTM` and `MLST` are answered from the search handler, and transfer-related
/// commands are rejected with 500/502. Everything is bound to 127.0.0.1.
///
/// Column defaults follow Everything's opt-in style: `PATH` is emitted by
/// default because it identifies the result; size, dates and attributes are
/// emitted only after the corresponding `*_COLUMN 1` command. `RESULT_COUNT`
/// always reports the total number of matches before OFFSET/COUNT paging.
/// Because the handler accepts only a limit, results are fetched with a
/// generous upper bound (`max(10_000, count + offset)`, capped at 1,000,000)
/// and the total is capped at that same bound.
public final class SearchETPServer: @unchecked Sendable {

    private struct Session: Sendable {
        var authenticated = false
        var query = ""
        var count = 100
        var offset = 0
        var pathColumn = true
        var attributesColumn = false
        var sizeColumn = false
        var modifiedColumn = false
        var createdColumn = false
    }

    private enum FileInfoKind: Sendable {
        case size
        case mdtm
        case mlst
    }

    private let lock = NSLock()
    private let port: UInt16
    private let handler: @Sendable (String, Int) async -> [SearchResult]
    private let acceptQueue = DispatchQueue(label: "com.local.needle.etp", qos: .utility)

    private var listenFD: Int32 = -1
    private var source: DispatchSourceRead?
    private var clientSockets: Set<Int32> = []
    private var running = false
    private var boundPort: UInt16 = 0

    private static let maxLineBytes = 64 * 1_024
    private static let maxRequested = 1_000_000
    private static let maxUserValue = 100_000

    /// The OS-assigned port when started with port 0; otherwise the chosen port.
    public var listeningPort: UInt16 {
        lock.lock()
        defer { lock.unlock() }
        return boundPort
    }

    public init(port: UInt16 = 8_081, handler: @escaping @Sendable (String, Int) async -> [SearchResult]) {
        self.port = port
        self.handler = handler
    }

    deinit { stop() }

    public var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    public func start() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !running else { return }

        signal(SIGPIPE, SIG_IGN)

        let fd = socket(AF_INET, Int32(SOCK_STREAM), 0)
        guard fd >= 0 else { throw serverError(L("socket oluşturulamadı")) }

        var reuse: Int32 = 1
        _ = withUnsafePointer(to: &reuse) {
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, $0, socklen_t(MemoryLayout<Int32>.size))
        }

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bindResult = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            close(fd)
            throw serverError(L("%d portu bağlanamadı", port))
        }
        guard listen(fd, 32) == 0 else {
            close(fd)
            throw serverError(L("dinleme başlatılamadı"))
        }

        var actualAddress = sockaddr_in()
        var actualLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actualAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &actualLength)
            }
        }
        boundPort = UInt16(bigEndian: actualAddress.sin_port)

        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        let readSource = DispatchSource.makeReadSource(fileDescriptor: fd, queue: acceptQueue)
        readSource.setEventHandler { [weak self] in self?.acceptPending() }
        readSource.setCancelHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let current = self.listenFD
            self.lock.unlock()
            if current >= 0 { close(current) }
        }

        listenFD = fd
        source = readSource
        running = true
        readSource.resume()
    }

    public func stop() {
        lock.lock()
        guard running else { lock.unlock(); return }
        running = false
        let clients = clientSockets
        clientSockets.removeAll()
        let currentSource = source
        source = nil
        lock.unlock()

        currentSource?.cancel()
        for fd in clients { close(fd) }
    }

    // MARK: - Accept / client loop

    private func acceptPending() {
        while true {
            lock.lock()
            let fd = listenFD
            lock.unlock()
            guard fd >= 0 else { return }

            let client = accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return
            }
            let flags = fcntl(client, F_GETFL)
            _ = fcntl(client, F_SETFL, flags & ~O_NONBLOCK)
            lock.lock()
            clientSockets.insert(client)
            lock.unlock()
            DispatchQueue(label: "com.local.needle.etp.client").async { [weak self] in
                self?.handle(client)
            }
        }
    }

    private func handle(_ client: Int32) {
        var session = Session()
        write(client, Self.lines("220 Welcome to Needle ETP"))

        var pending = Data()
        let scratch = UnsafeMutableRawPointer.allocate(byteCount: 8_192, alignment: 1)
        defer { scratch.deallocate() }

        while true {
            if let raw = Self.popLine(&pending) {
                if raw.utf8.count > Self.maxLineBytes {
                    write(client, Self.lines("500 Line too long."))
                    break
                }
                if !process(raw, client: client, session: &session) { break }
                continue
            }
            if pending.count > Self.maxLineBytes {
                write(client, Self.lines("500 Line too long."))
                break
            }
            let count = recv(client, scratch, 8_192, 0)
            if count <= 0 {
                if count < 0 && errno == EINTR { continue }
                break
            }
            pending.append(scratch.assumingMemoryBound(to: UInt8.self), count: count)
        }
        closeClient(client)
    }

    private func closeClient(_ fd: Int32) {
        lock.lock()
        clientSockets.remove(fd)
        lock.unlock()
        close(fd)
    }

    private static func popLine(_ buffer: inout Data) -> String? {
        let separator = Data([0x0D, 0x0A])
        guard let range = buffer.range(of: separator) else { return nil }
        let line = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
        buffer.removeSubrange(buffer.startIndex..<range.upperBound)
        return String(decoding: line, as: UTF8.self)
    }

    /// Runs an async response on the cooperative pool while keeping this
    /// client's serial queue and session state single-threaded.
    private func runAsync(_ work: @escaping @Sendable () async -> Void) {
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            await work()
            semaphore.signal()
        }
        semaphore.wait()
    }

    private func write(_ fd: Int32, _ data: Data) {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let written = send(fd, base.advanced(by: offset), raw.count - offset, 0)
                if written <= 0 {
                    if errno == EINTR { continue }
                    return
                }
                offset += written
            }
        }
    }

    // MARK: - Command dispatch

    /// FTP/ETP commands are case-insensitive. Splitting at the first whitespace
    /// keeps the remainder intact so search text may contain spaces.
    private static func split(_ text: String) -> (command: String, argument: String) {
        let characters = Array(text)
        var index = 0
        while index < characters.count, characters[index] != " ", characters[index] != "\t" {
            index += 1
        }
        let command = String(characters[0..<index]).uppercased()
        while index < characters.count, characters[index] == " " || characters[index] == "\t" {
            index += 1
        }
        var end = characters.count
        while end > index, characters[end - 1] == " " || characters[end - 1] == "\t" {
            end -= 1
        }
        return (command, String(characters[index..<end]))
    }

    private func process(_ raw: String, client: Int32, session: inout Session) -> Bool {
        let (command, argument) = Self.split(raw)
        switch command {
        case "USER":
            session.authenticated = false
            write(client, Self.lines("331 Password required"))
        case "PASS":
            // Loopback only and no configured credential: PASS always succeeds.
            session.authenticated = true
            write(client, Self.lines("230 Logged on."))
        case "FEAT":
            write(client, Self.lines([
                "211-Features:",
                " MDTM",
                " REST STREAM",
                " SIZE",
                " MLST type*;size*;modify*;",
                " MLSD",
                " UTF8",
                " EVERYTHING",
                "211 End"
            ]))
        case "HELP":
            write(client, Self.lines([
                "214-Site commands:",
                " EVERYTHING",
                "214 End"
            ]))
        case "SYST":
            write(client, Self.lines("215 UNIX Type: L8"))
        case "NOOP":
            write(client, Self.lines("200 NOOP ok."))
        case "QUIT":
            write(client, Self.lines("221 Goodbye."))
            return false
        case "SITE":
            let (subcommand, value) = Self.split(argument)
            if subcommand == "EVERYTHING" {
                handleEverything(value, client: client, session: &session)
            } else {
                write(client, Self.lines("502 Command not implemented."))
            }
        case "EVERYTHING":
            handleEverything(argument, client: client, session: &session)
        // Bare subcommands are accepted as a convenience in addition to the
        // required `SITE EVERYTHING ...` and `EVERYTHING ...` spellings.
        case "SEARCH", "COUNT", "OFFSET", "QUERY",
             "PATH_COLUMN", "ATTRIBUTES_COLUMN", "SIZE_COLUMN",
             "DATE_MODIFIED_COLUMN", "DATE_CREATED_COLUMN":
            handleEverything(raw, client: client, session: &session)
        case "SIZE":
            runAsync { [weak self] in await self?.answerFileInfo(.size, path: argument, client: client) }
        case "MDTM":
            runAsync { [weak self] in await self?.answerFileInfo(.mdtm, path: argument, client: client) }
        case "MLST":
            runAsync { [weak self] in await self?.answerFileInfo(.mlst, path: argument, client: client) }
        case "PASV", "EPSV", "PORT", "EPRT", "LIST", "MLSD", "RETR", "STOR":
            write(client, Self.lines("502 Command not implemented."))
        default:
            write(client, Self.lines("500 Unknown command."))
        }
        return true
    }

    private func handleEverything(_ argument: String, client: Int32, session: inout Session) {
        let (command, value) = Self.split(argument)
        switch command {
        case "SEARCH":
            session.query = value
            write(client, Self.lines("200 Search set to (\(value))."))
        case "COUNT":
            let number = Self.clamp(value, fallback: session.count)
            session.count = number
            write(client, Self.lines("200 Count set to (\(number))."))
        case "OFFSET":
            let number = Self.clamp(value, fallback: session.offset)
            session.offset = number
            write(client, Self.lines("200 Offset set to (\(number))."))
        case "PATH_COLUMN":
            if setColumn(value, client: client, apply: { session.pathColumn = $0 }) {
                write(client, Self.lines("200 PATH_COLUMN set to (\(session.pathColumn ? 1 : 0))."))
            }
        case "ATTRIBUTES_COLUMN":
            if setColumn(value, client: client, apply: { session.attributesColumn = $0 }) {
                write(client, Self.lines("200 ATTRIBUTES_COLUMN set to (\(session.attributesColumn ? 1 : 0))."))
            }
        case "SIZE_COLUMN":
            if setColumn(value, client: client, apply: { session.sizeColumn = $0 }) {
                write(client, Self.lines("200 SIZE_COLUMN set to (\(session.sizeColumn ? 1 : 0))."))
            }
        case "DATE_MODIFIED_COLUMN":
            if setColumn(value, client: client, apply: { session.modifiedColumn = $0 }) {
                write(client, Self.lines("200 DATE_MODIFIED_COLUMN set to (\(session.modifiedColumn ? 1 : 0))."))
            }
        case "DATE_CREATED_COLUMN":
            if setColumn(value, client: client, apply: { session.createdColumn = $0 }) {
                write(client, Self.lines("200 DATE_CREATED_COLUMN set to (\(session.createdColumn ? 1 : 0))."))
            }
        case "QUERY":
            let snapshot = session
            runAsync { [weak self] in await self?.answerQuery(client: client, session: snapshot) }
        default:
            write(client, Self.lines("500 Unknown EVERYTHING command."))
        }
    }

    private func setColumn(_ value: String, client: Int32, apply: (Bool) -> Void) -> Bool {
        guard let flag = Self.columnFlag(value) else {
            write(client, Self.lines("500 Invalid column value."))
            return false
        }
        apply(flag)
        return true
    }

    private static func clamp(_ text: String, fallback: Int) -> Int {
        guard let number = Int(text), number >= 0 else { return fallback }
        return min(number, maxUserValue)
    }

    private static func columnFlag(_ text: String) -> Bool? {
        switch text {
        case "0": return false
        case "1": return true
        default: return nil
        }
    }

    // MARK: - Responses

    private func answerQuery(client: Int32, session: Session) async {
        let upperBound = min(Self.maxRequested, max(10_000, session.count + session.offset))
        let results = await handler(session.query, upperBound)
        // The handler only takes a limit, so this is the best available total.
        let total = min(results.count, upperBound)

        var response = ["200-Query results", " RESULT_COUNT \(total)"]
        for result in results.dropFirst(session.offset).prefix(session.count) {
            let entry = result.entry
            if session.pathColumn { response.append(" PATH \(Self.adaptPath(entry.path))") }
            if session.attributesColumn { response.append(" ATTRIBUTES \(entry.isDirectory ? 16 : 0)") }
            if session.sizeColumn { response.append(" SIZE \(entry.isDirectory ? 0 : entry.size)") }
            if session.modifiedColumn { response.append(" DATE_MODIFIED \(Self.fileTime(entry.modifiedAt))") }
            if session.createdColumn { response.append(" DATE_CREATED \(Self.fileTime(entry.createdAt))") }
            response.append(entry.isDirectory ? " FOLDER \(entry.name)" : " FILE \(entry.name)")
        }
        response.append("200 End.")
        write(client, Self.lines(response))
    }

    private func answerFileInfo(_ kind: FileInfoKind, path rawPath: String, client: Int32) async {
        guard !rawPath.isEmpty else {
            write(client, Self.lines("500 Syntax error."))
            return
        }
        let name = (rawPath as NSString).lastPathComponent
        let results = await handler(name, 1_000)
        let target = Self.adaptPath(rawPath)
        let match = results.first { Self.adaptPath($0.entry.path) == target }
            ?? results.first { Self.adaptPath($0.entry.path).caseInsensitiveCompare(target) == .orderedSame }
        guard let entry = match?.entry else {
            write(client, Self.lines("550 File not found."))
            return
        }

        let path = Self.adaptPath(entry.path)
        switch kind {
        case .size:
            write(client, Self.lines("200 \(entry.isDirectory ? 0 : entry.size)"))
        case .mdtm:
            write(client, Self.lines("213 \(Self.utcString(entry.modifiedAt))"))
        case .mlst:
            let type = entry.isDirectory ? "dir" : "file"
            write(client, Self.lines([
                "250-Listing \(path)",
                " type=\(type); modify=\(Self.utcString(entry.modifiedAt)); size=\(entry.isDirectory ? 0 : entry.size); \(path)",
                "250 End."
            ]))
        }
    }

    /// Needle stores POSIX paths while Everything clients expect DOS-style
    /// paths. Emit POSIX paths unchanged when already rooted, otherwise prefix
    /// a single `/`. No drive letter is invented: clients that prepend one
    /// treat the leading slash as a relative root.
    private static func adaptPath(_ path: String) -> String {
        path.hasPrefix("/") ? path : "/" + path
    }

    /// Windows FILETIME: 100ns ticks since 1601-01-01 UTC, clamped at zero.
    private static func fileTime(_ date: Date?) -> UInt64 {
        guard let date else { return 0 }
        let ticks = (date.timeIntervalSince1970 + 11_644_473_600) * 10_000_000
        return ticks <= 0 ? 0 : UInt64(ticks.rounded())
    }

    private static func utcString(_ date: Date?) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMddHHmmss"
        return formatter.string(from: date ?? Date(timeIntervalSince1970: 0))
    }

    private static func lines(_ lines: [String]) -> Data {
        Data((lines.joined(separator: "\r\n") + "\r\n").utf8)
    }

    private static func lines(_ line: String) -> Data {
        lines([line])
    }

    private func serverError(_ message: String) -> NSError {
        NSError(domain: "NeedleETPServer", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
