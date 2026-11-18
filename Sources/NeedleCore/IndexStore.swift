import Foundation
import CoreGraphics

/// Cancellation token shared between the MainActor UI and the scanning queue.
public final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    public init() {}

    public func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    public func reset() {
        lock.lock()
        cancelled = false
        lock.unlock()
    }

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

/// Owns the persistent database, the in-memory engine and the change stream.
/// All mutations are serialized by the actor.
public actor IndexStore {

    private let database: IndexDatabase
    private let engine = SearchEngine()
    private let cancellation: CancellationFlag
    private var statusHandler: (@Sendable (IndexStatus) -> Void)?
    private var roots: [IndexRoot] = []
    private var watcher: FSEventsWatcher?
    private var status = IndexStatus()
    private var isScanning = false
    private var spotlightEnabled = true
    private var skipPackageContents = true
    private var networkReconciliationTask: Task<Void, Never>?
    private var scanConfiguration = NetworkScanConfiguration()
    private var lastNetworkScanAt: Date?
    private let initialRoots: [IndexRoot]?
    private let internalExcludedPaths: [String]
    private var userExcludedPaths: [String] = []

    private var excludedPaths: [String] { internalExcludedPaths + userExcludedPaths }

    public init(
        databasePath: String,
        cancellation: CancellationFlag,
        initialRoots: [IndexRoot]? = nil
    ) {
        self.database = IndexDatabase(path: databasePath)
        self.cancellation = cancellation
        self.initialRoots = initialRoots

        // Exclude only our own database files, not their whole parent folder —
        // a caller may legitimately index that folder (the tests do).
        var excluded = [databasePath, databasePath + "-wal", databasePath + "-shm"]
        let savedState = NSHomeDirectory() + "/Library/Saved Application State/com.local.needle.savedState"
        excluded.append(savedState)
        self.internalExcludedPaths = excluded
    }

    public func setStatusHandler(_ handler: @escaping @Sendable (IndexStatus) -> Void) {
        statusHandler = handler
        publish()
    }

    // MARK: - Startup

    public func start() async {
        do {
            try database.open()
            var savedRoots = database.loadRoots()
            if savedRoots.isEmpty {
                if let initialRoots, !initialRoots.isEmpty {
                    savedRoots = initialRoots
                } else {
                    let home = NSHomeDirectory()
                    savedRoots = [IndexRoot(path: home, kind: FileSystem.volumeKind(for: home))]
                }
                try database.setRoots(savedRoots)
            }
            roots = savedRoots
            spotlightEnabled = (database.meta("spotlightEnabled") != "0")
            skipPackageContents = (database.meta("skipPackageContents") != "0")
            userExcludedPaths = (database.meta("excludedFolders") ?? "")
                .split(separator: "\n")
                .map(String.init)
                .map { EntryID.normalize($0) }
                .filter { !$0.isEmpty }
            scanConfiguration = NetworkScanConfiguration(
                schedule: NetworkScanSchedule(rawValue: database.meta("networkScanSchedule") ?? "")
                    ?? .daily,
                hour: Int(database.meta("networkScanHour") ?? "") ?? 2,
                minute: Int(database.meta("networkScanMinute") ?? "") ?? 0,
                idleMinutes: Int(database.meta("networkIdleMinutes") ?? "") ?? 15
            )
            if let raw = database.meta("lastNetworkScanAt"), let time = TimeInterval(raw) {
                lastNetworkScanAt = Date(timeIntervalSince1970: time)
            }

            let entries = try database.loadAllEntries()
            engine.rebuild(from: entries)

            status.totalEntries = entries.count
            status.spotlightEnabled = spotlightEnabled
            status.phase = .watching
            status.message = entries.isEmpty ? L("İlk tarama gerekiyor") : nil
            publish()

            if entries.isEmpty { await rescan() }
            else { restartWatcher() }
            startNetworkReconciliation()
        } catch {
            fail(error.localizedDescription)
        }
    }

    // MARK: - Configuration

    public func currentRoots() -> [IndexRoot] { roots }
    public func isSpotlightEnabled() -> Bool { spotlightEnabled }
    public func isSkippingPackageContents() -> Bool { skipPackageContents }
    public func excludedFolders() -> [String] { userExcludedPaths }
    public func isHTTPServerEnabled() -> Bool { database.meta("httpEnabled") == "1" }
    public func httpServerPort() -> UInt16 {
        UInt16(database.meta("httpPort") ?? "") ?? 8_080
    }

    public func setHTTPServerSettings(enabled: Bool, port: UInt16) {
        try? database.setMeta("httpEnabled", value: enabled ? "1" : "0")
        try? database.setMeta("httpPort", value: String(port))
    }

    public func networkScanConfiguration() -> NetworkScanConfiguration { scanConfiguration }
    public func lastNetworkScanDate() -> Date? { lastNetworkScanAt }

    public func setNetworkScanConfiguration(_ configuration: NetworkScanConfiguration) {
        scanConfiguration = configuration
        try? database.setMeta("networkScanSchedule", value: configuration.schedule.rawValue)
        try? database.setMeta("networkScanHour", value: String(configuration.hour))
        try? database.setMeta("networkScanMinute", value: String(configuration.minute))
        try? database.setMeta("networkIdleMinutes", value: String(configuration.idleMinutes))
        // Re-arm the timer so a changed time or mode takes effect immediately.
        startNetworkReconciliation()
    }

    public func setExcludedFolders(_ paths: [String]) async {
        let cleaned = paths
            .map { EntryID.normalize($0) }
            .filter { !$0.isEmpty && !internalExcludedPaths.contains($0) }
        userExcludedPaths = Array(Set(cleaned)).sorted()
        try? database.setMeta("excludedFolders", value: userExcludedPaths.joined(separator: "\n"))
        await rescan()
    }

    public func setSpotlight(_ enabled: Bool) {
        spotlightEnabled = enabled
        try? database.setMeta("spotlightEnabled", value: enabled ? "1" : "0")
        status.spotlightEnabled = enabled
        publish()
    }

    public func setSkipPackageContents(_ value: Bool) {
        skipPackageContents = value
        try? database.setMeta("skipPackageContents", value: value ? "1" : "0")
    }

    // MARK: - Roots

    public func addRoot(path: String) async -> String? {
        let clean = EntryID.normalize(path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: clean, isDirectory: &isDirectory), isDirectory.boolValue else {
            return L("Klasör bulunamadı: %@", clean)
        }
        guard !roots.contains(where: { $0.path == clean }) else { return L("Bu klasör zaten listede.") }

        roots.append(IndexRoot(path: clean, kind: FileSystem.volumeKind(for: clean)))
        try? database.setRoots(roots)
        await rescan()
        return nil
    }

    public func removeRoot(path: String) async {
        roots.removeAll { $0.path == path }
        try? database.setRoots(roots)
        try? database.deleteSubtree(path: path)
        let entries = (try? database.loadAllEntries()) ?? []
        engine.rebuild(from: entries)
        status.totalEntries = entries.count
        restartWatcher()
        publish()
    }

    /// Adds mounted network volumes (SMB/AFP/etc.) that are not already roots.
    public func addNetworkVolumes() async -> Int {
        guard let volumes = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: nil,
            options: [.skipHiddenVolumes]
        ) else { return 0 }

        var added = 0
        for url in volumes {
            let path = EntryID.normalize(url.path)
            guard path.hasPrefix("/Volumes/"), path != "/Volumes",
                  !roots.contains(where: { $0.path == path }) else { continue }
            guard FileSystem.volumeKind(for: path) == .network else { continue }
            roots.append(IndexRoot(path: path, kind: .network))
            added += 1
        }
        guard added > 0 else { return 0 }
        try? database.setRoots(roots)
        await rescan()
        return added
    }

    // MARK: - Scanning

    public func rescan() async {
        guard !isScanning else { return }
        isScanning = true
        cancellation.reset()
        defer { isScanning = false }

        status.phase = .scanning
        status.scannedInPass = 0
        status.message = nil
        publish()

        do {
            try database.beginTransaction()
            try database.deleteAll()
            engine.beginBulk()

            for root in roots {
                try await FileSystem.scan(
                    root: root.path,
                    skipPackageContents: skipPackageContents,
                    excludedPaths: excludedPaths,
                    isCancelled: { [cancellation] in cancellation.isCancelled },
                    onBatch: { [database, engine] batch in
                        for entry in batch { try database.upsert(entry) }
                        // Feed the engine immediately so search results stay
                        // live while the scan is still running.
                        engine.apply(batch.map { .upsert($0) })
                        // Yield so the actor can answer search requests while
                        // a long initial scan is in progress.
                        await Task.yield()
                    },
                    onProgress: { count in
                        self.status.scannedInPass = count
                        self.status.totalEntries = count
                        self.publish()
                    }
                )
            }

            try database.commit()
            engine.finishBulk()
            let entries = try database.loadAllEntries()
            status.totalEntries = entries.count
            status.phase = .watching
            status.scannedInPass = entries.count
            status.lastUpdate = Date()
            status.message = nil
            if roots.contains(where: { $0.kind == .network }) { recordNetworkScan() }
            publish()
            restartWatcher()
        } catch {
            database.rollback()
            let wasCancelled: Bool = {
                if case IndexError.cancelled = error { return true }
                return cancellation.isCancelled
            }()
            status.phase = wasCancelled ? .watching : .error
            status.message = wasCancelled ? L("Tarama iptal edildi") : error.localizedDescription
            publish()
        }
    }

    // MARK: - Fast updates

    public func handleEvents(_ paths: [String]) async {
        guard !isScanning else { return }
        var changes: [IndexChange] = []

        for path in paths {
            let clean = EntryID.normalize(path)
            guard roots.contains(where: { clean == $0.path || clean.hasPrefix($0.path + "/") }) else { continue }
            // Ignore our own database files — writing them would otherwise
            // generate another FSEvent and create an endless update loop.
            guard !excludedPaths.contains(where: {
                clean == $0 || clean.hasPrefix($0 + "/")
            }) else { continue }

            if let entry = FileSystem.entry(at: clean) {
                try? database.upsert(entry)
                changes.append(.upsert(entry))
            } else {
                try? database.deleteSubtree(path: clean)
                changes.append(.delete(path: clean))
            }
        }

        guard !changes.isEmpty else { return }
        engine.apply(changes)
        status.totalEntries = engine.indexedCount()
        status.lastUpdate = Date()
        publish()
    }

    /// Reconciles only network roots. Local entries stay untouched, so this is
    /// much cheaper than a full rescan and is what the schedule uses.
    public func rescanNetworkRoots() async {
        let networkRoots = roots.filter { $0.kind == .network }
        guard !networkRoots.isEmpty, !isScanning else { return }
        isScanning = true
        cancellation.reset()
        defer { isScanning = false }

        status.phase = .scanning
        status.scannedInPass = 0
        status.message = L("Ağ konumları taranıyor")
        publish()

        do {
            try database.beginTransaction()
            for root in networkRoots { try database.deleteSubtree(path: root.path) }

            for root in networkRoots {
                try await FileSystem.scan(
                    root: root.path,
                    skipPackageContents: skipPackageContents,
                    excludedPaths: excludedPaths,
                    isCancelled: { [cancellation] in cancellation.isCancelled },
                    onBatch: { [database] batch in
                        for entry in batch { try database.upsert(entry) }
                        await Task.yield()
                    },
                    onProgress: { count in
                        self.status.scannedInPass = count
                        self.publish()
                    }
                )
            }

            try database.commit()
            let entries = try database.loadAllEntries()
            engine.rebuild(from: entries)
            recordNetworkScan()
            status.totalEntries = entries.count
            status.phase = .watching
            status.scannedInPass = entries.count
            status.lastUpdate = Date()
            status.message = nil
            publish()
        } catch {
            database.rollback()
            let wasCancelled: Bool = {
                if case IndexError.cancelled = error { return true }
                return cancellation.isCancelled
            }()
            status.phase = wasCancelled ? .watching : .error
            status.message = wasCancelled ? L("Ağ taraması iptal edildi") : error.localizedDescription
            publish()
        }
    }

    private func recordNetworkScan() {
        lastNetworkScanAt = Date()
        try? database.setMeta("lastNetworkScanAt", value: String(lastNetworkScanAt!.timeIntervalSince1970))
    }

    // MARK: - Network scan scheduling

    /// FSEvents is unreliable on network shares, so they get a scheduled
    /// reconciliation instead. The mode is user-configurable: daily at a chosen
    /// time, when the Mac has been idle, hourly, or the legacy five minutes.
    private func startNetworkReconciliation() {
        networkReconciliationTask?.cancel()
        networkReconciliationTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let configuration = await self.networkScanConfiguration()
                let delay = await self.delayUntilNextNetworkScan(for: configuration)
                if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
                guard !Task.isCancelled else { return }
                await self.runScheduledNetworkScan(configuration)
            }
        }
    }

    private func delayUntilNextNetworkScan(for configuration: NetworkScanConfiguration) -> UInt64 {
        let now = Date()
        let seconds: TimeInterval
        switch configuration.schedule {
        case .daily:
            var components = Calendar.current.dateComponents([.year, .month, .day], from: now)
            components.hour = configuration.hour
            components.minute = configuration.minute
            components.second = 0
            var next = Calendar.current.date(from: components) ?? now.addingTimeInterval(24 * 3600)
            if next <= now { next = next.addingTimeInterval(24 * 3600) }
            seconds = next.timeIntervalSince(now)
        case .idle:
            seconds = 60 // poll the idle timer once a minute
        case .every5Minutes:
            seconds = 5 * 60
        case .hourly:
            seconds = 60 * 60
        }
        return UInt64(max(0, seconds) * 1_000_000_000)
    }

    private func runScheduledNetworkScan(_ configuration: NetworkScanConfiguration) async {
        guard roots.contains(where: { $0.kind == .network }) else { return }

        switch configuration.schedule {
        case .idle:
            let anyInput = CGEventType(rawValue: UInt32.max)!
            let idleSeconds = CGEventSource.secondsSinceLastEventType(
                .hidSystemState, eventType: anyInput
            )
            guard idleSeconds >= Double(configuration.idleMinutes * 60) else { return }
            // Idle mode is still a daily reconciliation, not a continuous watch.
            if let last = lastNetworkScanAt, Date().timeIntervalSince(last) < 24 * 3600 { return }
        case .daily:
            // A manual full rescan may already have covered today's slot.
            if let last = lastNetworkScanAt, Date().timeIntervalSince(last) < 6 * 3600 { return }
        case .every5Minutes, .hourly:
            break
        }

        await rescanNetworkRoots()
    }

    private func restartWatcher() {
        watcher?.stop()
        guard !roots.isEmpty else { return }
        let watchedPaths = roots.map(\.path)
        let store = self
        watcher = FSEventsWatcher(paths: watchedPaths) { paths in
            Task { await store.handleEvents(paths) }
        }
        watcher?.start()
        status.watchedPaths = watchedPaths.filter { FileSystem.volumeKind(for: $0) == .local }.count
        publish()
    }

    // MARK: - Search

    public func search(_ query: ParsedQuery, limit: Int) async -> [SearchResult] {
        var results = engine.search(query, limit: limit)
        guard spotlightEnabled, !query.isEmpty else { return results }

        // mdfind is a subprocess and can take hundreds of ms. Skip it while a
        // scan is running so typing stays responsive; the local index already
        // covers everything scanned so far.
        guard !isScanning else { return results }

        let hits = await SpotlightSearch.search(
            query: query,
            roots: roots.map(\.path),
            limit: 250
        )
        var seen = Set(results.map(\.id))
        for hit in hits where seen.insert(hit.id).inserted {
            results.append(SearchResult(entry: hit.entry, source: .spotlight))
            if results.count >= limit { break }
        }
        return results
    }

    // MARK: - Status

    private func fail(_ message: String) {
        status.phase = .error
        status.message = message
        publish()
    }

    private func publish() {
        status.rootCount = roots.count
        status.revision += 1
        statusHandler?(status)
    }
}
