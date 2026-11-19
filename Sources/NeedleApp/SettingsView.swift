import SwiftUI
import AppKit
import NeedleCore

struct SettingsView: View {
    @EnvironmentObject private var coordinator: IndexCoordinator
    @EnvironmentObject private var preferences: Preferences
    @ObservedObject private var localization = LocalizationManager.shared
    @StateObject private var loginItems = LoginItemManager()
    @State private var httpPortText = "8080"
    @State private var etpPortText = "8081"
    @State private var isSettingsUnlocked = false

    private var needsUnlock: Bool {
        preferences.requireAuthForSettings && !isSettingsUnlocked
    }

    var body: some View {
        ZStack {
            TabView {
            generalTab
                .tabItem { Label(L("Genel"), systemImage: "gearshape") }
            rootsTab
                .tabItem { Label(L("Kökler"), systemImage: "folder") }
            searchTab
                .tabItem { Label(L("Arama"), systemImage: "magnifyingglass") }
            serversTab
                .tabItem { Label(L("Sunucular"), systemImage: "network") }
            historyTab
                .tabItem { Label(L("Geçmiş"), systemImage: "clock") }
            fileListsTab
                .tabItem { Label(L("Dosya Listeleri"), systemImage: "doc.text") }
            syntaxTab
                .tabItem { Label(L("Sözdizimi"), systemImage: "questionmark.circle") }
            }
            .disabled(needsUnlock)

            if needsUnlock {
                SettingsLockView { isSettingsUnlocked = true }
                    .background(.regularMaterial)
            }
        }
        .frame(minWidth: 640, idealWidth: 720, minHeight: 520, idealHeight: 640)
        .onDisappear { isSettingsUnlocked = false }
    }

    // MARK: - Roots

    private var rootsTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("İndekslenen konumlar"))
                .font(.headline)
            Text(L("Kendi indeksiniz bu klasörlerdeki tüm dosya ve klasörleri tarar. Ağ birimlerini eklemek için bağlı olduklarından emin olun."))
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(L("Bir kökü devre dışı bırakabilir veya yalnızca o kök için dışlama yolları ekleyebilirsiniz."))
                .font(.caption2)
                .foregroundStyle(.tertiary)

            List {
                Section(L("Kökler")) {
                    ForEach(coordinator.roots) { root in
                        HStack {
                            Image(systemName: root.kind == .network ? "network" : "folder.fill")
                                .foregroundStyle(root.kind == .network ? .purple : .blue)
                            VStack(alignment: .leading) {
                                Text(root.displayName)
                                Text(root.path)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if root.kind == .network {
                                Text(L("Ağ")).font(.caption2).foregroundStyle(.purple)
                            }
                            Toggle("", isOn: Binding(
                                get: { root.isEnabled },
                                set: { value in
                                    Task { await coordinator.setRootEnabled(path: root.path, enabled: value) }
                                }
                            ))
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                            .help(L("Kökü etkinleştir/devre dışı bırak"))
                            Menu {
                                if root.excludedPaths.isEmpty {
                                    Text(L("Köke özel dışlama yok")).foregroundStyle(.secondary)
                                } else {
                                    ForEach(root.excludedPaths, id: \.self) { path in
                                        Button(path) {
                                            var updated = root.excludedPaths
                                            updated.removeAll { $0 == path }
                                            Task {
                                                await coordinator.setRootExcludedPaths(
                                                    path: root.path, paths: updated
                                                )
                                            }
                                        }
                                    }
                                    Divider()
                                }
                                Button(L("Bu kök için dışlama ekle…")) {
                                    addExcludedFolders(for: root)
                                }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                            }
                            .buttonStyle(.borderless)
                            .help(L("Kök ayarları"))
                            Button {
                                Task { await coordinator.removeRoot(path: root.path) }
                            } label: {
                                Image(systemName: "trash").foregroundStyle(.red)
                            }
                            .buttonStyle(.borderless)
                            .help(L("Kökü kaldır"))
                        }
                        .padding(.vertical, 3)
                    }
                }

                Section(L("Dışlanan klasörler")) {
                    if coordinator.excludedFolders.isEmpty {
                        Text(L("Yok")).font(.caption).foregroundStyle(.secondary)
                    } else {
                        ForEach(coordinator.excludedFolders, id: \.self) { path in
                            HStack {
                                Image(systemName: "nosign").foregroundStyle(.orange)
                                Text(path).font(.caption).textSelection(.enabled)
                                Spacer()
                                Button {
                                    var updated = coordinator.excludedFolders
                                    updated.removeAll { $0 == path }
                                    Task { await coordinator.setExcludedFolders(updated) }
                                } label: {
                                    Image(systemName: "xmark.circle").foregroundStyle(.red)
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                }

                Section(L("Ağ taraması")) {
                    Picker(L("Zamanlama"), selection: Binding(
                        get: { coordinator.networkScanConfiguration.schedule },
                        set: { schedule in
                            var configuration = coordinator.networkScanConfiguration
                            configuration.schedule = schedule
                            Task { await coordinator.setNetworkScanConfiguration(configuration) }
                        }
                    )) {
                        ForEach(NetworkScanSchedule.allCases) { schedule in
                            Text(L(schedule.displayName)).tag(schedule)
                        }
                    }

                    if coordinator.networkScanConfiguration.schedule == .daily {
                        DatePicker(L("Saat"), selection: Binding(
                            get: { Self.scheduleDate(coordinator.networkScanConfiguration) },
                            set: { date in
                                var configuration = coordinator.networkScanConfiguration
                                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                                configuration.hour = parts.hour ?? configuration.hour
                                configuration.minute = parts.minute ?? configuration.minute
                                Task { await coordinator.setNetworkScanConfiguration(configuration) }
                            }
                        ), displayedComponents: .hourAndMinute)
                        .datePickerStyle(.compact)
                    }

                    if coordinator.networkScanConfiguration.schedule == .idle {
                        Stepper(value: Binding(
                            get: { coordinator.networkScanConfiguration.idleMinutes },
                            set: { value in
                                var configuration = coordinator.networkScanConfiguration
                                configuration.idleMinutes = value
                                Task { await coordinator.setNetworkScanConfiguration(configuration) }
                            }
                        ), in: 1...240) {
                            Text(L("Boşta kalma: %d dk", coordinator.networkScanConfiguration.idleMinutes))
                        }
                    }

                    Text(L(coordinator.networkScanConfiguration.summary))
                        .font(.caption)
                        .foregroundStyle(.purple)

                    if let last = coordinator.lastNetworkScanDate {
                        Text(L("Son ağ taraması: %@", last.formatted(date: .abbreviated, time: .shortened)))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Text(L("Ağ kökleri yalnızca bu zamanlamada taranır; yerel diskler FSEvents ile anlık izlenmeye devam eder."))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .listStyle(.inset)
            .frame(minHeight: 200)

            HStack {
                Button(L("Klasör Ekle…")) { addFolders() }
                Button(L("Dışla…")) { addExcludedFolders() }
                Button(L("Bağlı Ağ Birimlerini Ekle")) {
                    Task { await coordinator.addNetworkVolumes() }
                }
                Button(L("Ağ Konumlarını Tara")) {
                    Task { await coordinator.rescanNetworkRoots() }
                }
                Spacer()
                Button(L("Şimdi Yeniden Tara")) {
                    Task { await coordinator.rescan() }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .onAppear {
            Task { await coordinator.refresh() }
        }
    }

    // MARK: - General

    private var generalTab: some View {
        List {
            Section(L("Dil")) {
                Picker(L("Dil"), selection: Binding(
                    get: { localization.language },
                    set: { localization.language = $0 }
                )) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(L(language.displayName)).tag(language)
                    }
                }
                Text(L("Dil değişikliği anında uygulanır."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(L("Başlangıç")) {
                Toggle(L("Açılışta Needle'ı başlat"), isOn: Binding(
                    get: { loginItems.isEnabled },
                    set: { loginItems.setEnabled($0) }
                ))
                Text(L("Kayıt için uygulamanın imzalı olması gerekir; macOS ayrıca onay isteyebilir."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let error = loginItems.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Button(L("Açılış Öğelerini Aç")) { loginItems.openSystemSettings() }
                        .font(.caption)
                }
            }

            Section(L("Güvenlik")) {
                Toggle(L("Ayarları kimlik doğrulama ile koru"), isOn: $preferences.requireAuthForSettings)
                Text(L("Açıldığında Touch ID veya parola istenir."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(L("Görünüm")) {
                Picker(L("Tema"), selection: $preferences.theme) {
                    ForEach(AppTheme.allCases) { theme in
                        Text(L(theme.displayName)).tag(theme)
                    }
                }
                .pickerStyle(.segmented)

                Picker(L("Sonuç görünümü"), selection: $preferences.viewMode) {
                    ForEach(ResultViewMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                LabeledContent(L("Sonuç sınırı"), value: "\(preferences.resultLimit)")
                Slider(
                    value: Binding(
                        get: { Double(preferences.resultLimit) },
                        set: { preferences.resultLimit = Int($0) }
                    ),
                    in: 500...10_000,
                    step: 500
                )

                Text(L("Sütunlar kenar çubuğundaki Seçenekler menüsünden değiştirilebilir."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(L("Arama")) {
                Toggle(L("Spotlight sonuçlarıyla zenginleştir"), isOn: Binding(
                    get: { coordinator.spotlightEnabled },
                    set: { value in Task { await coordinator.setSpotlight(value) } }
                ))
                Text(L("Kendi indeksinizde olmayan veya ağ birimlerindeki dosyalar Spotlight üzerinden eklenir."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(L("İndeksleme")) {
                Toggle(L("Paket (.app, .bundle) içeriklerini atla"), isOn: Binding(
                    get: { coordinator.skipPackageContents },
                    set: { value in Task { await coordinator.setSkipPackageContents(value) } }
                ))
                Toggle(L("Finder etiketlerini ve yorumlarını indeksle"), isOn: Binding(
                    get: { coordinator.finderMetadataEnabled },
                    set: { value in Task { await coordinator.setFinderMetadata(value) } }
                ))
                Text(L("tag: ve comment: aramaları için gerekir; her dosyanın genişletilmiş özniteliklerini okur."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(L("Dışlanan klasörler de dahil tüm değişiklikler yeniden taramada uygulanır."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button(L("İndeksi Sıfırla ve Yeniden Tara")) {
                    Task { await coordinator.rescan() }
                }
            }

            Section(L("Kısayollar")) {
                LabeledContent(L("Pencereyi göster"), value: L("⌘ ⇧ Boşluk"))
                LabeledContent(L("Aramaya odaklan"), value: "⌘ F")
                LabeledContent(L("Gelişmiş arama"), value: "⌘ ⌥ F")
                LabeledContent(L("Aç"), value: "⏎")
                LabeledContent(L("Finder'da göster"), value: "⌘ ⏎")
                LabeledContent(L("Hızlı önizleme"), value: L("Boşluk"))
                LabeledContent(L("Yolları kopyala"), value: "⌘ ⇧ C")
                LabeledContent(L("Özellikler"), value: "⌘ I")
            }
        }
        .listStyle(.inset)
        .onAppear {
            httpPortText = String(coordinator.httpServerPort)
            etpPortText = String(coordinator.etpServerPort)
        }
    }

    // MARK: - Search defaults

    private var searchTab: some View {
        List {
            Section(L("Varsayılan eşleştirme")) {
                Toggle(L("Büyük/küçük harfe duyarlı"), isOn: $preferences.matchCase)
                Toggle(L("Tam kelime"), isOn: $preferences.wholeWords)
                Toggle(L("Yolda ara"), isOn: $preferences.matchPath)
                Toggle(L("Aksanlara duyarlı"), isOn: $preferences.matchDiacritics)
                Toggle(L("Noktalama ve boşlukları yok say"), isOn: $preferences.ignorePunctuation)
                Toggle(L("Joker karakterler"), isOn: $preferences.wildcardsEnabled)
                Toggle(L("Düzenli ifadeler"), isOn: $preferences.regexEnabled)
            }
            Text(L("Bu seçenekler aramaya Everything'in ?case:, ?whole-words:, ?path: gibi global değiştiricileri olarak eklenir."))
                .font(.caption)
                .foregroundStyle(.secondary)

            Section(L("Sütunlar")) {
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
        }
        .listStyle(.inset)
    }

    // MARK: - Servers

    private var serversTab: some View {
        List {
            Section(L("HTTP Sunucusu")) {
                    Toggle(L("Yerel HTTP arama sunucusunu etkinleştir"), isOn: Binding(
                        get: { coordinator.httpServerEnabled },
                        set: { enabled in
                            Task { await coordinator.setHTTPServer(enabled: enabled, port: UInt16(httpPortText)) }
                        }
                    ))
                    HStack {
                        TextField(L("Port"), text: $httpPortText)
                            .frame(width: 80)
                            .onSubmit { applyHTTPPort() }
                        Button(L("Uygula")) { applyHTTPPort() }
                        Spacer()
                        if coordinator.httpServerRunning {
                            Label(L("Çalışıyor"), systemImage: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.green)
                        } else {
                            Label(L("Durdu"), systemImage: "xmark.circle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(L("http://localhost:%@/?s=rapor  ·  JSON için &format=json", httpPortText))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                Section(L("ETP Sunucusu")) {
                    Toggle(L("Yerel ETP (Everything ağ protokolü) sunucusunu etkinleştir"), isOn: Binding(
                        get: { coordinator.etpServerEnabled },
                        set: { enabled in
                            Task { await coordinator.setETPServer(enabled: enabled, port: UInt16(etpPortText)) }
                        }
                    ))
                    HStack {
                        TextField(L("Port"), text: $etpPortText)
                            .frame(width: 80)
                            .onSubmit { applyETPPort() }
                        Button(L("Uygula")) { applyETPPort() }
                        Spacer()
                        if coordinator.etpServerRunning {
                            Label(L("Çalışıyor"), systemImage: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.green)
                        } else {
                            Label(L("Durdu"), systemImage: "xmark.circle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(L("Etkinleştirildiğinde 127.0.0.1:%@ adresinde düz metin ETP/FTP komutları dinlenir; veri kanalı ve dosya indirme yoktur.", etpPortText))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
        }
        .listStyle(.inset)
        .onAppear {
            httpPortText = String(coordinator.httpServerPort)
            etpPortText = String(coordinator.etpServerPort)
        }
    }

    // MARK: - History

    private var historyTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L("Arama geçmişi"))
                    .font(.headline)
                Spacer()
                Button(L("Temizle"), role: .destructive) { preferences.clearSearchHistory() }
            }
            List {
                if preferences.searchHistory.isEmpty {
                    Text(L("Yok")).foregroundStyle(.secondary)
                } else {
                    ForEach(preferences.searchHistory, id: \.self) { item in
                        Text(item).font(.system(.caption, design: .monospaced))
                    }
                }
            }
            .frame(height: 130)

            HStack {
                Text(L("Çalıştırma geçmişi"))
                    .font(.headline)
                Spacer()
                Button(L("Temizle"), role: .destructive) { preferences.clearRunHistory() }
            }
            List {
                if preferences.runHistory.isEmpty {
                    Text(L("Yok")).foregroundStyle(.secondary)
                } else {
                    ForEach(preferences.runHistory) { item in
                        VStack(alignment: .leading) {
                            Text((item.path as NSString).lastPathComponent)
                            Text(item.path)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .frame(minHeight: 140)
        }
        .padding(20)
    }

    // MARK: - Syntax

    private var syntaxTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(L("Arama sözdizimi")).font(.headline)
                Group {
                    SyntaxRow(query: L("rapor"), meaning: L("Adında 'rapor' geçenler"))
                    SyntaxRow(query: "\"\(L("yıllık rapor"))\"", meaning: L("Tam ifade"))
                    SyntaxRow(query: L("elma | armut"), meaning: L("VEYA"))
                    SyntaxRow(query: L("<elma armut> | muz"), meaning: L("Grup + VEYA"))
                    SyntaxRow(query: "!tmp", meaning: L("Hariç tut"))
                    SyntaxRow(query: "ext:pdf;docx", meaning: L("Uzantı listesi"))
                    SyntaxRow(query: "ext:!pdf", meaning: L("PDF olmayanlar"))
                    SyntaxRow(query: L("path:projeler"), meaning: L("Tam yolda geçen"))
                    SyntaxRow(query: L("parent:projeler"), meaning: L("Üst klasör eşleşmesi"))
                    SyntaxRow(query: "root:Users", meaning: L("Kök birim"))
                }
                Group {
                    SyntaxRow(query: "file  size:>10mb", meaning: L("Boyut filtresi"))
                    SyntaxRow(query: "folder  dm:today", meaning: L("Bugün değişen klasörler"))
                    SyntaxRow(query: "size:10mb..100mb", meaning: L("Boyut aralığı"))
                    SyntaxRow(query: "dc:>2024-06", meaning: L("Oluşturma tarihi"))
                    SyntaxRow(query: "*.jpg", meaning: L("Joker: tek klasör"))
                    SyntaxRow(query: "**.jpg", meaning: L("Joker: alt klasörlerle"))
                    SyntaxRow(query: "regex:^photo\\d+\\.jpg$", meaning: L("Düzenli ifade"))
                    SyntaxRow(query: L("case:RAPOR"), meaning: L("Büyük/küçük harfe duyarlı"))
                    SyntaxRow(query: L("wholewords:rapor"), meaning: L("Tam kelime"))
                    SyntaxRow(query: "content:needle", meaning: L("Dosya içeriğinde ara (PDF ve görsellerde OCR)"))
                    SyntaxRow(query: "tag:Önemli", meaning: L("Finder etiketi"))
                    SyntaxRow(query: "comment:taslak", meaning: L("Finder yorumu"))
                    SyntaxRow(query: "child:*.mp3", meaning: L("Eşleşen alt öğesi olan klasörler"))
                    SyntaxRow(query: "empty:", meaning: L("Boş klasörler"))
                }
                Group {
                    SyntaxRow(query: "dupe:size;content", meaning: L("Yinelenen dosyalar"))
                    SyntaxRow(query: "distinct:name", meaning: L("Tekil sonuçlar"))
                    SyntaxRow(query: "count:50", meaning: L("Sonuç sayısını sınırla"))
                    SyntaxRow(query: "sort:size-descending", meaning: L("Sıralama"))
                    SyntaxRow(query: "audio: image: video: zip:", meaning: L("Hazır dosya türü makroları"))
                    SyntaxRow(query: "C&sp:Program&sp:Files", meaning: L("Karakter varlıkları"))
                }
                Text(L("Boşluk VE, | VEYA, ! DEĞİL anlamına gelir. Varsayılan olarak VEYA, VE'den önce değerlendirilir; ?and-precedence: ile değiştirilebilir."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
    }

    // MARK: - File lists and journal

    private var fileListsTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("EFU dosya listeleri"))
                .font(.headline)
            Text(L("Everything uyumlu EFU listeleri çevrimdışı medyayı, yedekleri veya geçici olarak bağlı olmayan konumları indekse ekler. Listeler yeniden taramada korunur."))
                .font(.caption)
                .foregroundStyle(.secondary)

            List {
                Section(L("İçe Aktarılan Listeler")) {
                    if coordinator.fileLists.isEmpty {
                        Text(L("Henüz dosya listesi eklenmedi"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(coordinator.fileLists) { list in
                            HStack {
                                Image(systemName: "doc.text").foregroundStyle(.purple)
                                VStack(alignment: .leading) {
                                    Text(list.name)
                                    Text(L("%d kayıt · %@", list.count, formatDate(list.importedAt)))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button {
                                    Task { await coordinator.removeFileList(id: list.identifier) }
                                } label: {
                                    Image(systemName: "trash").foregroundStyle(.red)
                                }
                                .buttonStyle(.borderless)
                                .help(L("Listeyi kaldır"))
                            }
                        }
                    }
                }

                Section(L("Son Değişiklikler")) {
                    if coordinator.journalEntries.isEmpty {
                        Text(L("Henüz değişiklik yok"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(coordinator.journalEntries.prefix(40)) { entry in
                            HStack {
                                Image(systemName: entry.action == "delete" ? "minus.circle" : "plus.circle")
                                    .foregroundStyle(entry.action == "delete" ? .red : .green)
                                VStack(alignment: .leading) {
                                    Text(entry.path).font(.caption).lineLimit(1).truncationMode(.middle)
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
            }
            .listStyle(.inset)
            .frame(minHeight: 200)

            HStack {
                Button(L("EFU Dosya Listesi Ekle…")) { importEFU() }
                Spacer()
                Button(L("Günlüğü Temizle"), role: .destructive) {
                    Task { await coordinator.clearJournal() }
                }
            }
        }
        .padding(20)
        .onAppear {
            Task {
                await coordinator.refresh()
                await coordinator.loadJournal()
            }
        }
    }

    // MARK: - Helpers

    private static func scheduleDate(_ configuration: NetworkScanConfiguration) -> Date {
        var components = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        components.hour = configuration.hour
        components.minute = configuration.minute
        components.second = 0
        return Calendar.current.date(from: components) ?? Date()
    }

    private func applyHTTPPort() {
        guard let port = UInt16(httpPortText), port > 0 else {
            httpPortText = String(coordinator.httpServerPort)
            return
        }
        Task { await coordinator.setHTTPServer(enabled: coordinator.httpServerEnabled, port: port) }
    }

    private func applyETPPort() {
        guard let port = UInt16(etpPortText), port > 0 else {
            etpPortText = String(coordinator.etpServerPort)
            return
        }
        Task { await coordinator.setETPServer(enabled: coordinator.etpServerEnabled, port: port) }
    }

    private func addFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.begin { response in
            guard response == .OK else { return }
            let paths = panel.urls.map(\.path)
            Task { @MainActor in
                for path in paths { await coordinator.addRoot(path: path) }
            }
        }
    }

    private func addExcludedFolders(for root: IndexRoot) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.begin { response in
            guard response == .OK else { return }
            var updated = root.excludedPaths
            for path in panel.urls.map(\.path) where !updated.contains(path) {
                updated.append(path)
            }
            Task { @MainActor in
                await coordinator.setRootExcludedPaths(path: root.path, paths: updated)
            }
        }
    }

    private func importEFU() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.prompt = L("Ekle")
        panel.message = L("EFU dosya listesini seçin")
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let text = try? String(contentsOf: url, encoding: .utf8)
            Task { @MainActor in
                guard let text else {
                    coordinator.showError(L("Dosya listesi okunamadı."))
                    return
                }
                if let error = await coordinator.importEFU(
                    name: url.lastPathComponent,
                    text: text,
                    baseURL: url.deletingLastPathComponent()
                ) {
                    coordinator.showError(error)
                }
            }
        }
    }

    private func addExcludedFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.begin { response in
            guard response == .OK else { return }
            var updated = coordinator.excludedFolders
            for path in panel.urls.map(\.path) where !updated.contains(path) {
                updated.append(path)
            }
            Task { @MainActor in
                await coordinator.setExcludedFolders(updated)
            }
        }
    }
}

private struct SyntaxRow: View {
    let query: String
    let meaning: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(query)
                .font(.system(.body, design: .monospaced))
                .frame(width: 250, alignment: .leading)
            Text(meaning)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }
}
