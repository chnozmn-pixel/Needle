import SwiftUI
import AppKit
import NeedleCore

enum SortField: String, CaseIterable {
    case name = "name"
    case path = "path"
    case size = "size"
    case kind = "kind"
    case modified = "modified"
    case created = "created"

    var title: String {
        switch self {
        case .name: return L("Ad")
        case .path: return L("Yol")
        case .size: return L("Boyut")
        case .kind: return L("Tür")
        case .modified: return L("Değiştirildi")
        case .created: return L("Oluşturuldu")
        }
    }

    var width: CGFloat {
        switch self {
        case .name: return 280
        case .path: return 340
        case .size: return 100
        case .kind: return 90
        case .modified: return 150
        case .created: return 150
        }
    }
}

extension SearchResult {
    var modifiedSortKey: Date { entry.modifiedAt ?? .distantPast }
    var createdSortKey: Date { entry.createdAt ?? .distantPast }
    var sizeSortKey: Int64 { entry.isDirectory ? -1 : entry.size }
    var kindSortKey: String { entry.isDirectory ? "folder" : (entry.name as NSString).pathExtension.lowercased() }
}

func sortedResults(_ items: [SearchResult], by field: SortField, ascending: Bool) -> [SearchResult] {
    func stringSorted(_ key: (SearchResult) -> String) -> [SearchResult] {
        let keyed = items.map { ($0, key($0).lowercased()) }
        return keyed.sorted { ascending ? $0.1 < $1.1 : $0.1 > $1.1 }.map(\.0)
    }

    switch field {
    case .name: return stringSorted { $0.entry.name }
    case .path: return stringSorted { $0.entry.path }
    case .size:
        return items.sorted { ascending ? $0.sizeSortKey < $1.sizeSortKey : $0.sizeSortKey > $1.sizeSortKey }
    case .kind:
        return items.sorted { ascending ? $0.kindSortKey < $1.kindSortKey : $0.kindSortKey > $1.kindSortKey }
    case .modified:
        return items.sorted { ascending ? $0.modifiedSortKey < $1.modifiedSortKey : $0.modifiedSortKey > $1.modifiedSortKey }
    case .created:
        return items.sorted { ascending ? $0.createdSortKey < $1.createdSortKey : $0.createdSortKey > $1.createdSortKey }
    }
}

struct SortHeader: View {
    let field: SortField
    let active: SortField
    let ascending: Bool
    let action: (SortField) -> Void

    var body: some View {
        Button { action(field) } label: {
            HStack(spacing: 4) {
                Text(field.title)
                if active == field {
                    Image(systemName: ascending ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .frame(width: field.width)
        .foregroundStyle(active == field ? Color.primary : Color.secondary)
    }
}

struct ResultTable: View {
    @ObservedObject private var localization = LocalizationManager.shared
    let results: [SearchResult]
    let terms: [String]
    @Binding var selection: Set<SearchResult.ID>
    @Binding var sortField: SortField
    @Binding var sortAscending: Bool
    @Binding var visibleColumns: Set<String>
    let onOpen: (SearchResult) -> Void
    let onReveal: (SearchResult) -> Void
    let onPreview: (SearchResult) -> Void
    let onProperties: (SearchResult) -> Void

    private var visibleFields: [SortField] {
        SortField.allCases.filter { visibleColumns.contains($0.rawValue) }
    }

    private func columnWidth(_ field: SortField) -> CGFloat {
        visibleColumns.contains(field.rawValue) ? field.width : 0
    }

    private var selectedResults: [SearchResult] {
        results.filter { selection.contains($0.id) }
    }

    private var singleSelection: SearchResult? {
        selectedResults.count == 1 ? selectedResults[0] : nil
    }

    private func toggleSort(_ field: SortField) {
        if sortField == field {
            sortAscending.toggle()
        } else {
            sortField = field
            sortAscending = true
        }
    }

    private func copyPaths(_ items: [SearchResult]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(items.map(\.entry.path).joined(separator: "\n"), forType: .string)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(visibleFields, id: \.self) { field in
                    SortHeader(
                        field: field,
                        active: sortField,
                        ascending: sortAscending,
                        action: toggleSort
                    )
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(.bar)

            Table(results, selection: $selection) {
                TableColumn("") { result in
                    HStack(spacing: 6) {
                        Image(systemName: result.entry.isDirectory ? "folder.fill" : "doc")
                            .foregroundStyle(result.entry.isDirectory ? .blue : .secondary)
                        highlightedText(result.entry.name, terms: terms)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if result.source == .spotlight {
                            Image(systemName: "sparkles")
                                .font(.caption2)
                                .foregroundStyle(.purple)
                                .help(L("Spotlight sonucu"))
                        }
                    }
                    .onTapGesture(count: 2) { onOpen(result) }
                }
                .width(columnWidth(.name))

                TableColumn("") { result in
                    Text(result.entry.path)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(result.entry.path)
                }
                .width(columnWidth(.path))

                TableColumn("") { result in
                    Text(result.entry.isDirectory ? "—" : formatBytes(result.entry.size))
                        .monospacedDigit()
                        .foregroundStyle(result.entry.isDirectory ? .tertiary : .primary)
                }
                .width(columnWidth(.size))

                TableColumn("") { result in
                    Text(result.kindSortKey.isEmpty ? L("Dosya") : result.kindSortKey.uppercased())
                        .foregroundStyle(.secondary)
                }
                .width(columnWidth(.kind))

                TableColumn("") { result in
                    Text(formatDate(result.entry.modifiedAt))
                        .foregroundStyle(.secondary)
                }
                .width(columnWidth(.modified))

                TableColumn("") { result in
                    Text(formatDate(result.entry.createdAt))
                        .foregroundStyle(.secondary)
                }
                .width(columnWidth(.created))
            }
            .tableStyle(.automatic)
        }
        .contextMenu {
            if let result = singleSelection {
                Button(L("Aç")) { onOpen(result) }
                Button(L("Finder'da Göster")) { onReveal(result) }
                Button(L("Hızlı Önizleme")) { onPreview(result) }
                Divider()
                Button(L("Özellikler…")) { onProperties(result) }
                Divider()
                Button(L("Adı Kopyala")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(result.entry.name, forType: .string)
                }
                Button(L("Yolu Kopyala")) { copyPaths([result]) }
            }
            if !selectedResults.isEmpty {
                Button(L("Seçili %d yolu kopyala", selectedResults.count)) { copyPaths(selectedResults) }
            }
        }
    }
}
