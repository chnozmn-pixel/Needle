import Foundation
import Darwin

public enum FileSystem {

    // MARK: - Volume type

    /// Network volumes do not deliver FSEvents reliably, so the coordinator
    /// treats them with periodic reconciliation instead.
    public static func volumeKind(for path: String) -> VolumeKind {
        var info = statfs()
        let result = path.withCString { statfs($0, &info) }
        guard result == 0 else { return .unknown }
        // MNT_LOCAL == 0x00001000 in sys/mount.h
        return (info.f_flags & 0x1000) != 0 ? .local : .network
    }

    // MARK: - Single entry

    public static func entry(at path: String) -> IndexEntry? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        let isDirectory = (info.st_mode & S_IFMT) == S_IFDIR
        return IndexEntry.make(
            path: path,
            isDirectory: isDirectory,
            size: isDirectory ? 0 : Int64(info.st_size),
            modifiedAt: Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec)),
            createdAt: Date(timeIntervalSince1970: Double(info.st_birthtimespec.tv_sec))
        )
    }

    // MARK: - Fast full scan

    private static let packageExtensions: Set<String> = [
        "app", "bundle", "framework", "xcframework", "plugin", "xcworkspace",
        "playground", "photoslibrary", "xcodeproj", "component", "wdgt"
    ]

    /// POSIX `opendir`/`readdir`/`lstat` walker. This is dramatically faster
    /// than Foundation's URL enumeration for large trees. The callbacks are
    /// async so the caller (an actor) can yield between batches and keep
    /// processing searches while a long scan runs.
    public static func scan(
        root: String,
        skipPackageContents: Bool,
        excludedPaths: [String] = [],
        isCancelled: @escaping () -> Bool,
        onBatch: ([IndexEntry]) async throws -> Void,
        onProgress: (Int) async -> Void
    ) async throws {
        var batch: [IndexEntry] = []
        batch.reserveCapacity(2048)
        var scanned = 0
        var caughtError: Error?

        func flush() async {
            guard !batch.isEmpty else { return }
            do { try await onBatch(batch) }
            catch { caughtError = error }
            batch.removeAll(keepingCapacity: true)
        }

        func add(_ entry: IndexEntry) async {
            batch.append(entry)
            scanned += 1
            if batch.count >= 2048 { await flush() }
            if scanned % 512 == 0 { await onProgress(scanned) }
        }

        if let rootEntry = entry(at: root) { await add(rootEntry) }

        func isExcluded(_ path: String) -> Bool {
            excludedPaths.contains { path == $0 || path.hasPrefix($0 + "/") }
        }

        var stack: [String] = [root]
        while let directory = stack.popLast() {
            if isCancelled() { throw IndexError.cancelled }
            if caughtError != nil { break }
            if isExcluded(directory) { continue }

            guard let handle = directory.withCString({ opendir($0) }) else { continue }
            defer { closedir(handle) }

            while let item = readdir(handle) {
                if isCancelled() { throw IndexError.cancelled }

                let name = withUnsafePointer(to: &item.pointee.d_name) { pointer in
                    String(cString: UnsafeRawPointer(pointer).assumingMemoryBound(to: CChar.self))
                }
                if name == "." || name == ".." { continue }

                let path = (directory as NSString).appendingPathComponent(name)
                if isExcluded(path) { continue }
                var info = stat()
                guard lstat(path, &info) == 0 else { continue }

                let isDirectory = (info.st_mode & S_IFMT) == S_IFDIR
                await add(IndexEntry.make(
                    path: path,
                    isDirectory: isDirectory,
                    size: isDirectory ? 0 : Int64(info.st_size),
                    modifiedAt: Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec)),
                    createdAt: Date(timeIntervalSince1970: Double(info.st_birthtimespec.tv_sec))
                ))

                if isDirectory {
                    if skipPackageContents {
                        let ext = (name as NSString).pathExtension.lowercased()
                        if packageExtensions.contains(ext) { continue }
                    }
                    stack.append(path)
                }
            }
        }

        if let error = caughtError { throw error }
        await flush()
        await onProgress(scanned)
    }
}
