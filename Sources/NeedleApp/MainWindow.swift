import SwiftUI
import AppKit
import NeedleCore

struct MainWindow: View {
    @EnvironmentObject private var coordinator: IndexCoordinator
    @EnvironmentObject private var preferences: Preferences
    @ObservedObject private var localization = LocalizationManager.shared

    @State private var query = ""
    @State private var results: [SearchResult] = []
    @State private var displayedResults: [SearchResult] = []
    @State private var selection: Set<SearchResult.ID> = []
    @State private var sortField: SortField = .name
    @State private var sortAscending = true
    @State private var searchTask: Task<Void, Never>?
    @State private var quickLookURL: URL?
    @State private var keyMonitor: Any?
    @State private var showSidebar = true
    @State private var showAdvanced = false
    @State private var propertiesResult: SearchResult?
    @State private var selectedRootPath: String?
    @FocusState private var searchFocused: Bool

    private var effectiveQuery: String {
        [preferences.queryPrefix, query]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private var parsed: ParsedQuery { QueryParser.parse(effectiveQuery) }

    private var selectedResults: [SearchResult] {
        displayedResults.filter { selection.contains($0.id) }
    }

    private var rootFilteredResults: [SearchResult] {
        guard let selectedRootPath else { return results }
        return results.filter {
            $0.entry.path == selectedRootPath || $0.entry.path.hasPrefix(selectedRootPath + "/")
        }
    }

    private var activeSort: (SortField, Bool) {
        if let specification = parsed.sortSpecifications.first {
            let field = Self.mapSortField(specification.field) ?? sortField
            return (field, !specification.descending)
        }
        return (sortField, sortAscending)
    }

    var body: some View {
        HSplitView {
            if showSidebar { sidebar }
            mainPane
        }
        .background(QuickLookBridge(url: $quickLookURL))
        .sheet(isPresented: $showAdvanced) {
            AdvancedSearchView(query: $query)
        }
        .sheet(item: $propertiesResult) { result in
            PropertiesView(result: result)
        }
        .onAppear {
            searchFocused = true
            HotKeyManager.shared.register { showWindow() }
            installKeyMonitor()
            scheduleSearch()
        }
        .task {
            await coordinator.start()
        }
        .onChange(of: query) { _ in scheduleSearch() }
        .onChange(of: coordinator.status.revision) { _ in scheduleSearch() }
        .onChange(of: coordinator.spotlightEnabled) { _ in scheduleSearch() }
        .onChange(of: sortField) { _ in recomputeDisplayed() }
        .onChange(of: sortAscending) { _ in recomputeDisplayed() }
        .onChange(of: selectedRootPath) { _ in recomputeDisplayed() }
        .onChange(of: preferences.visibleColumns) { _ in recomputeDisplayed() }
        .onDisappear {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .needleOpenSelected)) { _ in openSelected() }
        .onReceive(NotificationCenter.default.publisher(for: .needleRevealSelected)) { _ in revealSelected() }
        .onReceive(NotificationCenter.default.publisher(for: .needlePreviewSelected)) { _ in previewSelected() }
        .onReceive(NotificationCenter.default.publisher(for: .needleCopyPaths)) { _ in copySelectedPaths() }
        .onReceive(NotificationCenter.default.publisher(for: .needleCopyNames)) { _ in copySelectedNames() }
        .onReceive(NotificationCenter.default.publisher(for: .needleProperties)) { _ in showProperties() }
        .onReceive(NotificationCenter.default.publisher(for: .needleAdvancedSearch)) { _ in showAdvanced = true }
        .onReceive(NotificationCenter.default.publisher(for: .needleExportCSV)) { _ in export(.csv) }
        .onReceive(NotificationCenter.default.publisher(for: .needleExportTXT)) { _ in export(.txt) }
        .onReceive(NotificationCenter.default.publisher(for: .needleFocusSearch)) { _ in searchFocused = true }
        .onReceive(NotificationCenter.default.publisher(for: .needleShowWindow)) { _ in showWindow() }
        .alert(
            L("Hata"),
            isPresented: Binding(
                get: { coordinator.errorMessage != nil },
                set: { if !$0 { coordinator.showError(nil) } }
            )
        ) {
            Button(L("Tamam"), role: .cancel) {}
        } message: {
            Text(coordinator.errorMessage ?? "")
        }
    }

    // MARK: - Sections

    private var mainPane: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()
            toolbar
            resultHeader
            ResultTable(
                results: displayedResults,
                terms: parsed.nameTerms,
                selection: $selection,
                sortField: $sortField,
                sortAscending: $sortAscending,
                visibleColumns: $preferences.visibleColumns,
                onOpen: open,
                onReveal: reveal,
                onPreview: preview,
                onProperties: { propertiesResult = $0 }
            )
            statusBar
        }
        .frame(minWidth: 720)
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Button {
                showSidebar.toggle()
            } label: {
                Image(systemName: "sidebar.left")
            }
            .buttonStyle(.borderless)
            .help(L("Kenar çubuğunu göster/gizle"))

            Image(systemName: "magnifyingglass")
                .font(.title2)
                .foregroundStyle(.secondary)

            TextField(L("Dosya veya klasör adı…  (örn. ext:pdf path:projeler)"), text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 18))
                .focused($searchFocused)
                .onSubmit { preferences.rememberSearch(query) }

            if !query.isEmpty {
                Button {
                    query = ""
                    searchFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help(L("Aramayı temizle"))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button {
                chooseFolders()
            } label: {
                Label(L("Klasör Ekle"), systemImage: "folder.badge.plus")
            }
            Button {
                Task { await coordinator.addNetworkVolumes() }
            } label: {
                Label(L("Ağ"), systemImage: "network")
            }

            if coordinator.status.isBusy {
                Button {
                    coordinator.cancelScan()
                } label: {
                    Label(L("İptal"), systemImage: "stop.circle")
                }
                .foregroundStyle(.red)
            } else {
                Button {
                    Task { await coordinator.rescan() }
                } label: {
                    Label(L("Yeniden Tara"), systemImage: "arrow.triangle.2.circlepath")
                }
                .keyboardShortcut("r", modifiers: .command)
            }

            Divider().frame(height: 18)

            historyMenu
            savedSearchMenu

            Button {
                showAdvanced = true
            } label: {
                Label(L("Gelişmiş"), systemImage: "slider.horizontal.3")
            }
            .help(L("Gelişmiş arama (⌘⌥F)"))

            Menu {
                Button(L("CSV…")) { export(.csv) }
                Button(L("Metin…")) { export(.txt) }
                Divider()
                Button(L("Yolları Kopyala")) { copySelectedPaths() }
                Button(L("Adları Kopyala")) { copySelectedNames() }
                Button(L("Özellikler…")) { showProperties() }
            } label: {
                Label(L("Dışa Aktar"), systemImage: "square.and.arrow.up")
            }

            optionsMenu

            Button {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            } label: {
                Label(L("Ayarlar"), systemImage: "gearshape")
            }
            .help(L("Ayarlar (⌘,)"))

            Spacer(minLength: 4)

            if !parsed.filterSummary.isEmpty {
                Text(parsed.filterSummary)
                    .font(.caption)
                    .foregroundStyle(.purple)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.purple.opacity(0.1), in: Capsule())
                    .lineLimit(1)
            }

            Toggle(L("Spotlight"), isOn: Binding(
                get: { coordinator.spotlightEnabled },
                set: { value in Task { await coordinator.setSpotlight(value) } }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .help(L("Kendi indeksine ek olarak Spotlight sonuçlarını da göster"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.bar)
    }

    private var historyMenu: some View {
        Menu {
            if preferences.searchHistory.isEmpty {
                Text(L("Henüz arama yok")).foregroundStyle(.secondary)
            } else {
                ForEach(preferences.searchHistory.prefix(12), id: \.self) { item in
                    Button(item) {
                        query = item
                        preferences.rememberSearch(item)
                    }
                }
                Divider()
                Button(L("Geçmişi Temizle"), role: .destructive) {
                    preferences.clearSearchHistory()
                }
            }
        } label: {
            Label(L("Geçmiş"), systemImage: "clock.arrow.circlepath")
        }
        .help(L("Son aramalar"))
    }

    private var savedSearchMenu: some View {
        Menu {
            Button(L("Geçerli Aramayı Kaydet…")) { saveCurrentSearch() }
            Divider()
            if preferences.savedSearches.isEmpty {
                Text(L("Kayıtlı arama yok")).foregroundStyle(.secondary)
            } else {
                ForEach(preferences.savedSearches) { item in
                    Button(item.name) {
                        query = item.query
                        preferences.rememberSearch(item.query)
                    }
                }
            }
        } label: {
            Label(L("Kayıtlı"), systemImage: "bookmark")
        }
        .help(L("Kayıtlı aramalar"))
    }

    private var optionsMenu: some View {
        Menu {
            Toggle(L("Büyük/küçük harfe duyarlı"), isOn: $preferences.matchCase)
            Toggle(L("Tam kelime"), isOn: $preferences.wholeWords)
            Toggle(L("Yolda ara"), isOn: $preferences.matchPath)
            Toggle(L("Aksanlara duyarlı"), isOn: $preferences.matchDiacritics)
            Toggle(L("Noktalama yok say"), isOn: $preferences.ignorePunctuation)
            Toggle(L("Joker karakterler"), isOn: $preferences.wildcardsEnabled)
            Toggle(L("Düzenli ifade"), isOn: $preferences.regexEnabled)
            Divider()
            Menu(L("Sütunlar")) {
                ForEach(SortField.allCases, id: \.self) { field in
                    Toggle(field.title, isOn: Binding(
                        get: { preferences.visibleColumns.contains(field.rawValue) },
                        set: { enabled in
                            if enabled { preferences.visibleColumns.insert(field.rawValue) }
                            else { preferences.visibleColumns.remove(field.rawValue) }
                        }
                    ))
                }
            }
        } label: {
            Label(L("Seçenekler"), systemImage: "checkmark.circle")
        }
        .help(L("Arama seçenekleri ve sütunlar"))
    }

    private var sidebar: some View {
        List {
            Section(L("Kökler")) {
                Button {
                    selectedRootPath = nil
                } label: {
                    Label(L("Tüm konumlar"), systemImage: "circle.grid.3x3")
                        .foregroundStyle(selectedRootPath == nil ? Color.accentColor : Color.primary)
                }
                .buttonStyle(.plain)

                ForEach(coordinator.roots) { root in
                    Button {
                        selectedRootPath = root.path
                    } label: {
                        HStack {
                            Image(systemName: root.kind == .network ? "network" : "folder.fill")
                            Text(root.displayName)
                            Spacer()
                        }
                        .foregroundStyle(selectedRootPath == root.path ? Color.accentColor : Color.primary)
                    }
                    .buttonStyle(.plain)
                    .help(root.path)
                }
            }

            Section(L("Kayıtlı Aramalar")) {
                if preferences.savedSearches.isEmpty {
                    Text(L("Yok")).font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(preferences.savedSearches) { item in
                        Button {
                            query = item.query
                            preferences.rememberSearch(item.query)
                        } label: {
                            Label(item.name, systemImage: "bookmark.fill")
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Section(L("Son Aramalar")) {
                if preferences.searchHistory.isEmpty {
                    Text(L("Yok")).font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(preferences.searchHistory.prefix(8), id: \.self) { item in
                        Button {
                            query = item
                        } label: {
                            Label(item, systemImage: "clock")
                                .lineLimit(1)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Section(L("Çalıştırılanlar")) {
                if preferences.runHistory.isEmpty {
                    Text(L("Yok")).font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(preferences.runHistory.prefix(8)) { item in
                        Button {
                            openPath(item.path, query: item.query)
                        } label: {
                            Label((item.path as NSString).lastPathComponent, systemImage: "arrow.up.forward.app")
                                .lineLimit(1)
                        }
                        .buttonStyle(.plain)
                        .help(item.path)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 190, idealWidth: 230, maxWidth: 300)
    }

    private var resultHeader: some View {
        HStack {
            Text(L("%@ sonuç", formatCount(displayedResults.count)))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if results.count >= preferences.resultLimit {
                Text(L("· ilk %@ gösteriliyor", formatCount(preferences.resultLimit)))
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Spacer()
            Text(L("Çift tık: aç · ⏎: aç · ⌘⏎: Finder · Boşluk: önizle · ⌘⇧C: yol"))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            if coordinator.status.isBusy {
                ProgressView().controlSize(.small)
                Text(L("Taranıyor: %@ kayıt", formatCount(coordinator.status.scannedInPass)))
                    .font(.caption)
            } else {
                Image(systemName: coordinator.status.phase == .error ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(coordinator.status.phase == .error ? .orange : .green)
                Text(L("%@ kayıt · %d kök", formatCount(coordinator.status.totalEntries), coordinator.status.rootCount))
                    .font(.caption)
            }

            if let message = coordinator.status.message {
                Text(L("· %@", message)).font(.caption).foregroundStyle(.secondary)
            }

            optionBadge("A", enabled: preferences.matchCase, help: L("Büyük/küçük harfe duyarlı"))
            optionBadge("W", enabled: preferences.wholeWords, help: L("Tam kelime"))
            optionBadge("P", enabled: preferences.matchPath, help: L("Yolda ara"))
            optionBadge("R", enabled: preferences.regexEnabled, help: L("Düzenli ifade"))

            Spacer()

            if coordinator.status.watchedPaths > 0 {
                Label(L("Canlı izleme"), systemImage: "bolt.fill")
                    .font(.caption)
                    .foregroundStyle(.yellow)
            }
            if coordinator.status.spotlightEnabled {
                Label(L("Spotlight"), systemImage: "sparkles")
                    .font(.caption)
                    .foregroundStyle(.purple)
            }
            if let last = coordinator.status.lastUpdate {
                Text(L("Son: %@", formatDate(last)))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private func optionBadge(_ title: String, enabled: Bool, help: String) -> some View {
        Group {
            if enabled {
                Text(title)
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.accentColor.opacity(0.18), in: Capsule())
                    .help(help)
            }
        }
    }

    // MARK: - Search

    private func recomputeDisplayed() {
        let sort = activeSort
        displayedResults = sortedResults(rootFilteredResults, by: sort.0, ascending: sort.1)
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 60_000_000)
            guard !Task.isCancelled else { return }
            let found = await coordinator.search(parsed, limit: preferences.resultLimit)
            guard !Task.isCancelled else { return }
            results = found
            recomputeDisplayed()
        }
    }

    private static func mapSortField(_ raw: String) -> SortField? {
        switch raw.lowercased().replacingOccurrences(of: "-", with: "") {
        case "name", "filename", "stem": return .name
        case "path", "fullpath", "parent", "location": return .path
        case "size": return .size
        case "ext", "extension", "kind", "type": return .kind
        case "dm", "datemodified", "modified", "date": return .modified
        case "dc", "datecreated", "created": return .created
        default: return nil
        }
    }

    // MARK: - Actions

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags
            if flags.contains(.command), flags.contains(.shift), event.keyCode == 8 {
                copySelectedPaths()
                return nil
            }
            if flags.contains(.command), event.keyCode == 34 {
                showProperties()
                return nil
            }
            if event.keyCode == 36 && flags.contains(.command) {
                revealSelected()
                return nil
            }
            if searchFocused { return event }
            if event.keyCode == 36 {
                openSelected()
                return nil
            }
            if event.keyCode == 49 {
                previewSelected()
                return nil
            }
            return event
        }
    }

    private func open(_ result: SearchResult) {
        preferences.recordRun(path: result.entry.path, query: query)
        NSWorkspace.shared.open(result.entry.url)
    }

    private func openPath(_ path: String, query: String) {
        preferences.recordRun(path: path, query: query)
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    private func reveal(_ result: SearchResult) {
        preferences.recordRun(path: result.entry.path, query: query)
        NSWorkspace.shared.activateFileViewerSelecting([result.entry.url])
    }

    private func preview(_ result: SearchResult) {
        quickLookURL = result.entry.url
    }

    private func openSelected() {
        guard let result = selectedResults.first else { return }
        open(result)
    }

    private func revealSelected() {
        guard let result = selectedResults.first else { return }
        reveal(result)
    }

    private func previewSelected() {
        guard let result = selectedResults.first else { return }
        preview(result)
    }

    private func showProperties() {
        guard let result = selectedResults.first else { return }
        propertiesResult = result
    }

    private func copySelectedPaths() {
        guard !selectedResults.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(selectedResults.map(\.entry.path).joined(separator: "\n"), forType: .string)
    }

    private func copySelectedNames() {
        guard !selectedResults.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(selectedResults.map(\.entry.name).joined(separator: "\n"), forType: .string)
    }

    private func saveCurrentSearch() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let name = promptForText(
            title: L("Aramayı Kaydet"),
            message: L("Bu aramaya bir ad verin:"),
            defaultValue: trimmed
        )?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let name, !name.isEmpty else { return }
        preferences.addSavedSearch(name: name, query: trimmed)
    }

    private enum ExportFormat: String {
        case csv
        case txt
    }

    private func export(_ format: ExportFormat) {
        let items = displayedResults
        let name = query.isEmpty ? "needle-results" : "needle-\(query.prefix(24).replacingOccurrences(of: " ", with: "-"))"
        guard let url = savePanel(
            title: L("Sonuçları Dışa Aktar"),
            defaultName: name,
            allowedExtensions: [format.rawValue]
        ) else { return }

        let content: String
        switch format {
        case .csv:
            var lines = [L("Ad,Yol,Tür,Boyut,Değiştirildi,Oluşturuldu,Kaynak")]
            for item in items {
                let e = item.entry
                let row = [
                    e.name, e.path, e.isDirectory ? L("Klasör") : e.pathExtension,
                    e.isDirectory ? "" : String(e.size),
                    e.modifiedAt.map { formatDate($0) } ?? "",
                    e.createdAt.map { formatDate($0) } ?? "",
                    item.source.rawValue
                ]
                lines.append(row.map { Self.csvEscape($0) }.joined(separator: ","))
            }
            content = lines.joined(separator: "\n") + "\n"
        case .txt:
            content = items.map(\.entry.path).joined(separator: "\n") + "\n"
        }
        try? content.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func csvEscape(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
        return escaped.contains(",") || escaped.contains("\"") || escaped.contains("\n")
            ? "\"\(escaped)\"" : escaped
    }

    private func showWindow() {
        if let window = NSApp.windows.first(where: { $0.contentView?.subviews.isEmpty == false }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
        searchFocused = true
    }

    private func chooseFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = L("Ekle")
        panel.message = L("İndekslenecek klasörleri seçin")
        panel.begin { response in
            guard response == .OK else { return }
            let paths = panel.urls.map(\.path)
            Task { @MainActor in
                for path in paths { await coordinator.addRoot(path: path) }
            }
        }
    }
}

private extension IndexEntry {
    var pathExtension: String { (name as NSString).pathExtension.uppercased() }
}
