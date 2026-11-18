import SwiftUI
import AppKit
import NeedleCore

struct PropertiesView: View {
    @EnvironmentObject private var coordinator: IndexCoordinator
    @ObservedObject private var localization = LocalizationManager.shared
    let result: SearchResult
    @Environment(\.dismiss) private var dismiss
    @State private var tagsText = ""
    @State private var commentText = ""

    private var attributes: [FileAttributeKey: Any]? {
        try? FileManager.default.attributesOfItem(atPath: result.entry.path)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: result.entry.isDirectory ? "folder.fill" : "doc.fill")
                    .font(.title)
                    .foregroundStyle(result.entry.isDirectory ? .blue : .secondary)
                VStack(alignment: .leading) {
                    Text(result.entry.name)
                        .font(.title3.weight(.semibold))
                    Text(result.source == .spotlight ? L("Spotlight sonucu") : L("Yerel indeks"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 10) {
                row(L("Tam yol"), result.entry.path)
                row(L("Üst klasör"), result.entry.parentPath)
                row(L("Tür"), result.entry.isDirectory ? L("Klasör") : (result.entry.name as NSString).pathExtension.uppercased())
                row(L("Boyut"), result.entry.isDirectory ? "—" : formatBytes(result.entry.size))
                row(L("Değiştirildi"), formatDate(result.entry.modifiedAt))
                row(L("Oluşturuldu"), formatDate(result.entry.createdAt))
                row(L("İzinler"), permissionText)
                row(L("Kimlik"), String(format: "%016llx", result.entry.id))
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text(L("Finder Etiketleri"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextField(L("Etiketleri virgülle ayırın"), text: $tagsText)
                    .textFieldStyle(.roundedBorder)
                Text(L("Finder Yorumu"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextField(L("Yorum ekleyin…"), text: $commentText)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button(L("Kaydet")) {
                        let tags = tagsText
                            .components(separatedBy: ",")
                            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                            .filter { !$0.isEmpty }
                        Task {
                            await coordinator.replaceTags(paths: [result.entry.path], tags: tags)
                            await coordinator.setComment(
                                paths: [result.entry.path],
                                comment: commentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                    ? nil : commentText
                            )
                        }
                    }
                    .disabled(result.source == .spotlight)
                    Text(L("Yalnızca yerel dosyalarda düzenlenebilir."))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 8)

            HStack {
                Button(L("Yolu Kopyala")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(result.entry.path, forType: .string)
                }
                Spacer()
                Button(L("Kapat")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 560, height: 540)
        .onAppear {
            tagsText = FileMetadata.readTags(at: result.entry.path).joined(separator: ", ")
            commentText = FileMetadata.readComment(at: result.entry.path) ?? ""
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 100, alignment: .leading)
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
        }
    }

    private var permissionText: String {
        guard let number = attributes?[.posixPermissions] as? NSNumber else { return "—" }
        return String(format: "%o", number.int16Value)
    }
}
