import SwiftUI
import AppKit
import NeedleCore

extension Notification.Name {
    static let needleOpenSelected = Notification.Name("needle.openSelected")
    static let needleRevealSelected = Notification.Name("needle.revealSelected")
    static let needlePreviewSelected = Notification.Name("needle.previewSelected")
    static let needleFocusSearch = Notification.Name("needle.focusSearch")
    static let needleShowWindow = Notification.Name("needle.showWindow")
    static let needleCopyPaths = Notification.Name("needle.copyPaths")
    static let needleCopyNames = Notification.Name("needle.copyNames")
    static let needleProperties = Notification.Name("needle.properties")
    static let needleAdvancedSearch = Notification.Name("needle.advancedSearch")
    static let needleExportCSV = Notification.Name("needle.exportCSV")
    static let needleExportTXT = Notification.Name("needle.exportTXT")
}

@main
struct NeedleApp: App {
    @StateObject private var coordinator = IndexCoordinator()
    @StateObject private var preferences = Preferences()
    @ObservedObject private var localization = LocalizationManager.shared

    var body: some Scene {
        WindowGroup {
            MainWindow()
                .environmentObject(coordinator)
                .environmentObject(preferences)
                .preferredColorScheme(preferences.theme.colorScheme)
                .frame(minWidth: 1_000, minHeight: 620)
        }
        .windowStyle(.automatic)
        .commands {
            CommandMenu(L("İşlemler")) {
                Button(L("Aç")) {
                    NotificationCenter.default.post(name: .needleOpenSelected, object: nil)
                }
                .keyboardShortcut(.return, modifiers: [])
                Button(L("Finder'da Göster")) {
                    NotificationCenter.default.post(name: .needleRevealSelected, object: nil)
                }
                .keyboardShortcut(.return, modifiers: .command)
                Button(L("Hızlı Önizleme")) {
                    NotificationCenter.default.post(name: .needlePreviewSelected, object: nil)
                }
                .keyboardShortcut(.space, modifiers: [])
                Divider()
                Button(L("Yolları Kopyala")) {
                    NotificationCenter.default.post(name: .needleCopyPaths, object: nil)
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                Button(L("Adları Kopyala")) {
                    NotificationCenter.default.post(name: .needleCopyNames, object: nil)
                }
            }

            CommandMenu(L("Özellikler")) {
                Button(L("Seçili Öğenin Özellikleri…")) {
                    NotificationCenter.default.post(name: .needleProperties, object: nil)
                }
                .keyboardShortcut("i", modifiers: .command)
            }

            CommandMenu(L("Arama")) {
                Button(L("Gelişmiş Arama…")) {
                    NotificationCenter.default.post(name: .needleAdvancedSearch, object: nil)
                }
                .keyboardShortcut("f", modifiers: [.command, .option])
                Button(L("Araya Odaklan")) {
                    NotificationCenter.default.post(name: .needleFocusSearch, object: nil)
                }
                .keyboardShortcut("f", modifiers: .command)
                Divider()
                Button(L("CSV Olarak Dışa Aktar…")) {
                    NotificationCenter.default.post(name: .needleExportCSV, object: nil)
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                Button(L("Metin Olarak Dışa Aktar…")) {
                    NotificationCenter.default.post(name: .needleExportTXT, object: nil)
                }
            }

            CommandMenu(L("Ayarlar")) {
                Button(L("Ayarlar…")) {
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                }
                .keyboardShortcut(",", modifiers: .command)
                Divider()
                Button(L("Gelişmiş Arama…")) {
                    NotificationCenter.default.post(name: .needleAdvancedSearch, object: nil)
                }
                .keyboardShortcut("f", modifiers: [.command, .option])
            }

            CommandGroup(replacing: .newItem) {
                Button(L("Yeni Tarama")) {
                    Task { await coordinator.rescan() }
                }
                .keyboardShortcut("r", modifiers: .command)
            }
        }

        MenuBarExtra("Needle", systemImage: "magnifyingglass") {
            Button(L("Pencereyi Aç")) {
                NotificationCenter.default.post(name: .needleShowWindow, object: nil)
                NSApp.activate(ignoringOtherApps: true)
            }
            Divider()
            Button(L("Gelişmiş Arama…")) {
                NotificationCenter.default.post(name: .needleAdvancedSearch, object: nil)
            }
            Button(L("Ayarlar…")) {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }
            Divider()
            Button(L("Çık")) { NSApp.terminate(nil) }
                .keyboardShortcut("q", modifiers: .command)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView()
                .environmentObject(coordinator)
                .environmentObject(preferences)
        }
    }
}
