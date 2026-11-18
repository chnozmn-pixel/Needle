import SwiftUI
import AppKit
import QuickLookUI
import Carbon
import NeedleCore

// MARK: - Formatting

func formatBytes(_ bytes: Int64) -> String {
    if bytes < 1024 { return "\(bytes) B" }
    let formatter = ByteCountFormatter()
    formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
    formatter.countStyle = .file
    formatter.includesUnit = true
    formatter.isAdaptive = true
    return formatter.string(fromByteCount: bytes)
}

func formatDate(_ date: Date?) -> String {
    guard let date else { return "—" }
    let formatter = DateFormatter()
    formatter.locale = LocalizationManager.shared.locale
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    return formatter.string(from: date)
}

func formatCount(_ count: Int) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.locale = LocalizationManager.shared.locale
    return formatter.string(from: NSNumber(value: count)) ?? "\(count)"
}

// MARK: - Highlighting

func highlightedText(_ text: String, terms: [String]) -> Text {
    var attributed = AttributedString(text)
    let lower = text.lowercased()

    for term in terms where !term.isEmpty {
        var start = lower.startIndex
        while let range = lower.range(of: term, range: start..<lower.endIndex) {
            guard let lowerIndex = AttributedString.Index(range.lowerBound, within: attributed),
                  let upperIndex = AttributedString.Index(range.upperBound, within: attributed) else {
                break
            }
            attributed[lowerIndex..<upperIndex].foregroundColor = .accentColor
            attributed[lowerIndex..<upperIndex].font = .body.bold()
            start = range.upperBound
            if start == lower.endIndex { break }
        }
    }
    return Text(attributed)
}

// MARK: - Quick Look

private final class PreviewItem: NSObject, QLPreviewItem {
    let url: URL
    init(url: URL) { self.url = url }
    var previewItemURL: URL? { url }
    var previewItemTitle: String? { url.lastPathComponent }
}

private final class QuickLookController: NSObject, QLPreviewPanelDataSource {
    static let shared = QuickLookController()
    private var item: PreviewItem?

    func show(_ url: URL) {
        item = PreviewItem(url: url)
        let panel = QLPreviewPanel.shared()
        panel?.dataSource = self
        panel?.reloadData()
        if panel?.isVisible == false { panel?.makeKeyAndOrderFront(nil) }
    }

    func close() {
        guard QLPreviewPanel.shared()?.isVisible == true else { return }
        QLPreviewPanel.shared()?.close()
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { item == nil ? 0 : 1 }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! { item }
}

struct QuickLookBridge: NSViewRepresentable {
    @Binding var url: URL?

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let url { QuickLookController.shared.show(url) }
        else { QuickLookController.shared.close() }
    }
}

// MARK: - Global hotkey (Cmd + Shift + Space)

private var hotKeyHandler: (() -> Void)?

final class HotKeyManager {
    static let shared = HotKeyManager()
    private var hotKeyRef: EventHotKeyRef?
    private var installed = false

    func register(action: @escaping () -> Void) {
        hotKeyHandler = action
        guard !installed else { return }
        installed = true

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, _ in
                hotKeyHandler?()
                return noErr
            },
            1,
            &eventType,
            nil,
            nil
        )

        let hotKeyID = EventHotKeyID(signature: OSType(0x45564c31), id: 1) // 'NDL1'
        RegisterEventHotKey(
            UInt32(kVK_Space),
            UInt32(cmdKey | shiftKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
    }
}
