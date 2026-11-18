import AppKit
import UniformTypeIdentifiers
import NeedleCore

func promptForText(title: String, message: String, defaultValue: String = "") -> String? {
    let alert = NSAlert()
    alert.alertStyle = .informational
    alert.messageText = title
    alert.informativeText = message
    alert.addButton(withTitle: L("Tamam"))
    alert.addButton(withTitle: L("İptal"))

    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
    field.stringValue = defaultValue
    alert.accessoryView = field

    guard alert.runModal() == .alertFirstButtonReturn else { return nil }
    return field.stringValue
}

func savePanel(title: String, defaultName: String, allowedExtensions: [String]) -> URL? {
    let panel = NSSavePanel()
    panel.title = title
    panel.nameFieldStringValue = defaultName
    panel.allowedContentTypes = allowedExtensions.compactMap { UTType(filenameExtension: $0) }
    panel.canCreateDirectories = true
    return panel.runModal() == .OK ? panel.url : nil
}
