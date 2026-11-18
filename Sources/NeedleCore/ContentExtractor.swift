import Foundation
import PDFKit
import Vision

/// Extracts searchable text from PDFs, images, and plain text/data files.
///
/// The entry point is synchronous and non-throwing. All work is bounded to
/// files no larger than 16 MB; plain text/data decoding is additionally
/// limited to 8 MB, matching the behavior previously used by the indexer.
public enum ContentExtractor {

    private static let maxFileSize = 16 * 1024 * 1024
    private static let maxTextFileSize = 8 * 1024 * 1024
    private static let cacheLimit = 128

    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "bmp", "tiff", "heic", "webp"
    ]

    private struct CacheKey: Hashable {
        let path: String
        let modified: Int64
        let size: Int
    }

    private static let cacheLock = NSLock()
    private static var cache: [CacheKey: String?] = [:]

    /// Returns searchable text for a file when it is a PDF (PDFKit text layer),
    /// a common image format (Vision OCR), or a plain text file.
    /// Returns nil for directories, unsupported types, empty text, or unreadable files.
    /// Must be synchronous, bounded to files <= 16 MB, and must never throw.
    public static func text(for url: URL, pathExtension: String, isDirectory: Bool) -> String? {
        guard !isDirectory, url.isFileURL else { return nil }
        guard let info = fileInfo(for: url), info.size <= maxFileSize else { return nil }

        let key = CacheKey(path: url.path, modified: info.modified, size: info.size)
        let cached = cachedResult(for: key)
        if cached.found { return cached.value }

        let ext = pathExtension.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let result: String?
        if ext == "pdf" {
            result = pdfText(for: url)
        } else if imageExtensions.contains(ext) {
            result = imageText(for: url)
        } else {
            result = dataText(for: url)
        }

        store(result, for: key)
        return result
    }

    // MARK: - Extractors

    private static func pdfText(for url: URL) -> String? {
        guard let document = PDFDocument(url: url) else { return nil }
        return trimmed(document.string)
    }

    private static func imageText(for url: URL) -> String? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        if #available(macOS 11.0, *) {
            let supported = Set((try? request.supportedRecognitionLanguages()) ?? [])
            let preferred = ["en-US", "tr-TR"].filter { supported.contains($0) }
            if !preferred.isEmpty { request.recognitionLanguages = preferred }
        }

        let handler = VNImageRequestHandler(url: url, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }

        let lines = (request.results ?? []).compactMap { observation in
            observation.topCandidates(1).first?.string
        }
        return trimmed(lines.joined(separator: "\n"))
    }

    private static func dataText(for url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              data.count <= maxTextFileSize else { return nil }
        let value = String(data: data, encoding: .utf8)
            ?? String(decoding: data, as: UTF8.self)
        guard trimmed(value) != nil else { return nil }
        return value
    }

    // MARK: - Helpers

    private static func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }

    private static func fileInfo(for url: URL) -> (size: Int, modified: Int64)? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = (attributes?[.size] as? NSNumber)?.intValue else { return nil }
        let modified: Int64
        if let date = attributes?[.modificationDate] as? Date {
            modified = Int64(date.timeIntervalSince1970 * 1_000_000)
        } else {
            modified = 0
        }
        return (size, modified)
    }

    // MARK: - Memoization

    private static func cachedResult(for key: CacheKey) -> (found: Bool, value: String?) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        guard let stored = cache[key] else { return (false, nil) }
        return (true, stored)
    }

    private static func store(_ value: String?, for key: CacheKey) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if cache.count >= cacheLimit { cache.removeAll() }
        cache[key] = value
    }
}
