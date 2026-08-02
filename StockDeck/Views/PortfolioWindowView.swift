import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The full-window companion to the menu-bar glance. It IS the app in expanded
/// form: same tabs as the popover (Home, Watchlist, Portfolios, Settings), same
/// data, over the same shared `StockService`/`StorageService` — so edits here
/// reflect in the menu bar instantly and vice versa. The look is the "private
/// banking" light editorial system: one uninterrupted paper surface under a
/// transparent titlebar, flat tinted sidebar, floating traffic lights.
struct PortfolioWindowView: View {
    @EnvironmentObject var stockService: StockService
    @EnvironmentObject var storageService: StorageService
    @Namespace private var navNamespace

    /// Sidebar destinations — the dock tabs, with Portfolios expanded per portfolio.
    enum Nav: Hashable {
        case home, watchlist, portfoliosAll, importExport, settings
        case portfolio(UUID)
    }

    /// Scope passed to the portfolio overview.
    enum Scope: Hashable {
        case all
        case portfolio(UUID)
    }

    @State private var selection: Nav = PortfolioWindowView.initialSelection()
    @State private var portfolioPath = NavigationPath()

    /// Dev affordance: SD_OPEN_TAB=home|watchlist|settings preselects a tab so
    /// each pane can be screenshotted deterministically.
    static func initialSelection() -> Nav {
        switch ProcessInfo.processInfo.environment["SD_OPEN_TAB"] {
        case "home": return .home
        case "watchlist": return .watchlist
        case "settings": return .settings
        default: return .portfoliosAll
        }
    }
    @State private var showSearch = false
    @State private var addHoldingTarget: AddHoldingTarget?
    @State private var editHolding: EditTarget?
    @State private var showNewPortfolio = false
    @State private var showBinanceSheet = false
    @State private var newPortfolioName = ""
    @State private var showNewWatchlistAlert = false
    @State private var newWatchlistName = ""
    @State private var renamingWatchlist: Watchlist? = nil
    @State private var renameWatchlistName = ""
    @State private var deleteWatchlistTarget: Watchlist? = nil
    @State private var draggingWatchlistId: UUID? = nil
    @State private var renameTarget: PortfolioRef?
    @State private var notifTarget: PortfolioRef?
    @State private var importAlert: String?
    @State private var pendingImportResult: PortfolioIO.ImportResult? = nil
    @State private var activeOverviewVM: PortfolioViewModel?

    /// Shared valuation cache from the active PortfolioOverview ViewModel.
    /// The sidebar TotalFooter reads this instead of recalculating independently.
    private struct SidebarValuation {
        var value: Double
        var cost: Double
    }
    @State private var sidebarValuation: SidebarValuation = .init(value: 0, cost: 0)

    struct AddHoldingTarget: Identifiable {
        let id = UUID()
        let portfolioId: UUID
        let symbol: String?
    }

    /// Wraps the edit-holding tuple so it can drive a `.sheet(item:)`.
    struct EditTarget: Identifiable {
        let portfolioId: UUID
        let holding: Holding
        var id: UUID { holding.id }
    }
    struct PortfolioRef: Identifiable { let id: UUID; let name: String }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 224, ideal: 240, max: 280)
        } detail: {
            detail
                .frame(minWidth: 640)
                .id(selection)
                .transition(.opacity.combined(with: .offset(y: 6)))
        }
        .animation(.easeOut(duration: 0.22), value: selection)
        .toolbar(removing: .sidebarToggle)
        .toolbarBackground(.hidden, for: .windowToolbar)
        .frame(minWidth: 1000, minHeight: 680)
        .preferredColorScheme(storageService.appearanceMode.colorScheme)
        // If News is turned off while its pane is open, fall back to Watchlist.
        .onChange(of: storageService.showNewsTab) { _, showNews in
            if !showNews, selection == .home { navigate(to: .watchlist) }
        }
        .environment(\.locale, Locale(identifier: storageService.appLanguage))
        .environment(\.addHoldingAction, AddHoldingAction { addHoldingTarget = AddHoldingTarget(portfolioId: $0, symbol: $1) })
        .environment(\.editHoldingAction, EditHoldingAction { editHolding = EditTarget(portfolioId: $0, holding: $1) })
        .environment(\.portfolioActions, PortfolioActions(
            addHolding: { addHoldingTarget = AddHoldingTarget(portfolioId: $0, symbol: nil) },
            batchImport: { _ in importStandard() },
            rename: { renameTarget = PortfolioRef(id: $0, name: $1) },
            notifications: { notifTarget = PortfolioRef(id: $0, name: $1) },
            export: { exportPortfolios([$0]) },
            delete: { id in
                storageService.deletePortfolio(id: id)
                if selection == .portfolio(id) { navigate(to: .portfoliosAll) }
            }))
        .sheet(isPresented: $showSearch) {
            WatchlistSearchSheet { showSearch = false }
                .environmentObject(stockService).environmentObject(storageService)
        }
        .sheet(item: $addHoldingTarget) { target in
            let mode: HoldingFormSheet.Mode = {
                if let sym = target.symbol {
                    return .addSymbol(symbol: sym, portfolioId: target.portfolioId)
                } else {
                    return .add(portfolioId: target.portfolioId)
                }
            }()
            HoldingFormSheet(mode: mode) { addHoldingTarget = nil }
                .environmentObject(stockService).environmentObject(storageService)
        }
        .sheet(item: $editHolding) { target in
            HoldingFormSheet(mode: .edit(portfolioId: target.portfolioId, holding: target.holding)) { editHolding = nil }
                .environmentObject(stockService).environmentObject(storageService)
        }
        .sheet(isPresented: $showNewPortfolio) { newPortfolioSheet }
        .sheet(isPresented: $showBinanceSheet) {
            AddBinancePortfolioSheet(storageService: storageService) { newP in
                selection = .portfolio(newP.id)
            }
        }
        .sheet(item: $renameTarget) { t in
            RenamePortfolioSheet(portfolioId: t.id, currentName: t.name) { renameTarget = nil }
                .environmentObject(storageService)
        }
        .sheet(item: $notifTarget) { t in
            PortfolioNotificationsSheet(portfolioId: t.id, portfolioName: t.name) { notifTarget = nil }
                .environmentObject(storageService)
        }
        .sheet(item: $pendingImportResult) { res in
            ImportPreviewSheet(
                items: res.items,
                suggestedPortfolioName: res.suggestedPortfolioName,
                isFundImport: res.isFundImport
            ) {
                pendingImportResult = nil
            }
            .environmentObject(stockService)
            .environmentObject(storageService)
        }
        .dsAlert(Binding(get: { importAlert != nil }, set: { if !$0 { importAlert = nil } }),
                 title: "Import", message: importAlert ?? "", confirmTitle: "OK", cancelTitle: nil, onConfirm: {})
        .alert("New Watchlist", isPresented: $showNewWatchlistAlert) {
            TextField("Watchlist name", text: $newWatchlistName)
            Button("Cancel", role: .cancel) { newWatchlistName = "" }
            Button("Create") {
                let trimmed = newWatchlistName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    storageService.createWatchlist(name: trimmed)
                }
                newWatchlistName = ""
            }
        }
        .alert("Rename Watchlist", isPresented: Binding(get: { renamingWatchlist != nil }, set: { if !$0 { renamingWatchlist = nil } })) {
            TextField("Watchlist name", text: $renameWatchlistName)
            Button("Cancel", role: .cancel) { renamingWatchlist = nil }
            Button("Rename") {
                if let wl = renamingWatchlist {
                    let trimmed = renameWatchlistName.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        storageService.renameWatchlist(id: wl.id, newName: trimmed)
                    }
                    renamingWatchlist = nil
                }
            }
        }
        .alert("Delete Watchlist", isPresented: Binding(get: { deleteWatchlistTarget != nil }, set: { if !$0 { deleteWatchlistTarget = nil } })) {
            Button("Cancel", role: .cancel) { deleteWatchlistTarget = nil }
            Button("Delete", role: .destructive) {
                if let wl = deleteWatchlistTarget {
                    storageService.deleteWatchlist(id: wl.id)
                    deleteWatchlistTarget = nil
                }
            }
        } message: {
            Text("Are you sure you want to delete “\(deleteWatchlistTarget?.name ?? "")”? This action cannot be undone.")
        }
        .background(keyboardShortcuts)
    }

    /// Invisible buttons that give the window native keyboard shortcuts:
    /// ⌘1 Home · ⌘2 Watchlist · ⌘3 Portfolios · ⌘4 Settings · ⌘R Refresh · ⌘N New portfolio.
    private var keyboardShortcuts: some View {
        Group {
            Button("") { if storageService.showNewsTab { navigate(to: .home) } }.keyboardShortcut("1", modifiers: .command)
            Button("") { navigate(to: .watchlist) }.keyboardShortcut("2", modifiers: .command)
            Button("") { navigate(to: .portfoliosAll) }.keyboardShortcut("3", modifiers: .command)
            Button("") { navigate(to: .settings) }.keyboardShortcut("4", modifiers: .command)
            Button("") {
                Task { await stockService.refreshAll(storageService: storageService) }
            }.keyboardShortcut("r", modifiers: .command)
            Button("") { showNewPortfolio = true }.keyboardShortcut("n", modifiers: .command)
            // ⌘W closes just this window — StockDeck keeps living in the menu bar.
            Button("") { NSApp.keyWindow?.performClose(nil) }.keyboardShortcut("w", modifiers: .command)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            // Top-right support icons, in the traffic-light clearance band (lights
            // sit on the left, so these stay clear of them).
            HStack(spacing: 6) {
                Spacer()
                SupportButton(icon: "star", title: "Star", hoverTint: DS.gold,
                              url: "https://github.com/tuyennq1001/stockdeck", compact: true)
                SupportButton(icon: "heart", title: "Sponsor", hoverTint: Color(red: 0.86, green: 0.30, blue: 0.46),
                              url: "https://github.com/sponsors/tuyennq1001", compact: true)
            }
            .padding(.top, 12).padding(.trailing, 12).padding(.bottom, 2)
            brand
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if storageService.showNewsTab {
                        NavRow(icon: "newspaper", title: "Home", helpText: "Financial news for your symbols  ⌘1",
                               selected: selection == .home, namespace: navNamespace) { navigate(to: .home) }
                    }

                    watchlistsHeader
                    ForEach(storageService.watchlists) { wl in
                        NavRow(icon: "star", title: wl.name,
                               trailing: "\(wl.symbols.count)",
                               trailingTint: DS.inkTertiary,
                               helpText: "Open “\(wl.name)” watchlist · Drag to reorder",
                               selected: selection == .watchlist && storageService.selectedWatchlistId == wl.id,
                               namespace: navNamespace) {
                            storageService.selectedWatchlistId = wl.id
                            navigate(to: .watchlist)
                        }
                        .onDrag {
                            self.draggingWatchlistId = wl.id
                            return NSItemProvider(object: wl.id.uuidString as NSString)
                        }
                        .onDrop(of: [.text], delegate: WatchlistSidebarDropDelegate(
                            targetId: wl.id,
                            draggingId: $draggingWatchlistId,
                            onMove: { srcId, tgtId in
                                storageService.moveWatchlist(from: srcId, beforeOrAfter: tgtId)
                            }
                        ))
                        .contextMenu {
                            Button { renamingWatchlist = wl; renameWatchlistName = wl.name } label: {
                                Label("Rename Watchlist…", systemImage: "pencil")
                            }
                            if storageService.watchlists.count > 1 {
                                Divider()
                                Button(role: .destructive) {
                                    deleteWatchlistTarget = wl
                                } label: {
                                    Label("Delete Watchlist", systemImage: "trash")
                                }
                            }
                        }
                    }

                    portfoliosHeader
                    NavRow(icon: "square.grid.2x2", title: "All Portfolios",
                           trailing: trailingPercent(for: storageService.portfolios),
                           trailingTint: DS.pnlColor(aggregatePnlPercent(for: storageService.portfolios)),
                           helpText: "Combined view of every portfolio  ⌘3",
                           selected: selection == .portfoliosAll, namespace: navNamespace) { navigate(to: .portfoliosAll) }
                    ForEach(storageService.portfolios) { portfolio in
                        NavRow(icon: "briefcase", title: portfolio.name,
                               trailing: trailingPercent(for: [portfolio]),
                               trailingTint: DS.pnlColor(aggregatePnlPercent(for: [portfolio])),
                               helpText: "Open “\(portfolio.name)” · right-click for rename, notifications",
                               selected: selection == .portfolio(portfolio.id), namespace: navNamespace) {
                            navigate(to: .portfolio(portfolio.id))
                        }
                        .contextMenu {
                            Button { addHoldingTarget = AddHoldingTarget(portfolioId: portfolio.id, symbol: nil) } label: {
                                Label("Add Holding…", systemImage: "plus")
                            }
                            Button { importStandard() } label: {
                                Label("Import File…", systemImage: "square.and.arrow.down")
                            }
                            Button { renameTarget = PortfolioRef(id: portfolio.id, name: portfolio.name) } label: {
                                Label("Rename…", systemImage: "pencil")
                            }
                            Button { notifTarget = PortfolioRef(id: portfolio.id, name: portfolio.name) } label: {
                                Label("Notifications…", systemImage: "bell")
                            }
                            Divider()
                            Button(role: .destructive) {
                                storageService.deletePortfolio(id: portfolio.id)
                                if selection == .portfolio(portfolio.id) { navigate(to: .portfoliosAll) }
                            } label: { Label("Delete", systemImage: "trash") }
                        }
                    }
                }
                .padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 12)
            }
            // Pinned bottom block: Import / Export, Settings, then total footer.
            NavRow(icon: "square.and.arrow.down.on.square", title: "Import / Export", helpText: "Import & Export portfolios, watchlists, templates",
                   selected: selection == .importExport, namespace: navNamespace) { navigate(to: .importExport) }
                .padding(.horizontal, 12).padding(.top, 4).padding(.bottom, 2)

            NavRow(icon: "gearshape", title: "Settings", helpText: "Preferences (shared with the menu bar)  ⌘4",
                   selected: selection == .settings, namespace: navNamespace) { navigate(to: .settings) }
                .padding(.horizontal, 12).padding(.top, 2).padding(.bottom, 6)
            TotalFooter(value: aggregateValue(for: storageService.portfolios),
                        cost: aggregateCost(for: storageService.portfolios),
                        currency: storageService.preferredCurrency,
                        decimals: storageService.amountDecimals)
            quitRow
        }
        .background(DS.sidebarBG)
        .overlay(alignment: .trailing) { DS.hairline.frame(width: 1) }
    }


    /// Explicit exit: closing the window keeps StockDeck in the menu bar, so a
    /// separate "Quit" affordance makes "leave everything" discoverable.
    @State private var quitHover = false
    private var quitRow: some View {
        VStack(spacing: 0) {
            Divider().overlay(DS.hairline)
            Button {
                NSApp.terminate(nil)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "power").font(.system(size: 11, weight: .medium))
                    Text("Quit StockDeck").font(.inter(11.5, weight: .medium, relativeTo: .caption))
                    Spacer()
                    Text("⌘Q").font(.inter(10, relativeTo: .caption2)).foregroundStyle(DS.inkTertiary)
                }
                .foregroundStyle(quitHover ? DS.down : DS.inkSecondary)
                .padding(.horizontal, 14).padding(.vertical, 9)
                .contentShape(Rectangle())
                .background(quitHover ? DS.down.opacity(0.08) : .clear)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("q", modifiers: .command)
            .onHover { quitHover = $0 }
            .help("Quit StockDeck completely — closing the window keeps it in the menu bar")
        }
    }

    /// "WATCHLISTS" label with the plus button. Right click exports all watchlists.
    private var watchlistsHeader: some View {
        HStack {
            Text("Watchlists")
                .font(DS.label)
                .foregroundStyle(DS.inkTertiary)
                .tracking(0.8).textCase(.uppercase)
            Spacer()
            Button {
                showNewWatchlistAlert = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DS.inkSecondary)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .help("Create new watchlist…")
        }
        .padding(.horizontal, 10).padding(.top, 14).padding(.bottom, 4)
        .contentShape(Rectangle())
        .contextMenu {
            Button {
                exportWatchlists(storageService.watchlists)
            } label: {
                Label("Export All Watchlists (XLSX)…", systemImage: "square.and.arrow.up")
            }
        }
    }

    /// "PORTFOLIOS" label with the quiet + button. Right click exports all portfolios.
    private var portfoliosHeader: some View {
        HStack {
            Text("Portfolios")
                .font(DS.label)
                .foregroundStyle(DS.inkTertiary)
                .tracking(0.8).textCase(.uppercase)
            Spacer()

            DSMenu(width: 230, sections: plusMenuSections) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DS.inkSecondary)
                    .frame(width: 20, height: 20)
            }
            .help("New portfolio or add holding…")
        }
        .padding(.horizontal, 10).padding(.top, 20).padding(.bottom, 4)
        .contentShape(Rectangle())
        .contextMenu {
            Button {
                exportPortfolios(storageService.portfolios)
            } label: {
                Label("Export All Portfolios (XLSX)…", systemImage: "square.and.arrow.up")
            }
        }
    }

    /// "IMPORT / EXPORT" section header in the sidebar.
    private var importExportHeader: some View {
        HStack {
            Text("Import / Export")
                .font(DS.label)
                .foregroundStyle(DS.inkTertiary)
                .tracking(0.8).textCase(.uppercase)
            Spacer()

            DSMenu(width: 260, sections: importMenuSections) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DS.inkSecondary)
                    .frame(width: 20, height: 20)
            }
            .help("Import portfolios/watchlists, download samples, or export data…")
        }
        .padding(.horizontal, 10).padding(.top, 20).padding(.bottom, 4)
    }

    /// Dedicated menu sections for Import & Sample Downloads.
    private var importMenuSections: [[DSMenuAction]] {
        var sections: [[DSMenuAction]] = [
            [
                DSMenuAction(title: "Import Standard Portfolio (CSV/XLSX)…", icon: "briefcase") { importStandard() },
                DSMenuAction(title: "Import 投資信託 (Japanese Funds CSV/XLSX)…", icon: "doc.text") { importJapaneseFunds() },
                DSMenuAction(title: "Import Watchlist (CSV/XLSX/TXT)…", icon: "star") { importWatchlist() }
            ],
            [
                DSMenuAction(title: "Download Portfolio Sample (XLSX)", icon: "doc.badge.plus") { downloadSampleFile() },
                DSMenuAction(title: "Download 投資信託 Template (XLSX)", icon: "doc.badge.plus") { downloadJapaneseFundSampleFile() },
                DSMenuAction(title: "Download Watchlist Sample (XLSX)", icon: "doc.badge.plus") { downloadWatchlistSampleFile() }
            ]
        ]
        var exportActions: [DSMenuAction] = []
        if !storageService.portfolios.isEmpty {
            exportActions.append(DSMenuAction(title: "Export Portfolios (XLSX)…", icon: "square.and.arrow.up") { exportPortfolios(storageService.portfolios) })
        }
        if !storageService.watchlists.isEmpty {
            exportActions.append(DSMenuAction(title: "Export Watchlists (XLSX)…", icon: "square.and.arrow.up") { exportWatchlists(storageService.watchlists) })
        }
        if !exportActions.isEmpty {
            sections.append(exportActions)
        }
        return sections
    }

    /// Sections for the sidebar "+" DSMenu.
    private var plusMenuSections: [[DSMenuAction]] {
        var s: [[DSMenuAction]] = [[ DSMenuAction(title: "New Portfolio…", icon: "folder.badge.plus") { showNewPortfolio = true } ]]
        if !storageService.portfolios.isEmpty {
            s.append(storageService.portfolios.map { p in
                DSMenuAction(title: "Add to \(p.name)", icon: "plus") { addHoldingTarget = AddHoldingTarget(portfolioId: p.id, symbol: nil) }
            })
        }
        return s
    }

    private var brand: some View {
        HStack(spacing: 10) {
            BrandMark(size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text("StockDeck").font(.inter(15, weight: .bold, relativeTo: .headline)).foregroundStyle(DS.ink)
                Text(appVersion).font(DS.micro).foregroundStyle(DS.inkTertiary)
            }
            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            NSApp.keyWindow?.performZoom(nil)
        }
        .background(WindowDragArea())
        .padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 10)
    }

    private var appVersion: String {
        let v = BundleInfo.versionString
        let dev = BundleInfo.isDevBuild ? " · DEV" : ""
        return "v\(v)\(dev)"
    }

    // MARK: - Detail

    @ViewBuilder private var detail: some View {
        switch selection {
        case .home:
            HomeWideView()
        case .watchlist:
            WatchlistWideView(showSearch: $showSearch)
                .id(storageService.selectedWatchlistId)
        case .settings:
            SettingsWideView()
        case .importExport:
            ImportExportWideView(
                onImportStandard: { importStandard() },
                onImportJapaneseFunds: { importJapaneseFunds() },
                onImportWatchlist: { importWatchlist() },
                onDownloadSample: { downloadSampleFile() },
                onDownloadJapaneseFundSample: { downloadJapaneseFundSampleFile() },
                onDownloadWatchlistSample: { downloadWatchlistSampleFile() },
                onExportPortfolios: { exportPortfolios(storageService.portfolios) },
                onExportWatchlists: { exportWatchlists(storageService.watchlists) }
            )
        case .portfoliosAll:
            NavigationStack(path: $portfolioPath) {
                let vm = PortfolioViewModel(scope: .all, stockService: stockService, storageService: storageService)
                PortfolioOverview(viewModel: vm)
                    .onAppear { activeOverviewVM = vm }
            }
        case .portfolio(let id):
            NavigationStack(path: $portfolioPath) {
                let vm = PortfolioViewModel(scope: .portfolio(id), stockService: stockService, storageService: storageService)
                PortfolioOverview(viewModel: vm)
                    .onAppear { activeOverviewVM = vm }
            }
        }
    }

    /// Sidebar navigation always exits a pushed portfolio detail first. Keeping
    /// this path explicit avoids SwiftUI retaining a stale HoldingDetailView when
    /// the user switches directly to a watchlist or another sidebar destination.
    private func navigate(to destination: Nav) {
        portfolioPath = NavigationPath()
        selection = destination
    }

    private var newPortfolioSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Portfolio").font(.inter(15, weight: .bold, relativeTo: .headline))
            TextField("Portfolio name", text: $newPortfolioName)
                .textFieldStyle(.roundedBorder)
                .onSubmit(createPortfolio)

            Divider()

            Button(action: {
                showNewPortfolio = false
                showBinanceSheet = true
            }) {
                HStack {
                    Image(systemName: "circle.hexagongrid.fill")
                        .foregroundColor(.yellow)
                    Text("Connect Binance (Read-Only)...")
                        .font(.inter(12, weight: .medium, relativeTo: .body))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(8)
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(6)
            }
            .buttonStyle(.plain)

            HStack {
                Spacer()
                Button("Cancel") { showNewPortfolio = false; newPortfolioName = "" }
                Button("Create", action: createPortfolio)
                    .buttonStyle(.borderedProminent)
                    .tint(DS.brand)
                    .disabled(newPortfolioName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(18)
        .frame(width: 340)
    }

    private func createPortfolio() {
        let name = newPortfolioName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        storageService.addPortfolio(name: name)
        newPortfolioName = ""
        showNewPortfolio = false
    }

    // MARK: - Import / Export (reuses StorageService JSON logic)

    private func exportPortfolios(_ portfolios: [Portfolio]) {
        // This window keeps the app `.regular` for its own lifetime (see
        // `AppDelegate.bringWindowFront`/`windowWillClose`), so the panel
        // never needs the accessory<->regular activation-policy dance.
        PortfolioIO.exportAll(portfolios, storageService: storageService, restoreActivationPolicy: false)
    }

    private func exportWatchlists(_ watchlists: [Watchlist]) {
        PortfolioIO.exportWatchlists(watchlists, stockService: stockService, restoreActivationPolicy: false)
    }

    private func importStandard() {
        PortfolioIO.pickAndParseStandard(storageService: storageService, restoreActivationPolicy: false, onParsed: { result in
            self.pendingImportResult = result
        }, onAlert: { message in
            self.importAlert = message
        })
    }

    private func importJapaneseFunds() {
        PortfolioIO.pickAndParseJapaneseFunds(restoreActivationPolicy: false, onParsed: { result in
            self.pendingImportResult = result
        }, onAlert: { message in
            self.importAlert = message
        })
    }

    private func downloadSampleFile() {
        PortfolioIO.downloadSample(storageService: storageService, restoreActivationPolicy: false) { message in
            importAlert = message
        }
    }

    private func downloadJapaneseFundSampleFile() {
        PortfolioIO.downloadJapaneseFundSample(restoreActivationPolicy: false) { message in
            importAlert = message
        }
    }

    private func importWatchlist() {
        PortfolioIO.pickAndParseWatchlist(storageService: storageService, restoreActivationPolicy: false) { message in
            importAlert = message
        }
    }

    private func downloadWatchlistSampleFile() {
        PortfolioIO.downloadWatchlistSample(restoreActivationPolicy: false) { message in
            importAlert = message
        }
    }

    // MARK: - Aggregation helpers (reuse the shared valuation math)

    private func valued(_ portfolios: [Portfolio]) -> [PortfolioValuation.Input] {
        PortfolioValuation.resolveInputs(for: portfolios, stockService: stockService, storageService: storageService)
    }

    private func aggregateValue(for portfolios: [Portfolio]) -> Double {
        PortfolioValuation.totals(valued(portfolios)).value
    }
    private func aggregateCost(for portfolios: [Portfolio]) -> Double {
        PortfolioValuation.totals(valued(portfolios)).cost
    }
    private func aggregatePnlPercent(for portfolios: [Portfolio]) -> Double {
        let inputs = valued(portfolios)
        let pnl = inputs.reduce(0) { $0 + $1.holding.pnl(currentPrice: $1.price) * $1.rate }
        let cost = PortfolioValuation.totals(inputs).cost
        return abs(cost) >= 0.01 ? (pnl / abs(cost)) * 100 : 0
    }

    /// Sidebar trailing figure — nil (hidden) until at least one holding is
    /// priced, so an unpriced portfolio never shows a fake "+0.0%".
    private func trailingPercent(for portfolios: [Portfolio]) -> String? {
        guard !valued(portfolios).isEmpty else { return nil }
        return String(format: "%+.1f%%", aggregatePnlPercent(for: portfolios))
    }
}

// MARK: - Sidebar pieces

/// A subtle support button (Star / Sponsor) that opens a URL and warms to a tint
/// on hover.
private struct SupportButton: View {
    let icon: String
    let title: String
    let hoverTint: Color
    let url: String
    var compact: Bool = false
    @State private var hover = false

    var body: some View {
        Button {
            if let u = URL(string: url) { NSWorkspace.shared.open(u) }
        } label: {
            Group {
                if compact {
                    Image(systemName: hover ? "\(icon).fill" : icon)
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(hover ? hoverTint.opacity(0.14) : DS.cardAlt))
                } else {
                    HStack(spacing: 5) {
                        Image(systemName: hover ? "\(icon).fill" : icon).font(.system(size: 11, weight: .medium))
                        Text(LocalizedStringKey(title)).font(.inter(11, weight: .medium, relativeTo: .caption))
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(hover ? hoverTint.opacity(0.10) : DS.cardAlt))
                }
            }
            .foregroundStyle(hover ? hoverTint : DS.inkSecondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(title == "Star" ? "Star the repo on GitHub" : "Sponsor development")
    }
}

private struct TotalFooter: View {
    let value: Double
    let cost: Double
    let currency: String
    var decimals: Int = 2

    var body: some View {
        let symbol = StorageService.currencySymbol(for: currency)
        let pnl = value - cost
        // Same convention as the popover: amount and percentage, always together.
        let pct: Double? = abs(cost) >= 0.01 ? (pnl / abs(cost)) * 100 : nil
        VStack(alignment: .leading, spacing: 3) {
            Divider().overlay(DS.hairline)
            SectionLabel("Total portfolio").padding(.top, 10)
            Text(StorageService.formatAmount(value, symbol: symbol, decimals: decimals))
                .font(.inter(17, weight: .bold, relativeTo: .title3).monospacedDigit())
                .foregroundStyle(DS.ink)
                .contentTransition(.numericText())
            HStack(spacing: 5) {
                Image(systemName: pnl >= 0 ? "arrow.up.right" : "arrow.down.right")
                    .font(.system(size: 8, weight: .bold))
                Text(StorageService.formatAmount(pnl, symbol: symbol, decimals: decimals, signed: true)
                     + (pct.map { String(format: " (%+.1f%%)", $0) } ?? ""))
                    .font(.inter(11, weight: .medium, relativeTo: .caption).monospacedDigit())
                    .contentTransition(.numericText())
            }
            .foregroundStyle(DS.pnlColor(pnl))
            .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
    }
}

private struct WatchlistSidebarDropDelegate: DropDelegate {
    let targetId: UUID
    @Binding var draggingId: UUID?
    let onMove: (UUID, UUID) -> Void

    func performDrop(info: DropInfo) -> Bool {
        draggingId = nil
        return true
    }

    func dropEntered(info: DropInfo) {
        guard let draggingId = draggingId, draggingId != targetId else { return }
        withAnimation(.easeOut(duration: 0.15)) {
            onMove(draggingId, targetId)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }
}
