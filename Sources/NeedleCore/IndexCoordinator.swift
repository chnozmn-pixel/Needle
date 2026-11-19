import Foundation
import Combine

/// MainActor-facing state object used by the SwiftUI views.
@MainActor
public final class IndexCoordinator: ObservableObject {
    @Published public var status = IndexStatus()
    @Published public var roots: [IndexRoot] = []
    @Published public var spotlightEnabled = true
    @Published public var skipPackageContents = true
    @Published public var finderMetadataEnabled = true
    @Published public var excludedFolders: [String] = []
    @Published public var fileLists: [FileListInfo] = []
    @Published public var journalEntries: [IndexJournalEntry] = []
    @Published public var httpServerEnabled = false
    @Published public var httpServerPort: UInt16 = 8_080
    @Published public var httpServerRunning = false
    @Published public var etpServerEnabled = false
    @Published public var etpServerPort: UInt16 = 8_081
    @Published public var etpServerRunning = false
    @Published public var networkScanConfiguration = NetworkScanConfiguration()
    @Published public var lastNetworkScanDate: Date?
    @Published public var errorMessage: String?
    @Published public var infoMessage: String?

    private let store: IndexStore
    private let cancellation = CancellationFlag()
    private var httpServer: SearchHTTPServer?
    private var etpServer: SearchETPServer?

    private static let etpEnabledKey = "needle.etpEnabled"
    private static let etpPortKey = "needle.etpPort"

    public init() {
        let support = (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support"))
            .appendingPathComponent("Needle", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        store = IndexStore(
            databasePath: support.appendingPathComponent("index.sqlite").path,
            cancellation: cancellation
        )
    }

    public func start() async {
        let coordinator = self
        await store.setStatusHandler { status in
            Task { @MainActor in coordinator.status = status }
        }
        await store.start()
        await refresh()
        if httpServerEnabled && httpServer == nil {
            startHTTPServer(port: httpServerPort)
        }
        if etpServerEnabled && etpServer == nil {
            startETPServer(port: etpServerPort)
        }
    }

    public func refresh() async {
        roots = await store.currentRoots()
        spotlightEnabled = await store.isSpotlightEnabled()
        skipPackageContents = await store.isSkippingPackageContents()
        finderMetadataEnabled = await store.isFinderMetadataEnabled()
        excludedFolders = await store.excludedFolders()
        fileLists = await store.fileLists()
        journalEntries = await store.recentJournal()
        httpServerEnabled = await store.isHTTPServerEnabled()
        httpServerPort = await store.httpServerPort()
        let defaults = UserDefaults.standard
        etpServerEnabled = defaults.bool(forKey: Self.etpEnabledKey)
        let savedETPPort = defaults.integer(forKey: Self.etpPortKey)
        etpServerPort = savedETPPort > 0 && savedETPPort <= Int(UInt16.max)
            ? UInt16(savedETPPort) : 8_081
        networkScanConfiguration = await store.networkScanConfiguration()
        lastNetworkScanDate = await store.lastNetworkScanDate()
    }

    // MARK: - Actions

    public func rescan() async {
        infoMessage = nil
        await store.rescan()
    }

    public func cancelScan() {
        cancellation.cancel()
    }

    public func addRoot(path: String) async {
        errorMessage = await store.addRoot(path: path)
        if errorMessage == nil { await refresh() }
    }

    public func removeRoot(path: String) async {
        await store.removeRoot(path: path)
        await refresh()
    }

    public func addNetworkVolumes() async {
        let count = await store.addNetworkVolumes()
        if count > 0 {
            infoMessage = L("%d ağ birimi eklendi, indeks yenileniyor.", count)
            await refresh()
        } else {
            infoMessage = L("Yeni bağlanmış bir ağ birimi bulunamadı.")
        }
    }

    public func setSpotlight(_ enabled: Bool) async {
        await store.setSpotlight(enabled)
        spotlightEnabled = enabled
    }

    public func setSkipPackageContents(_ value: Bool) async {
        await store.setSkipPackageContents(value)
        skipPackageContents = value
    }

    public func setFinderMetadata(_ value: Bool) async {
        await store.setFinderMetadata(value)
        finderMetadataEnabled = value
    }

    public func setRootEnabled(path: String, enabled: Bool) async {
        await store.setRootEnabled(path: path, enabled: enabled)
        await refresh()
    }

    public func setRootExcludedPaths(path: String, paths: [String]) async {
        await store.setRootExcludedPaths(path: path, paths: paths)
        await refresh()
    }

    public func importEFU(name: String, text: String, baseURL: URL?) async -> String? {
        let items = FileList.parseEFU(text, baseURL: baseURL)
        guard !items.isEmpty else { return L("Dosya listesi boş veya geçersiz.") }
        let error = await store.importFileList(name: name, items: items)
        if error == nil {
            infoMessage = L("%d kayıtlık dosya listesi eklendi.", items.count)
        }
        await refresh()
        return error
    }

    public func removeFileList(id: String) async {
        await store.removeFileList(id: id)
        await refresh()
    }

    public func loadJournal(limit: Int = 100) async {
        journalEntries = await store.recentJournal(limit: limit)
    }

    public func clearJournal() async {
        await store.clearJournal()
        await loadJournal()
    }

    public func replaceTags(paths: [String], tags: [String]) async {
        guard !paths.isEmpty else { return }
        FileMetadata.setTags(tags, for: paths)
        await store.handleEvents(paths)
    }

    public func setTags(paths: [String], adding: [String], removing: [String]) async {
        guard !paths.isEmpty else { return }
        if !adding.isEmpty { FileMetadata.addTags(adding, to: paths) }
        if !removing.isEmpty { FileMetadata.removeTags(removing, from: paths) }
        await store.handleEvents(paths)
    }

    public func setComment(paths: [String], comment: String?) async {
        guard !paths.isEmpty else { return }
        FileMetadata.setComment(comment, for: paths)
        await store.handleEvents(paths)
    }

    public func setExcludedFolders(_ paths: [String]) async {
        await store.setExcludedFolders(paths)
        await refresh()
    }

    public func setNetworkScanConfiguration(_ configuration: NetworkScanConfiguration) async {
        await store.setNetworkScanConfiguration(configuration)
        networkScanConfiguration = configuration
    }

    public func rescanNetworkRoots() async {
        infoMessage = L("Ağ konumları taranıyor.")
        await store.rescanNetworkRoots()
        lastNetworkScanDate = await store.lastNetworkScanDate()
    }

    public func setHTTPServer(enabled: Bool, port: UInt16? = nil) async {
        let resolvedPort = port ?? httpServerPort
        await store.setHTTPServerSettings(enabled: enabled, port: resolvedPort)
        httpServerEnabled = enabled
        httpServerPort = resolvedPort
        if enabled {
            startHTTPServer(port: resolvedPort)
        } else {
            httpServer?.stop()
            httpServer = nil
            httpServerRunning = false
        }
    }

    private func startHTTPServer(port: UInt16) {
        httpServer?.stop()
        let server = SearchHTTPServer(port: port) { [store] query, limit in
            await store.search(QueryParser.parse(query), limit: limit)
        }
        do {
            try server.start()
            httpServer = server
            httpServerRunning = true
            errorMessage = nil
        } catch {
            httpServer = nil
            httpServerRunning = false
            errorMessage = error.localizedDescription
        }
    }

    /// ETP settings live in UserDefaults under `needle.*` keys; the HTTP server
    /// uses database metadata. Both servers are independent and loopback-only.
    public func setETPServer(enabled: Bool, port: UInt16? = nil) async {
        let resolvedPort = port ?? etpServerPort
        let defaults = UserDefaults.standard
        defaults.set(enabled, forKey: Self.etpEnabledKey)
        defaults.set(Int(resolvedPort), forKey: Self.etpPortKey)
        etpServerEnabled = enabled
        etpServerPort = resolvedPort
        if enabled {
            startETPServer(port: resolvedPort)
        } else {
            etpServer?.stop()
            etpServer = nil
            etpServerRunning = false
        }
    }

    private func startETPServer(port: UInt16) {
        etpServer?.stop()
        let server = SearchETPServer(port: port) { [store] query, limit in
            await store.search(QueryParser.parse(query), limit: limit)
        }
        do {
            try server.start()
            etpServer = server
            etpServerRunning = true
            errorMessage = nil
        } catch {
            etpServer = nil
            etpServerRunning = false
            errorMessage = error.localizedDescription
        }
    }

    public func search(_ query: ParsedQuery, limit: Int = 10_000) async -> [SearchResult] {
        await store.search(query, limit: limit)
    }

    public func showError(_ message: String?) {
        errorMessage = message
    }

    public func clearInfo() {
        infoMessage = nil
    }
}
