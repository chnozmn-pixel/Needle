import SwiftUI
import AppKit
import QuickLookThumbnailing
import NeedleCore

// MARK: - View mode

enum ResultViewMode: String, CaseIterable, Identifiable {
    case list
    case grid

    var id: String { rawValue }

    var title: String {
        switch self {
        case .list: return L("Liste Görünümü")
        case .grid: return L("Izgara Görünümü")
        }
    }

    var systemImage: String {
        switch self {
        case .list: return "list.bullet"
        case .grid: return "square.grid.2x2"
        }
    }

    static var thumbnailsTitle: String { L("Küçük Resimler") }
}

// MARK: - Thumbnail cache

/// Thread-safe path-keyed image cache. A failed lookup is cached as an empty
/// entry so the same file is not handed to Quick Look repeatedly.
private final class ThumbnailCache {
    static let shared = ThumbnailCache()

    private let lock = NSLock()
    private var images: [String: NSImage] = [:]
    private var attemptedPaths: Set<String> = []

    func cachedImage(forPath path: String) -> NSImage? {
        lock.lock()
        defer { lock.unlock() }
        return images[path]
    }

    func hasAttempted(_ path: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return attemptedPaths.contains(path)
    }

    func store(_ image: NSImage?, forPath path: String) {
        lock.lock()
        defer { lock.unlock() }
        attemptedPaths.insert(path)
        if let image {
            images[path] = image
        } else {
            images[path] = nil
        }
    }
}

// MARK: - Gallery

struct ResultGalleryView: View {
    @ObservedObject private var localization = LocalizationManager.shared

    let results: [SearchResult]
    let terms: [String]
    @Binding var selection: Set<SearchResult.ID>
    let onOpen: (SearchResult) -> Void
    let onPreview: (SearchResult) -> Void
    let onProperties: (SearchResult) -> Void

    init(
        results: [SearchResult],
        terms: [String],
        selection: Binding<Set<SearchResult.ID>>,
        onOpen: @escaping (SearchResult) -> Void,
        onPreview: @escaping (SearchResult) -> Void,
        onProperties: @escaping (SearchResult) -> Void
    ) {
        self.results = results
        self.terms = terms
        self._selection = selection
        self.onOpen = onOpen
        self.onPreview = onPreview
        self.onProperties = onProperties
    }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 150), spacing: 12)]
    }

    var body: some View {
        Group {
            if results.isEmpty {
                emptyView
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(results) { result in
                            GalleryResultCell(
                                result: result,
                                terms: terms,
                                isSelected: selection.contains(result.id),
                                onToggle: toggle,
                                onOpen: onOpen,
                                onPreview: onPreview,
                                onProperties: onProperties
                            )
                        }
                    }
                    .padding(12)
                }
                .accessibilityLabel("\(ResultViewMode.thumbnailsTitle) · \(ResultViewMode.grid.title)")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyView: some View {
        VStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 34))
                .foregroundStyle(.tertiary)
            Text(L("Sonuç yok"))
                .font(.title3.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityLabel(L("Sonuç yok"))
    }

    private func toggle(_ result: SearchResult) {
        if selection.contains(result.id) {
            selection.remove(result.id)
        } else {
            selection.insert(result.id)
        }
    }
}

// MARK: - Cell

private struct GalleryResultCell: View {
    let result: SearchResult
    let terms: [String]
    let isSelected: Bool
    let onToggle: (SearchResult) -> Void
    let onOpen: (SearchResult) -> Void
    let onPreview: (SearchResult) -> Void
    let onProperties: (SearchResult) -> Void

    @State private var thumbnail: NSImage?
    @State private var loadGeneration = 0
    @State private var pendingSelection: DispatchWorkItem?

    private var fallbackSymbol: String {
        result.entry.isDirectory ? "folder.fill" : "doc.text.fill"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(NSColor.controlBackgroundColor))

                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .scaledToFit()
                        .padding(6)
                } else {
                    Image(systemName: fallbackSymbol)
                        .font(.system(size: 38))
                        .foregroundStyle(result.entry.isDirectory ? Color.blue : Color.secondary)
                }
            }
            .frame(height: 92)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            highlightedText(result.entry.name, terms: terms)
                .font(.caption.weight(.semibold))
                .lineLimit(2)
                .truncationMode(.middle)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 4) {
                Text(result.entry.isDirectory ? "—" : formatBytes(result.entry.size))
                Text("·")
                Text(formatDate(result.entry.modifiedAt))
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isSelected ? Color.accentColor.opacity(0.18) : Color(NSColor.controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(
                    isSelected ? Color.accentColor : Color.secondary.opacity(0.18),
                    lineWidth: isSelected ? 2 : 1
                )
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { openImmediately() }
        .onTapGesture { scheduleToggle() }
        .contextMenu { contextMenuContent }
        .onAppear { loadThumbnail() }
        .onChange(of: result.id) { _ in prepareForReuse() }
        .onDisappear { pendingSelection?.cancel() }
        .help("\(ResultViewMode.thumbnailsTitle) — \(result.entry.path)")
    }

    @ViewBuilder
    private var contextMenuContent: some View {
        Button(L("Aç")) { onOpen(result) }
        Button(L("Hızlı Önizleme")) { onPreview(result) }
        Button(L("Özellikler…")) { onProperties(result) }
        Divider()
        Button(L("Adı Kopyala")) { copyToPasteboard(result.entry.name) }
        Button(L("Yolu Kopyala")) { copyToPasteboard(result.entry.path) }
    }

    private func scheduleToggle() {
        pendingSelection?.cancel()
        let work = DispatchWorkItem { [self] in
            pendingSelection = nil
            onToggle(result)
        }
        pendingSelection = work
        let delay = max(NSEvent.doubleClickInterval, 0.2)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func openImmediately() {
        pendingSelection?.cancel()
        pendingSelection = nil
        onOpen(result)
    }

    private func prepareForReuse() {
        pendingSelection?.cancel()
        pendingSelection = nil
        thumbnail = nil
        loadThumbnail()
    }

    private func loadThumbnail() {
        loadGeneration += 1
        let generation = loadGeneration
        let path = result.entry.path

        if ThumbnailCache.shared.hasAttempted(path) {
            thumbnail = ThumbnailCache.shared.cachedImage(forPath: path)
            return
        }

        let side: CGFloat = 160
        let request = QLThumbnailGenerator.Request(
            fileAt: result.entry.url,
            size: CGSize(width: side, height: side),
            scale: NSScreen.main?.backingScaleFactor ?? 2,
            representationTypes: [.thumbnail, .lowQualityThumbnail, .icon]
        )

        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
            let image = representation?.nsImage
            ThumbnailCache.shared.store(image, forPath: path)
            DispatchQueue.main.async {
                guard generation == self.loadGeneration else { return }
                self.thumbnail = image
            }
        }
    }

    private func copyToPasteboard(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}
