import SwiftUI
import UniformTypeIdentifiers

enum UtilitySegment: String, CaseIterable, Identifiable {
    case alerts = "Alerts"
    case importExport = "Import / Export"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .alerts: return "bell.badge"
        case .importExport: return "arrow.triangle.2.circlepath.icloud"
        }
    }
}

struct UtilitiesView: View {
    @ObservedObject private var storageService = StorageService.shared
    @ObservedObject private var syncService = iCloudSyncService.shared
    @ObservedObject private var stockService = StockService.shared

    @State private var selectedSegment: UtilitySegment = .alerts
    @State private var showAddAlertSheet = false
    @State private var editingAlert: PriceAlert? = nil

    // Import / Export states
    @State private var showFileImporter = false
    @State private var showFundImporter = false
    @State private var showWatchlistImporter = false
    @State private var pendingImportResult: PortfolioIO.ImportResult? = nil
    @State private var alertBannerMessage: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            pickerBar
            Divider()
            contentBody
        }
        .background(DS.ground)
        .sheet(isPresented: $showAddAlertSheet) {
            AddAlertSheet(isPresented: $showAddAlertSheet)
                .environmentObject(storageService)
                .environmentObject(stockService)
        }
        .sheet(item: $editingAlert) { alert in
            AlertEditView(symbol: alert.symbol) {
                editingAlert = nil
            }
            .environmentObject(storageService)
            .environmentObject(stockService)
        }
        .sheet(item: $pendingImportResult) { res in
            ImportPreviewSheet(
                items: res.items,
                suggestedPortfolioName: res.suggestedPortfolioName,
                isFundImport: res.isFundImport,
                onDismiss: {
                    pendingImportResult = nil
                }
            )
            .environmentObject(storageService)
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.json, .commaSeparatedText, UTType(filenameExtension: "xlsx") ?? .data],
            allowsMultipleSelection: false
        ) { result in
            handleGenericFileImport(result: result)
        }
        .fileImporter(
            isPresented: $showFundImporter,
            allowedContentTypes: [.commaSeparatedText, .plainText, UTType(filenameExtension: "xlsx") ?? .data],
            allowsMultipleSelection: false
        ) { result in
            handleFundFileImport(result: result)
        }
        .fileImporter(
            isPresented: $showWatchlistImporter,
            allowedContentTypes: [.commaSeparatedText, .plainText, UTType(filenameExtension: "xlsx") ?? .data],
            allowsMultipleSelection: false
        ) { result in
            handleWatchlistFileImport(result: result)
        }
        .alert(
            "Notification",
            isPresented: Binding(get: { alertBannerMessage != nil }, set: { if !$0 { alertBannerMessage = nil } })
        ) {
            Button("OK", role: .cancel) { alertBannerMessage = nil }
        } message: {
            Text(alertBannerMessage ?? "")
        }
    }

    private var pickerBar: some View {
        Picker("Utilities Segment", selection: $selectedSegment) {
            Text("🔔 Alerts").tag(UtilitySegment.alerts)
            Text("☁️ Import / Export").tag(UtilitySegment.importExport)
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var contentBody: some View {
        if selectedSegment == .alerts {
            alertsSection
        } else {
            importExportSection
        }
    }

    // MARK: - 1. ALERTS SUB-TAB

    private var alertsSection: some View {
        ScrollView {
            VStack(spacing: 12) {
                // Header Bar with count and + Add Alert
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Price Alerts")
                            .font(.inter(15, weight: .bold, relativeTo: .headline))
                            .foregroundColor(DS.ink)
                        Text("\(storageService.alerts.count) active or triggered alerts")
                            .font(.inter(11, relativeTo: .caption))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button {
                        showAddAlertSheet = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "plus.circle.fill")
                            Text("Add Alert")
                        }
                        .font(.inter(12, weight: .semibold, relativeTo: .subheadline))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)

                if storageService.alerts.isEmpty {
                    emptyAlertsView
                } else {
                    LazyVStack(spacing: 8) {
                        ForEach(storageService.alerts) { alert in
                            alertCard(alert)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 24)
                }
            }
        }
    }

    private var emptyAlertsView: some View {
        VStack(spacing: 12) {
            Image(systemName: "bell.slash.fill")
                .font(.system(size: 36))
                .foregroundColor(.secondary.opacity(0.5))
                .padding(.top, 40)
            Text("No Price Alerts")
                .font(.inter(14, weight: .semibold, relativeTo: .headline))
                .foregroundColor(DS.ink)
            Text("Get notified when a stock reaches your target price, crosses moving averages, or moves by a percentage.")
                .font(.inter(11, relativeTo: .caption))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button {
                showAddAlertSheet = true
            } label: {
                Label("Create First Alert", systemImage: "plus")
                    .font(.inter(12, weight: .semibold, relativeTo: .subheadline))
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 8)
            .padding(.bottom, 40)
        }
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 14).fill(DS.card))
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private func alertCard(_ alert: PriceAlert) -> some View {
        let quote = stockService.quotes[alert.symbol]
        let currSym = StorageService.currencySymbol(for: quote?.currency ?? storageService.preferredCurrency)
        let isTriggered = alert.lastTriggeredAt != nil

        return HStack(spacing: 12) {
            SymbolLogo(symbol: alert.symbol, size: 36)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(StockService.beautifiedSymbol(alert.symbol))
                        .font(.inter(13, weight: .bold, relativeTo: .body))
                        .foregroundColor(DS.ink)
                    if isTriggered {
                        Text("Triggered")
                            .font(.inter(9, weight: .bold, relativeTo: .caption2))
                            .foregroundColor(.orange)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.orange.opacity(0.15)))
                    } else if alert.isEnabled {
                        Text("Active")
                            .font(.inter(9, weight: .semibold, relativeTo: .caption2))
                            .foregroundColor(.green)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.green.opacity(0.15)))
                    } else {
                        Text("Disabled")
                            .font(.inter(9, weight: .semibold, relativeTo: .caption2))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.secondary.opacity(0.15)))
                    }
                }

                Text(AlertEvaluator.describe(alert, currencySymbol: currSym))
                    .font(.inter(11, relativeTo: .caption))
                    .foregroundColor(.secondary)

                if let q = quote {
                    Text("Current: \(currSym)\(StorageService.formatNumber(q.effectivePrice, decimals: 2))")
                        .font(.inter(10, weight: .medium, relativeTo: .caption2))
                        .foregroundColor(DS.inkSecondary)
                }
            }

            Spacer()

            // Delete button
            Button(role: .destructive) {
                withAnimation {
                    storageService.removeAlerts(ids: [alert.id])
                }
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.borderless)
            .padding(.trailing, 4)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(DS.card))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(DS.hairline, lineWidth: 0.5))
    }

    // MARK: - 2. IMPORT / EXPORT SUB-TAB

    private var importExportSection: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Card 1: iCloud Sync & Cloud Transfer
                iCloudSyncCard

                // Card 2: File Import & Export
                fileActionsCard

                // Card 3: Specialized Imports & Samples
                templatesCard
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }

    private var iCloudSyncCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "icloud.fill")
                    .foregroundColor(DS.brand)
                    .font(.system(size: 18))
                Text("iCloud Sync")
                    .font(.inter(14, weight: .bold, relativeTo: .headline))
                    .foregroundColor(DS.ink)
                Spacer()
                Toggle("", isOn: $storageService.iCloudSyncEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .onChange(of: storageService.iCloudSyncEnabled) {
                        syncService.onSyncToggleChanged(enabled: storageService.iCloudSyncEnabled)
                    }
            }

            Text("Automatically synchronizes portfolios, watchlists, alerts, and notes across all your Macs, iPhones, and iPads via iCloud.")
                .font(.inter(11, relativeTo: .caption))
                .foregroundColor(.secondary)

            if storageService.iCloudSyncEnabled {
                Divider()

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(syncService.syncStatus.contains("Fail") ? Color.red : Color.green)
                                .frame(width: 7, height: 7)
                            Text(syncService.syncStatus)
                                .font(.inter(11, weight: .semibold, relativeTo: .subheadline))
                        }
                        if let lastDate = syncService.lastSyncDate {
                            Text("Last sync: \(lastDate.formatted(date: .abbreviated, time: .shortened))")
                                .font(.inter(10, relativeTo: .caption))
                                .foregroundColor(.secondary)
                        }
                    }
                    Spacer()
                    Button(syncService.isSyncing ? "Syncing…" : "Sync Now") {
                        syncService.pullAndMerge(force: true)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(syncService.isSyncing)
                }

                HStack(spacing: 10) {
                    Button {
                        syncService.pushLocalData()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.up.icloud")
                            Text("Push to iCloud")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button {
                        syncService.pullAndMerge(force: true)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.down.icloud")
                            Text("Pull from iCloud")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(DS.card))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(DS.hairline, lineWidth: 0.5))
    }

    private var fileActionsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "folder.badge.gearshape")
                    .foregroundColor(DS.brand)
                    .font(.system(size: 16))
                Text("Backup & Files (iCloud Drive)")
                    .font(.inter(14, weight: .bold, relativeTo: .headline))
                    .foregroundColor(DS.ink)
            }

            Text("Import or export your full portfolio and watchlist data via JSON or Spreadsheet files.")
                .font(.inter(11, relativeTo: .caption))
                .foregroundColor(.secondary)

            Divider()

            VStack(spacing: 8) {
                Button {
                    showFileImporter = true
                } label: {
                    HStack {
                        Image(systemName: "square.and.arrow.down")
                            .foregroundColor(DS.brand)
                        Text("Import from File / iCloud Drive")
                            .font(.inter(12, weight: .medium, relativeTo: .body))
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
                }
                .buttonStyle(.plain)

                Button {
                    exportAppDataBackup()
                } label: {
                    HStack {
                        Image(systemName: "square.and.arrow.up")
                            .foregroundColor(DS.brand)
                        Text("Export Full App Backup (JSON)")
                            .font(.inter(12, weight: .medium, relativeTo: .body))
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(DS.card))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(DS.hairline, lineWidth: 0.5))
    }

    private var templatesCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "doc.text.badge.plus")
                    .foregroundColor(DS.brand)
                    .font(.system(size: 16))
                Text("Specific Imports")
                    .font(.inter(14, weight: .bold, relativeTo: .headline))
                    .foregroundColor(DS.ink)
            }

            VStack(spacing: 8) {
                Button {
                    showFundImporter = true
                } label: {
                    HStack {
                        Text("🇯🇵")
                        Text("Import Japanese Mutual Funds (CSV)")
                            .font(.inter(12, weight: .medium, relativeTo: .body))
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
                }
                .buttonStyle(.plain)

                Button {
                    showWatchlistImporter = true
                } label: {
                    HStack {
                        Image(systemName: "list.bullet.rectangle")
                            .foregroundColor(DS.brand)
                        Text("Import Watchlist (CSV/XLSX)")
                            .font(.inter(12, weight: .medium, relativeTo: .body))
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(DS.card))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(DS.hairline, lineWidth: 0.5))
    }

    // MARK: - FILE IMPORT / EXPORT HANDLERS

    private func handleGenericFileImport(result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        guard url.startAccessingSecurityScopedResource() else { return }
        defer { url.stopAccessingSecurityScopedResource() }

        // Check if it's a full AppData JSON backup or a Portfolio file
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(StorageService.AppData.self, from: data) {
            let local = storageService.exportAppData()
            let merged = syncService.smartMerge(local: local, remote: decoded)
            storageService.applyAppData(merged, isFromSync: true)
            let wlCount = merged.watchlists?.count ?? 0
            alertBannerMessage = "Successfully imported and merged backup file (\(merged.portfolios.count) portfolios, \(wlCount) watchlists)."
            Task {
                await stockService.refreshAll(storageService: storageService)
            }
            return
        }

        // Try standard portfolio parse for preview
        if let res = PortfolioIO.parseStandardFile(fileURL: url, storageService: storageService) {
            pendingImportResult = res
        } else {
            alertBannerMessage = "Could not parse file. Please verify the CSV/JSON format."
        }
    }

    private func handleFundFileImport(result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        guard url.startAccessingSecurityScopedResource() else { return }
        defer { url.stopAccessingSecurityScopedResource() }

        if let res = PortfolioIO.parseJapaneseFundFile(fileURL: url) {
            pendingImportResult = res
        } else {
            alertBannerMessage = "Could not parse Japanese mutual fund trade history CSV."
        }
    }

    private func handleWatchlistFileImport(result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        guard url.startAccessingSecurityScopedResource() else { return }
        defer { url.stopAccessingSecurityScopedResource() }

        if let parsed = SpreadsheetIO.parseWatchlistsFile(from: url) {
            var msgs: [String] = []
            for (wlName, symbols) in parsed {
                let deduped = Set(symbols)
                if let existing = storageService.watchlists.first(where: {
                    $0.name.trimmingCharacters(in: .whitespaces).lowercased() == wlName.trimmingCharacters(in: .whitespaces).lowercased()
                }) {
                    storageService.addMultipleToWatchlist(deduped, targetWatchlistId: existing.id)
                    msgs.append("\(deduped.count) symbols merged into “\(wlName)”")
                } else {
                    let created = storageService.createWatchlist(name: wlName)
                    storageService.addMultipleToWatchlist(deduped, targetWatchlistId: created.id)
                    msgs.append("\(deduped.count) symbols to new “\(wlName)”")
                }
            }
            alertBannerMessage = "Imported watchlists: " + msgs.joined(separator: ", ") + "."
            Task {
                await stockService.refreshAll(storageService: storageService)
            }
        } else {
            alertBannerMessage = "Could not parse watchlist file or no valid symbols found."
        }
    }

    private func exportAppDataBackup() {
        let appData = storageService.exportAppData()
        guard let encoded = try? JSONEncoder().encode(appData) else { return }
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("StockDeck_Backup.json")
        try? encoded.write(to: tempURL, options: .atomic)

        #if os(iOS)
        let av = UIActivityViewController(activityItems: [tempURL], applicationActivities: nil)
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let rootVC = windowScene.windows.first?.rootViewController {
            rootVC.present(av, animated: true, completion: nil)
        }
        #elseif os(macOS)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "StockDeck_Backup.json"
        panel.allowedContentTypes = [.json]
        panel.begin { response in
            if response == .OK, let url = panel.url {
                try? encoded.write(to: url, options: .atomic)
            }
        }
        #endif
    }
}

// MARK: - Add Alert Sheet Helper

struct AddAlertSheet: View {
    @EnvironmentObject var storageService: StorageService
    @EnvironmentObject var stockService: StockService
    @Binding var isPresented: Bool

    @State private var selectedSymbol: String = ""
    @State private var searchText: String = ""

    private var availableSymbols: [String] {
        var set = Set<String>()
        for p in storageService.portfolios {
            for h in p.holdings { set.insert(h.symbol) }
        }
        for w in storageService.watchlists {
            for s in w.symbols { set.insert(s) }
        }
        let list = Array(set).sorted()
        if searchText.isEmpty { return list }
        return list.filter { $0.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        NavigationStack {
            pickerContent
                .navigationTitle(selectedSymbol.isEmpty ? "Select Ticker" : "Set Alert")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { isPresented = false }
                    }
                }
        }
    }

    @ViewBuilder
    private var pickerContent: some View {
        if selectedSymbol.isEmpty {
            symbolPickerList
        } else {
            AlertEditView(symbol: selectedSymbol) {
                isPresented = false
            }
        }
    }

    private var symbolPickerList: some View {
        List {
            Section(header: Text("Choose a symbol from your Watchlists / Portfolios")) {
                if availableSymbols.isEmpty {
                    Text("No symbols available. Add stocks to your Watchlist first.")
                        .foregroundColor(.secondary)
                        .font(.caption)
                } else {
                    ForEach(availableSymbols, id: \.self) { sym in
                        Button {
                            selectedSymbol = sym
                        } label: {
                            HStack {
                                SymbolLogo(symbol: sym, size: 24)
                                Text(sym)
                                    .font(.inter(13, weight: .bold, relativeTo: .body))
                                    .foregroundColor(DS.ink)
                                Spacer()
                                if let q = stockService.quotes[sym] {
                                    Text("$\(StorageService.formatNumber(q.effectivePrice, decimals: 2))")
                                        .font(.inter(12, relativeTo: .caption).monospacedDigit())
                                        .foregroundColor(.secondary)
                                }
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .searchable(text: $searchText, prompt: "Filter tickers")
    }
}
