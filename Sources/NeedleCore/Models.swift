import Foundation

// MARK: - Index entry

public struct IndexEntry: Sendable, Equatable, Identifiable {
    public let id: UInt64
    public let parentID: UInt64
    public let name: String
    public let path: String
    public let isDirectory: Bool
    public let size: Int64
    public let modifiedAt: Date?
    public let createdAt: Date?

    public var url: URL { URL(fileURLWithPath: path) }
    public var parentPath: String { (path as NSString).deletingLastPathComponent }

    public static func make(
        path: String,
        isDirectory: Bool,
        size: Int64,
        modifiedAt: Date?,
        createdAt: Date?
    ) -> IndexEntry {
        let clean = EntryID.normalize(path)
        return IndexEntry(
            id: EntryID.forPath(clean),
            parentID: EntryID.forPath((clean as NSString).deletingLastPathComponent),
            name: (clean as NSString).lastPathComponent,
            path: clean,
            isDirectory: isDirectory,
            size: size,
            modifiedAt: modifiedAt,
            createdAt: createdAt
        )
    }
}

// MARK: - Roots

public enum VolumeKind: String, Sendable {
    case local
    case network
    case unknown
}

public struct IndexRoot: Sendable, Equatable, Identifiable {
    public let path: String
    public let kind: VolumeKind

    public var id: String { path }
    public var displayName: String {
        let last = (path as NSString).lastPathComponent
        return last.isEmpty ? path : last
    }
}

// MARK: - Network scan scheduling

public enum NetworkScanSchedule: String, CaseIterable, Sendable, Identifiable {
    case daily
    case idle
    case every5Minutes
    case hourly

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .daily: return L("Günde bir")
        case .idle: return L("Bilgisayar boşta iken")
        case .every5Minutes: return L("Her 5 dakika")
        case .hourly: return L("Saatlik")
        }
    }
}

public struct NetworkScanConfiguration: Sendable, Equatable {
    public var schedule: NetworkScanSchedule
    public var hour: Int
    public var minute: Int
    /// Idle threshold in minutes, used when `schedule == .idle`.
    public var idleMinutes: Int

    public init(
        schedule: NetworkScanSchedule = .daily,
        hour: Int = 2,
        minute: Int = 0,
        idleMinutes: Int = 15
    ) {
        self.schedule = schedule
        self.hour = min(max(hour, 0), 23)
        self.minute = min(max(minute, 0), 59)
        self.idleMinutes = min(max(idleMinutes, 1), 240)
    }

    public var timeText: String { String(format: "%02d:%02d", hour, minute) }

    public var summary: String {
        switch schedule {
        case .daily: return L("Her gün %@", timeText)
        case .idle: return L("%d dk boşta iken, günde en fazla bir kez", idleMinutes)
        case .every5Minutes: return L("Her 5 dakika")
        case .hourly: return L("Saatte bir")
        }
    }
}

// MARK: - Status

public enum IndexPhase: String, Sendable {
    case idle
    case scanning
    case watching
    case refreshing
    case error
}

public struct IndexStatus: Sendable, Equatable {
    public var phase: IndexPhase = .idle
    public var scannedInPass: Int = 0
    public var totalEntries: Int = 0
    public var rootCount: Int = 0
    public var lastUpdate: Date?
    public var watchedPaths: Int = 0
    public var message: String?
    public var spotlightEnabled: Bool = false
    /// Incremented on every publish so the UI can refresh live results while
    /// the index is still being built.
    public var revision: Int = 0

    public var isBusy: Bool { phase == .scanning || phase == .refreshing }
}

// MARK: - Search

public enum ResultSource: String, Sendable {
    case index
    case spotlight
}

public struct SearchResult: Sendable, Equatable, Identifiable {
    public let entry: IndexEntry
    public let source: ResultSource

    public var id: UInt64 { entry.id }
}

// MARK: - Index changes

public enum IndexChange: Sendable {
    case upsert(IndexEntry)
    case delete(path: String)
}
