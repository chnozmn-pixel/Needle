import SwiftUI
import NeedleCore

struct AdvancedSearchView: View {
    @ObservedObject private var localization = LocalizationManager.shared
    @Environment(\.dismiss) private var dismiss
    @Binding var query: String

    @State private var name = ""
    @State private var path = ""
    @State private var extensionText = ""
    @State private var content = ""
    @State private var minSize = ""
    @State private var maxSize = ""
    @State private var files = true
    @State private var folders = true
    @State private var useModified = false
    @State private var modifiedFrom = Date()
    @State private var modifiedTo = Date()
    @State private var useCreated = false
    @State private var createdFrom = Date()
    @State private var createdTo = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("Gelişmiş Arama"))
                .font(.title2.weight(.semibold))

            Form {
                Section(L("Ad ve konum")) {
                    TextField(L("Dosya adı"), text: $name)
                    TextField(L("Yol içerir"), text: $path)
                    TextField(L("Uzantı (örn. pdf;docx)"), text: $extensionText)
                    TextField(L("İçerik içerir"), text: $content)
                }

                Section(L("Tür")) {
                    Toggle(L("Dosyalar"), isOn: $files)
                    Toggle(L("Klasörler"), isOn: $folders)
                }

                Section(L("Boyut")) {
                    TextField(L("En küçük (örn. 10mb)"), text: $minSize)
                    TextField(L("En büyük (örn. 100mb)"), text: $maxSize)
                }

                Section(L("Tarih")) {
                    Toggle(L("Değiştirilme tarihi"), isOn: $useModified)
                    if useModified {
                        DatePicker(L("Başlangıç"), selection: $modifiedFrom, displayedComponents: .date)
                        DatePicker(L("Bitiş"), selection: $modifiedTo, displayedComponents: .date)
                    }
                    Toggle(L("Oluşturma tarihi"), isOn: $useCreated)
                    if useCreated {
                        DatePicker(L("Başlangıç"), selection: $createdFrom, displayedComponents: .date)
                        DatePicker(L("Bitiş"), selection: $createdTo, displayedComponents: .date)
                    }
                }
            }
            .formStyle(.grouped)
            .frame(height: 380)

            HStack {
                Button(L("Sıfırla")) { reset() }
                Spacer()
                Button(L("İptal")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(L("Ara")) { apply() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private func apply() {
        var parts: [String] = []
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedPath = path.trimmingCharacters(in: .whitespaces)
        let trimmedExt = extensionText.trimmingCharacters(in: .whitespaces)
        let trimmedContent = content.trimmingCharacters(in: .whitespaces)

        if !trimmedName.isEmpty { parts.append(trimmedName) }
        if !trimmedPath.isEmpty { parts.append("path:\(quoted(trimmedPath))") }
        if !trimmedExt.isEmpty { parts.append("ext:\(trimmedExt)") }
        if !trimmedContent.isEmpty { parts.append("content:\(quoted(trimmedContent))") }

        if files != folders {
            parts.append(files ? "file" : "folder")
        }

        let min = minSize.trimmingCharacters(in: .whitespaces)
        let max = maxSize.trimmingCharacters(in: .whitespaces)
        if !min.isEmpty && !max.isEmpty {
            parts.append("size:\(min)..\(max)")
        } else if !min.isEmpty {
            parts.append("size:>\(min)")
        } else if !max.isEmpty {
            parts.append("size:<\(max)")
        }

        if useModified {
            parts.append("dm:\(dateToken(from: modifiedFrom))..\(dateToken(from: modifiedTo))")
        }
        if useCreated {
            parts.append("dc:\(dateToken(from: createdFrom))..\(dateToken(from: createdTo))")
        }

        query = parts.joined(separator: " ")
        dismiss()
    }

    private func quoted(_ value: String) -> String {
        value.contains(" ") ? "\"\(value)\"" : value
    }

    private func dateToken(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private func reset() {
        name = ""
        path = ""
        extensionText = ""
        content = ""
        minSize = ""
        maxSize = ""
        files = true
        folders = true
        useModified = false
        useCreated = false
    }
}
