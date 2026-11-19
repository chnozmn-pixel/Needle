import AppIntents
import AppKit

/// Opens Needle and runs a search, so App Shortcuts and Shortcuts automations
/// can hand a query to the app without scripting its UI.
struct SearchNeedleIntent: AppIntent {
    static var title: LocalizedStringResource = "Search Needle"
    static var description = IntentDescription("Opens Needle and runs a search.")
    static var openAppWhenRun = true

    @Parameter(title: "Query")
    var query: String

    init() {}

    init(query: String) {
        self.query = query
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        if let url = URL(string: "needle://search?q=\(encoded)") {
            NSWorkspace.shared.open(url)
        }
        return .result()
    }
}

struct NeedleShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SearchNeedleIntent(),
            phrases: [
                "Search \(\.$query) in \(.applicationName)",
                "Search \(.applicationName) for \(\.$query)",
            ],
            shortTitle: "Search Needle",
            systemImageName: "magnifyingglass"
        )
    }
}
