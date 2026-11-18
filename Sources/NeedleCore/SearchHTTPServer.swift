import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Minimal local HTTP interface, similar in spirit to Everything's HTTP server.
///
/// `GET /?s=query&format=json` returns JSON; omitting `format` returns a small
/// HTML result page. The server binds to loopback only and is intentionally
/// read-only.
public final class SearchHTTPServer: @unchecked Sendable {

    private let lock = NSLock()
    private let port: UInt16
    private let handler: @Sendable (String, Int) async -> [SearchResult]
    private let queue = DispatchQueue(label: "com.local.needle.http", qos: .utility, attributes: .concurrent)

    private var listenFD: Int32 = -1
    private var source: DispatchSourceRead?
    private var clientSockets: Set<Int32> = []
    private var running = false
    private var boundPort: UInt16 = 0

    /// The OS-assigned port when started with port 0; otherwise the chosen port.
    public var listeningPort: UInt16 {
        lock.lock()
        defer { lock.unlock() }
        return boundPort
    }

    public init(port: UInt16 = 8080, handler: @escaping @Sendable (String, Int) async -> [SearchResult]) {
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

        let readSource = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        readSource.setEventHandler { [weak self] in self?.acceptPending() }
        readSource.setCancelHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let current = self.listenFD
            self.listenFD = -1
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

    // MARK: - Accept / request

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
            queue.async { [weak self] in self?.handle(client) }
        }
    }

    private func handle(_ client: Int32) {
        var data = Data()
        let bufferSize = 8_192
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 1)
        defer { buffer.deallocate() }

        while data.count < 64 * 1_024 {
            let count = recv(client, buffer, bufferSize, 0)
            if count <= 0 { break }
            data.append(buffer.assumingMemoryBound(to: UInt8.self), count: count)
            if let text = String(data: data, encoding: .utf8), text.contains("\r\n\r\n") { break }
        }
        guard !data.isEmpty, let request = String(data: data, encoding: .utf8) else {
            closeClient(client)
            return
        }

        let firstLine = request.split(separator: "\r", maxSplits: 1).first.map(String.init) ?? ""
        let pieces = firstLine.split(separator: " ")
        guard pieces.count >= 2 else {
            write(client, badRequest)
            closeClient(client)
            return
        }

        let target = pieces[1]
        let split = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let parameters = parseParameters(split.count > 1 ? String(split[1]) : "")
        let term = parameters["s"] ?? parameters["q"] ?? parameters["search"] ?? ""
        let format = (parameters["format"] ?? "html").lowercased()
        let limit = Int(parameters["count"] ?? parameters["limit"] ?? "") ?? 200

        Task { [weak self] in
            defer { self?.closeClient(client) }
            guard let self else { return }
            let results = await self.handler(term, min(max(limit, 1), 1_000))
            let isJSON = format == "json"
            let body = isJSON
                ? Self.jsonResponse(query: term, results: results)
                : Self.htmlResponse(query: term, results: results)
            self.write(client, Self.payload(body: body, contentType: isJSON ? "application/json; charset=utf-8" : "text/html; charset=utf-8"))
        }
    }

    private func closeClient(_ fd: Int32) {
        lock.lock()
        clientSockets.remove(fd)
        lock.unlock()
        close(fd)
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

    // MARK: - Parsing and rendering

    private func parseParameters(_ raw: String) -> [String: String] {
        var result: [String: String] = [:]
        for pair in raw.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let key = decode(String(parts[0])).lowercased()
            result[key] = decode(String(parts[1]))
        }
        return result
    }

    private func decode(_ value: String) -> String {
        value.replacingOccurrences(of: "+", with: " ")
            .removingPercentEncoding ?? value
    }

    private static func payload(body: Data, contentType: String) -> Data {
        let header = "HTTP/1.1 200 OK\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n"
        var data = Data(header.utf8)
        data.append(body)
        return data
    }

    private static func jsonResponse(query: String, results: [SearchResult]) -> Data {
        let rows: [[String: Any]] = results.map { result in
            [
                "name": result.entry.name,
                "path": result.entry.path,
                "isDirectory": result.entry.isDirectory,
                "size": result.entry.size,
                "modified": result.entry.modifiedAt?.timeIntervalSince1970 ?? NSNull(),
                "source": result.source.rawValue
            ]
        }
        let object: [String: Any] = [
            "query": query,
            "count": rows.count,
            "results": rows
        ]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]))
            ?? Data("{\"error\":\"serialization\"}".utf8)
    }

    private static func htmlResponse(query: String, results: [SearchResult]) -> Data {
        var html = """
        <!doctype html><html><head><meta charset="utf-8"><title>Needle</title>
        <style>body{font:13px -apple-system,sans-serif;margin:24px;color:#222}
        input{padding:6px;width:360px}li{margin:3px 0}a{color:#06c;text-decoration:none}</style></head><body>
        <h1>Needle</h1><form action="/"><input name="s" value="\(escape(query))" autofocus>
        <button type="submit">Ara</button></form><p>\(results.count) sonuç</p><ul>
        """
        for result in results {
            let href = result.entry.url.absoluteString
                .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? hrefFallback(result)
            html += "<li><a href=\"\(escape(href))\">\(escape(result.entry.name))</a> — \(escape(result.entry.path))</li>"
        }
        html += "</ul></body></html>"
        return Data(html.utf8)
    }

    private static func hrefFallback(_ result: SearchResult) -> String {
        "file://" + (result.entry.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? result.entry.path)
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private var badRequest: Data {
        Data("HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
    }

    private func serverError(_ message: String) -> NSError {
        NSError(domain: "NeedleHTTPServer", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
