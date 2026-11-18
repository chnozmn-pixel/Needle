import Foundation
import CoreServices

/// Fast update path: FSEvents reports changed paths directly, so we only
/// re-stat those entries instead of walking the tree again.
public final class FSEventsWatcher {
    private var stream: FSEventStreamRef?
    fileprivate let onChange: @Sendable ([String]) -> Void
    private let paths: [String]

    public init(paths: [String], onChange: @escaping @Sendable ([String]) -> Void) {
        self.paths = paths
        self.onChange = onChange
    }

    deinit { stop() }

    public func start() {
        guard !paths.isEmpty, stream == nil else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let flags: FSEventStreamCreateFlags = UInt32(
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
        )

        guard let newStream = FSEventStreamCreate(
            kCFAllocatorDefault,
            fseventsCallback,
            &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.7,
            flags
        ) else { return }

        stream = newStream
        FSEventStreamSetDispatchQueue(newStream, DispatchQueue(label: "needle.fsevents"))
        FSEventStreamStart(newStream)
    }

    public func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }
}

private let fseventsCallback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
    guard let info else { return }
    let watcher = Unmanaged<FSEventsWatcher>.fromOpaque(info).takeUnretainedValue()
    let rawPaths = eventPaths.assumingMemoryBound(to: UnsafePointer<Int8>.self)
    var paths: [String] = []
    paths.reserveCapacity(count)
    for i in 0..<count {
        paths.append(String(cString: rawPaths[i]))
    }
    watcher.onChange(paths)
}
