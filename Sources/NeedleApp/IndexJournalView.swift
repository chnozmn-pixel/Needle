import SwiftUI
import AppKit
import NeedleCore

struct IndexJournalView: View {
    @EnvironmentObject private var coordinator: IndexCoordinator
    @ObservedObject private var localization = LocalizationManager.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L("İndeks Günlüğü"))
                    .font(.title3.weight(.semibold))
                Spacer()
                Button(L("Temizle"), role: .destructive) {
                    Task { await coordinator.clearJournal() }
                }
                Button(L("Kapat")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }

            Text(L("Yalnızca artımlı değişiklikler, dosya listeleri ve kök işlemleri kaydedilir. Tam yeniden tarama tüm kayıtları günlüğe yazmaz."))
                .font(.caption)
                .foregroundStyle(.secondary)

            List {
                if coordinator.journalEntries.isEmpty {
                    Text(L("Henüz değişiklik yok")).foregroundStyle(.secondary)
                } else {
                    ForEach(coordinator.journalEntries) { entry in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Image(systemName: entry.action == "delete" ? "minus.circle" : "plus.circle")
                                .foregroundStyle(entry.action == "delete" ? .red : .green)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.path)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                                    .lineLimit(2)
                                    .truncationMode(.middle)
                                Text(entry.actionLabel)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(formatDate(entry.date))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            .listStyle(.inset)
            .frame(minHeight: 320)
        }
        .padding(20)
        .frame(width: 640, height: 460)
        .onAppear { Task { await coordinator.loadJournal() } }
    }
}
