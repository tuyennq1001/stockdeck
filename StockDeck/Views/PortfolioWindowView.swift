import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Combine

/// The full-window companion to the menu-bar glance. It IS the app in expanded
/// form: same tabs as the popover (Home, Watchlist, Portfolios, Settings), same
/// data, over the same shared `StockService`/`StorageService` — so edits here
/// reflect in the menu bar instantly and vice versa. The look is the "private
/// banking" light editorial system: one uninterrupted paper surface under a
/// transparent titlebar, flat tinted sidebar, floating traffic lights.
struct PortfolioWindowView: View {
    let stockService: StockService
    @EnvironmentObject var storageService: StorageService
    @Namespace private var navNamespace

    /// Sidebar destinations — the dock tabs, with Portfolios expanded per portfolio.
    enum Nav: Hashable {
        case home, insights, news, watchlist, portfoliosAll, importExport, settings, aiReview, alerts, earnings
        case portfolio(UUID)
    }

    /// Scope passed to the portfolio overview.
    typealias Scope = PortfolioScope

    @State private var selection: Nav = PortfolioWindowView.initialSelection()
    @AppStorage("stockdeck.superchart.workspaceEnabled") private var isSuperchartMode = false
    @State private var superchartSymbol: String?
    @State private var portfolioPath = NavigationPath()

    /// Dev affordance: SD_OPEN_TAB=home|insights|news|watchlist|settings|earnings preselects a tab so
    /// each pane can be screenshotted deterministically.
    static func initialSelection() -> Nav {
        switch ProcessInfo.processInfo.environment["SD_OPEN_TAB"] {
        case "home", "insights": return .insights
        case "news": return .news
        case "watchlist": return .watchlist
        case "settings": return .settings
        case "earnings": return .earnings
        default: return .portfoliosAll
        }
    }
    @State private var showSearch = false
    @State private var addHoldingTarget: AddHoldingTarget?
    @State private var editHolding: EditTarget?
    @State private var showNewPortfolioAlert = false
    @State private var showBinanceSheet = false
    @State private var newPortfolioName = ""
    @State private var showNewWatchlistAlert = false
    @State private var newWatchlistName = ""
    @State private var renamingWatchlist: Watchlist? = nil
    @State private var renameWatchlistName = ""
    @State private var deletePortfolioTarget: PortfolioRef? = nil
    @State private var deleteWatchlistTarget: Watchlist? = nil
    @State private var renameTarget: PortfolioRef?
    @State private var notifTarget: PortfolioRef?
    @State private var importAlert: String?
    @State private var pendingImportResult: PortfolioIO.ImportResult? = nil
    @State private var activeOverviewVM: PortfolioViewModel?
    @State private var sidebarSummaryCache = SidebarPortfolioSummaryCache()
    @State private var watchlistViewModel = WatchlistViewModel()

    init(stockService: StockService) {
        self.stockService = stockService
    }

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
        Group {
            if storageService.isRestoringData {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    modeRail
                    if isSuperchartMode {
                        SuperchartWorkspaceView(stockService: stockService,
                            selectedSymbol: $superchartSymbol,
                            initialSource: sourceForCurrentSelection(),
                            onSelectSource: selectSuperchartSource)
                            .frame(minWidth: 430, maxWidth: .infinity, maxHeight: .infinity)
                            .id("superchart")
                            .transition(.opacity.combined(with: .offset(y: 6)))
                    } else {
                        NavigationSplitView {
                            sidebar
                                .navigationSplitViewColumnWidth(min: 224, ideal: 240, max: 280)
                        } detail: {
                            detail
                                .frame(minWidth: 640)
                                .id(String(describing: selection))
                                .transition(.opacity.combined(with: .offset(y: 6)))
                        }
                        .frame(minWidth: 920, maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
        .animation(.easeOut(duration: 0.22), value: selection)
        .task {
            sidebarSummaryCache.setup(stockService: stockService, storageService: storageService)
            await sidebarSummaryCache.refresh()
        }
        .toolbar(removing: .sidebarToggle)
        .toolbarBackground(.hidden, for: .windowToolbar)
        .frame(minWidth: 1000, minHeight: 680)
        .preferredColorScheme(storageService.appearanceMode.colorScheme)
        // Clicking an alert notification lands the user on the Alerts tab.
        .onReceive(NotificationCenter.default.publisher(for: .stockDeckAlertTapped)) { _ in
            isSuperchartMode = false
            navigate(to: .alerts)
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
                if let p = storageService.portfolios.first(where: { $0.id == id }) {
                    deletePortfolioTarget = PortfolioRef(id: p.id, name: p.name)
                }
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
        .alert("New Portfolio", isPresented: $showNewPortfolioAlert) {
            TextField("Portfolio name", text: $newPortfolioName)
            Button("Cancel", role: .cancel) { newPortfolioName = "" }
            Button("Create") {
                let trimmed = newPortfolioName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    storageService.addPortfolio(name: trimmed)
                }
                newPortfolioName = ""
            }
        }
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
                closedTrades: res.closedTrades,
                transactions: res.transactions,
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
        .alert("Delete Portfolio", isPresented: Binding(get: { deletePortfolioTarget != nil }, set: { if !$0 { deletePortfolioTarget = nil } })) {
            Button("Cancel", role: .cancel) { deletePortfolioTarget = nil }
            Button("Delete", role: .destructive) {
                if let p = deletePortfolioTarget {
                    storageService.deletePortfolio(id: p.id)
                    if selection == .portfolio(p.id) { navigate(to: .portfoliosAll) }
                }
                deletePortfolioTarget = nil
            }
        } message: {
            Text("Are you sure you want to delete portfolio '\(deletePortfolioTarget?.name ?? "")'? This action cannot be undone.")
        }
        .background(keyboardShortcuts)
    }

    /// Invisible buttons that give the window native keyboard shortcuts:
    /// ⌘1 AI Insights · ⌘2 Watchlist · ⌘3 Portfolios · ⌘4 Settings · ⌘5 AI Review · ⌘6 News · ⌘R Refresh · ⌘N New portfolio.
    private var keyboardShortcuts: some View {
        Group {
            Button("") { navigate(to: .insights) }.keyboardShortcut("1", modifiers: .command).disabled(isSuperchartMode)
            Button("") { navigate(to: .watchlist) }.keyboardShortcut("2", modifiers: .command)
            Button("") { navigate(to: .portfoliosAll) }.keyboardShortcut("3", modifiers: .command)
            Button("") { navigate(to: .settings) }.keyboardShortcut("4", modifiers: .command).disabled(isSuperchartMode)
            Button("") { navigate(to: .aiReview) }.keyboardShortcut("5", modifiers: .command).disabled(isSuperchartMode)
            Button("") { navigate(to: .news) }.keyboardShortcut("6", modifiers: .command).disabled(isSuperchartMode)
            Button("") {
                Task {
                    await storageService.waitUntilRestored()
                    await stockService.refreshAll(storageService: storageService)
                }
            }.keyboardShortcut("r", modifiers: .command)
            Button("") { showNewPortfolioAlert = true }.keyboardShortcut("n", modifiers: .command)
            // ⌘W closes just this window — StockDeck keeps living in the menu bar.
            Button("") { NSApp.keyWindow?.performClose(nil) }.keyboardShortcut("w", modifiers: .command)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
    }

    // MARK: - Sidebar

    private var modeRail: some View {
        VStack(spacing: 8) {
            modeRailButton(title: "Bảng", symbol: "tablecells", selected: !isSuperchartMode) {
                isSuperchartMode = false
            }
            modeRailButton(title: "Superchart", symbol: "chart.xyaxis.line", selected: isSuperchartMode) {
                isSuperchartMode = true
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 14)
        .frame(minWidth: 60, maxWidth: 60, maxHeight: .infinity)
        .background(DS.sidebarBG)
        .overlay(alignment: .trailing) { DS.hairline.frame(width: 1) }
    }

    private func modeRailButton(title: String, symbol: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 17, weight: .medium))
                Text(title).font(.inter(9, weight: selected ? .semibold : .medium, relativeTo: .caption2))
                    .lineLimit(1).minimumScaleFactor(0.72)
            }
            .foregroundStyle(selected ? DS.brand : DS.inkSecondary)
            .frame(width: 54, height: 52)
            .background(selected ? DS.brand.opacity(0.11) : .clear, in: RoundedRectangle(cornerRadius: 9))
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
        .padding(.horizontal, 3)
    }

    private var sidebar: some View {
        return VStack(spacing: 0) {
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
            Divider().overlay(DS.hairline)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    watchlistsHeader
                    SidebarWatchlistsSection(
                        storageService: storageService,
                        isWatchlistSectionSelected: selection == .watchlist,
                        navNamespace: navNamespace,
                        onSelect: { wl in
                            storageService.selectedWatchlistId = wl.id
                            navigate(to: .watchlist)
                        },
                        onAddSymbol: { wl in
                            storageService.selectedWatchlistId = wl.id
                            showSearch = true
                        },
                        onRename: { wl in
                            renamingWatchlist = wl
                            renameWatchlistName = wl.name
                        },
                        onDelete: { wl in
                            deleteWatchlistTarget = wl
                        }
                    )

                    portfoliosHeader
                    let allStats = portfolioStats(for: storageService.portfolios)
                    NavRow(icon: "square.grid.2x2", title: "All Portfolios",
                           trailing: allStats.text,
                           trailingTint: DS.pnlColor(allStats.percent),
                           helpText: "Combined view of every portfolio  ⌘3",
                           selected: selection == .portfoliosAll, namespace: navNamespace) { navigate(to: .portfoliosAll) }
                    SidebarPortfoliosSection(
                        storageService: storageService,
                        selectedPortfolioId: {
                            if case .portfolio(let id) = selection { return id }
                            return nil
                        }(),
                        navNamespace: navNamespace,
                        statsProvider: { portfolio in portfolioStats(for: [portfolio]) },
                        onSelect: { portfolio in navigate(to: .portfolio(portfolio.id)) },
                        onAddHolding: { portfolio in addHoldingTarget = AddHoldingTarget(portfolioId: portfolio.id, symbol: nil) },
                        onRename: { portfolio in renameTarget = PortfolioRef(id: portfolio.id, name: portfolio.name) },
                        onNotifications: { portfolio in notifTarget = PortfolioRef(id: portfolio.id, name: portfolio.name) },
                        onDelete: { portfolio in deletePortfolioTarget = PortfolioRef(id: portfolio.id, name: portfolio.name) }
                    )

                    utilitiesHeader
                    NavRow(icon: "sparkles", title: "AI Review",
                           helpText: "Advise on your watchlists & portfolios with built-in context  ⌘5",
                           selected: selection == .aiReview, namespace: navNamespace) { navigate(to: .aiReview) }
                        .disabled(isSuperchartMode).opacity(isSuperchartMode ? 0.45 : 1)
                    NavRow(icon: "calendar", title: "Earnings",
                           helpText: "Earnings report calendar for your portfolios & watchlists",
                           selected: selection == .earnings, namespace: navNamespace) { navigate(to: .earnings) }
                        .disabled(isSuperchartMode).opacity(isSuperchartMode ? 0.45 : 1)
                    NavRow(icon: "bell", title: "Alerts",
                           helpText: "Price alerts you've set on your watchlist symbols",
                           selected: selection == .alerts, namespace: navNamespace) { navigate(to: .alerts) }
                        .disabled(isSuperchartMode).opacity(isSuperchartMode ? 0.45 : 1)
                    NavRow(icon: "arrow.triangle.2.circlepath.icloud", title: "Import / Export", helpText: "iCloud Sync, import & export portfolios, watchlists, templates",
                           selected: selection == .importExport, namespace: navNamespace) { navigate(to: .importExport) }
                        .disabled(isSuperchartMode).opacity(isSuperchartMode ? 0.45 : 1)
                }
                .padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 12)
            }
            Divider().overlay(DS.hairline)
            VStack(alignment: .leading, spacing: 2) {
                NavRow(icon: "sparkles", title: "AI Insights", helpText: "Daily AI market recap & movement drivers  ⌘1",
                       selected: selection == .insights, namespace: navNamespace) { navigate(to: .insights) }
                    .disabled(isSuperchartMode).opacity(isSuperchartMode ? 0.45 : 1)
                NavRow(icon: "newspaper", title: "News", helpText: "Financial news feed for tracked symbols  ⌘6",
                       selected: selection == .news, namespace: navNamespace) { navigate(to: .news) }
                    .disabled(isSuperchartMode).opacity(isSuperchartMode ? 0.45 : 1)
                NavRow(icon: "gearshape", title: "Settings", helpText: "Preferences (shared with the menu bar)  ⌘4",
                       selected: selection == .settings, namespace: navNamespace) { navigate(to: .settings) }
                    .disabled(isSuperchartMode).opacity(isSuperchartMode ? 0.45 : 1)
            }
            .padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 6)
            let totals = sidebarTotals
            let secCurr = storageService.secondaryCurrency
            let secRate = !secCurr.isEmpty && secCurr != storageService.preferredCurrency
                ? stockService.rate(from: storageService.preferredCurrency, to: secCurr)
                : 0
            TotalFooter(value: totals.value,
                        cost: totals.cost,
                        pnl: totals.pnl,
                        currency: storageService.preferredCurrency,
                        decimals: storageService.amountDecimals,
                        secondaryCurrency: secCurr,
                        secondaryRate: secRate)
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
    /// "UTILITIES" section label in the sidebar (AI Review + Alerts).
    private var utilitiesHeader: some View {
        HStack {
            Text("Utilities")
                .font(DS.label)
                .foregroundStyle(DS.inkTertiary)
                .tracking(0.8).textCase(.uppercase)
            Spacer()
        }
        .padding(.horizontal, 10).padding(.top, 20).padding(.bottom, 4)
    }

    /// "PORTFOLIOS" label with the plus button. Right click exports all portfolios.
    private var portfoliosHeader: some View {
        HStack {
            Text("Portfolios")
                .font(DS.label)
                .foregroundStyle(DS.inkTertiary)
                .tracking(0.8).textCase(.uppercase)
            Spacer()

            Button {
                showNewPortfolioAlert = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DS.inkSecondary)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .help("Create new portfolio…")
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

    /// Dedicated menu sections for Import & Sample Downloads.
    private var importMenuSections: [[DSMenuAction]] {
        var sections: [[DSMenuAction]] = [
            [
                DSMenuAction(title: "Import Watchlist (CSV/XLSX/TXT)…", icon: "star") { importWatchlist() },
                DSMenuAction(title: "Import Standard Portfolio (CSV/XLSX)…", icon: "briefcase") { importStandard() },
                DSMenuAction(title: "Import Transaction History (CSV/XLSX)…", icon: "doc.text") { importJapaneseFunds() }
            ],
            [
                DSMenuAction(title: "Download Watchlist Sample (XLSX)", icon: "doc.badge.plus") { downloadWatchlistSampleFile() },
                DSMenuAction(title: "Download Portfolio Sample (XLSX)", icon: "doc.badge.plus") { downloadSampleFile() },
                DSMenuAction(title: "Download Transaction History Template (XLSX)", icon: "doc.badge.plus") { downloadJapaneseFundSampleFile() }
            ]
        ]
        var exportActions: [DSMenuAction] = []
        if !storageService.watchlists.isEmpty {
            exportActions.append(DSMenuAction(title: "Export Watchlists (XLSX)…", icon: "square.and.arrow.up") { exportWatchlists(storageService.watchlists) })
        }
        if !storageService.portfolios.isEmpty {
            exportActions.append(DSMenuAction(title: "Export Portfolios (XLSX)…", icon: "square.and.arrow.up") { exportPortfolios(storageService.portfolios) })
        }
        if !exportActions.isEmpty {
            sections.append(exportActions)
        }
        return sections
    }

    private var brand: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Button { isSuperchartMode = false } label: {
                    HStack(spacing: 10) {
                        BrandMark(size: 30)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("StockDeck").font(.inter(15, weight: .bold, relativeTo: .headline)).foregroundStyle(DS.ink)
                            Text(appVersion).font(DS.micro).foregroundStyle(DS.inkTertiary)
                        }
                    }
                }
                .buttonStyle(.plain)
                Spacer(minLength: 0)
            }
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
        case .home, .insights:
            HomeWideView(mode: .insights, showModePicker: false, onOpenSettings: { navigate(to: .settings) })
                .id("home_insights")
        case .news:
            HomeWideView(mode: .news, showModePicker: false, onOpenSettings: { navigate(to: .settings) })
                .id("home_news")
        case .watchlist:
            WatchlistWideView(stockService: stockService, viewModel: watchlistViewModel, showSearch: $showSearch)
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
                onExportPortfoliosMD: { exportPortfoliosMD(storageService.portfolios) },
                onExportWatchlists: { exportWatchlists(storageService.watchlists) },
                onExportWatchlistsMD: { exportWatchlistsMD(storageService.watchlists) },
                onExportTransactions: { exportTransactions(storageService.portfolios) },
                onExportTransactionsMD: { exportTransactionsMD(storageService.portfolios) }
            )
        case .portfoliosAll:
            NavigationStack(path: $portfolioPath) {
                PortfolioOverview(scope: .all, stockService: stockService)
                    .id("all")
            }
        case .portfolio(let id):
            NavigationStack(path: $portfolioPath) {
                PortfolioOverview(scope: .portfolio(id), stockService: stockService)
                    .id(id)
            }
        case .aiReview:
            AIReviewWideView(onOpenSettings: { navigate(to: .settings) })
        case .earnings:
            EarningsCalendarView()
        case .alerts:
            AlertsWideView()
        }
    }

    /// Sidebar navigation always exits a pushed portfolio detail first. Keeping
    /// this path explicit avoids SwiftUI retaining a stale HoldingDetailView when
    /// the user switches directly to a watchlist or another sidebar destination.
    private func navigate(to destination: Nav) {
        if isSuperchartMode {
            switch destination {
            case .watchlist, .portfolio, .portfoliosAll: break
            default: return
            }
        }
        portfolioPath = NavigationPath()
        selection = destination
    }

    private func sourceForCurrentSelection() -> SuperchartSource {
        switch selection {
        case .watchlist:
            return .watchlist(storageService.selectedWatchlistId ?? storageService.watchlists.first?.id ?? UUID())
        case .portfolio(let id): return .portfolio(id)
        case .portfoliosAll: return .allPortfolios
        default:
            return .watchlist(storageService.selectedWatchlistId ?? storageService.watchlists.first?.id ?? UUID())
        }
    }

    private func selectSuperchartSource(_ source: SuperchartSource) {
        switch source {
        case .watchlist(let id):
            storageService.selectedWatchlistId = id
            navigate(to: .watchlist)
        case .portfolio(let id):
            navigate(to: .portfolio(id))
        case .allPortfolios:
            navigate(to: .portfoliosAll)
        }
    }



    // MARK: - Import / Export (reuses StorageService JSON logic)

    private func exportPortfolios(_ portfolios: [Portfolio]) {
        // This window keeps the app `.regular` for its own lifetime (see
        // `AppDelegate.bringWindowFront`/`windowWillClose`), so the panel
        // never needs the accessory<->regular activation-policy dance.
        PortfolioIO.exportAll(portfolios, storageService: storageService, restoreActivationPolicy: false)
    }

    private func exportPortfoliosMD(_ portfolios: [Portfolio]) {
        PortfolioIO.exportAllMarkdown(portfolios, restoreActivationPolicy: false)
    }

    private func exportWatchlists(_ watchlists: [Watchlist]) {
        PortfolioIO.exportWatchlists(watchlists, stockService: stockService, restoreActivationPolicy: false)
    }

    private func exportWatchlistsMD(_ watchlists: [Watchlist]) {
        PortfolioIO.exportWatchlistsMarkdown(watchlists, stockService: stockService, restoreActivationPolicy: false)
    }

    private func exportTransactions(_ portfolios: [Portfolio]) {
        PortfolioIO.exportTransactions(portfolios, restoreActivationPolicy: false)
    }

    private func exportTransactionsMD(_ portfolios: [Portfolio]) {
        PortfolioIO.exportTransactionsMarkdown(portfolios, restoreActivationPolicy: false)
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

    private var sidebarTotals: (value: Double, cost: Double, pnl: Double) {
        let totals = sidebarSummaryCache.allTotals
        return (totals.value, totals.cost, totals.pnl)
    }

    private func portfolioStats(for portfolios: [Portfolio]) -> (text: String?, percent: Double) {
        guard let first = portfolios.first else { return (nil, 0) }
        if portfolios.count == storageService.portfolios.count {
            let stats = sidebarSummaryCache.allStats
            return (stats.text, stats.percent)
        }
        let stats = sidebarSummaryCache.statsByPortfolio[first.id] ?? .init(text: nil, percent: 0)
        return (stats.text, stats.percent)
    }
}

/// Prepares sidebar totals after portfolio or relevant market data changes.
@Observable
@MainActor
private final class SidebarPortfolioSummaryCache {
    struct Stats: Sendable { var text: String?; var percent: Double }
    struct Totals: Sendable { var value: Double; var cost: Double; var pnl: Double }
    private struct SummaryResult: Sendable {
        var statsByPortfolio: [UUID: Stats]
        var allStats: Stats
        var allTotals: Totals
    }

    private(set) var statsByPortfolio: [UUID: Stats] = [:]
    private(set) var allStats = Stats(text: nil, percent: 0)
    private(set) var allTotals = Totals(value: 0, cost: 0, pnl: 0)
    @ObservationIgnored private weak var stockService: StockService?
    @ObservationIgnored private weak var storageService: StorageService?
    @ObservationIgnored private var cancellables = Set<AnyCancellable>()
    @ObservationIgnored private var worker: Task<SummaryResult, Never>?
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var fingerprint: Int?

    func setup(stockService: StockService, storageService: StorageService) {
        guard self.stockService == nil else { return }
        self.stockService = stockService
        self.storageService = storageService
        Publishers.MergeMany([
            storageService.$portfolios.map { _ in () }.eraseToAnyPublisher(),
            storageService.$preferredCurrency.map { _ in () }.eraseToAnyPublisher(),
            storageService.$symbolType.map { _ in () }.eraseToAnyPublisher()
        ])
        .throttle(for: .milliseconds(250), scheduler: DispatchQueue.main, latest: true)
        .sink { [weak self] _ in Task { @MainActor in await self?.refresh() } }
        .store(in: &cancellables)

        stockService.marketDataChanges
            .filter { [weak storageService] change in
                guard let storageService else { return false }
                if change.kind == .fx { return true }
                let symbols = Set(storageService.portfolios.flatMap(\.holdings)
                    .map { StockService.canonicalSymbol(for: $0.symbol) })
                return !symbols.isDisjoint(with: change.symbols)
            }
            .throttle(for: .milliseconds(250), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] _ in Task { @MainActor in await self?.refresh() } }
            .store(in: &cancellables)
    }

    func refresh() async {
        guard let stockService, let storageService else { return }
        let portfolios = storageService.portfolios
        var hasher = Hasher()
        hasher.combine(storageService.preferredCurrency)
        for portfolio in portfolios {
            hasher.combine(portfolio.id)
            for holding in portfolio.holdings {
                hasher.combine(holding.id)
                hasher.combine(holding.symbol)
                hasher.combine(holding.quantity)
                hasher.combine(holding.avgPrice)
                hasher.combine(holding.purchaseDate)
                hasher.combine(holding.effectiveLeverage)
                let quote = stockService.quotes[holding.symbol] ?? stockService.quotes[holding.symbol.uppercased()]
                hasher.combine(quote?.price)
                hasher.combine(quote?.change)
                hasher.combine(quote?.changePercent)
                hasher.combine(quote?.previousClose)
                hasher.combine(stockService.detectedCurrency(for: holding.symbol))
                hasher.combine(storageService.type(for: holding.symbol))
            }
        }
        hasher.combine(stockService.fxRevision)
        let nextFingerprint = hasher.finalize()
        guard fingerprint != nextFingerprint else { return }
        fingerprint = nextFingerprint
        generation &+= 1
        let requestedGeneration = generation

        let signpostID = PerformanceSignposts.begin(
            "Portfolio sidebar summaries",
            itemCount: portfolios.reduce(0) { $0 + $1.holdings.count }
        )
        defer { PerformanceSignposts.end("Portfolio sidebar summaries", id: signpostID) }
        let inputs = PortfolioValuation.resolveInputs(for: portfolios, stockService: stockService,
                                                      storageService: storageService)
        var portfolioIdByHoldingId: [UUID: UUID] = [:]
        for portfolio in portfolios {
            for holding in portfolio.holdings { portfolioIdByHoldingId[holding.id] = portfolio.id }
        }
        let portfolioIDs = portfolios.map(\.id)
        worker?.cancel()
        let task = Task.detached(priority: .utility) {
            let inputsByPortfolio = Dictionary(grouping: inputs) {
                portfolioIdByHoldingId[$0.holding.id] ?? UUID()
            }
            var nextStats: [UUID: Stats] = [:]
            for id in portfolioIDs {
                if Task.isCancelled { break }
                nextStats[id] = Self.stats(for: PortfolioValuation.totals(inputsByPortfolio[id] ?? []))
            }
            let raw = PortfolioValuation.totals(inputs)
            return SummaryResult(
                statsByPortfolio: nextStats,
                allStats: Self.stats(for: raw),
                allTotals: Totals(value: raw.value, cost: raw.cost, pnl: raw.pnl)
            )
        }
        worker = task
        let result = await task.value
        guard generation == requestedGeneration else { return }
        statsByPortfolio = result.statsByPortfolio
        allStats = result.allStats
        allTotals = result.allTotals
    }

    private nonisolated static func stats(for totals: (value: Double, cost: Double, pnl: Double)) -> Stats {
        guard abs(totals.cost) >= 0.01 else { return Stats(text: nil, percent: 0) }
        let percent = (totals.pnl / abs(totals.cost)) * 100
        return Stats(text: String(format: "%+.1f%%", percent), percent: percent)
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
    let pnl: Double
    let currency: String
    var decimals: Int = 2
    var secondaryCurrency: String = ""
    var secondaryRate: Double = 0

    var body: some View {
        let symbol = StorageService.currencySymbol(for: currency)
        // P&L comes from PortfolioValuation (0 for holdings without cost basis),
        // not `value - cost`, so Binance balances without order history don't
        // report their entire market value as profit.
        let pct: Double? = abs(cost) >= 0.01 ? (pnl / abs(cost)) * 100 : nil
        VStack(alignment: .leading, spacing: 3) {
            Divider().overlay(DS.hairline)
            SectionLabel("Total value").padding(.top, 10)
            Text(StorageService.formatAmount(value, symbol: symbol, decimals: decimals))
                .font(.inter(17, weight: .bold, relativeTo: .title3).monospacedDigit())
                .foregroundStyle(DS.ink)
                .contentTransition(.numericText())
            if !secondaryCurrency.isEmpty && secondaryCurrency != currency && secondaryRate > 0 {
                let secVal = value * secondaryRate
                let secSym = StorageService.currencySymbol(for: secondaryCurrency)
                let secDec = StorageService.defaultDecimals(for: secondaryCurrency)
                Text("≈ \(StorageService.formatAmount(secVal, symbol: secSym, decimals: secDec))")
                    .font(.inter(12, weight: .medium, relativeTo: .caption).monospacedDigit())
                    .foregroundStyle(DS.inkSecondary)
                    .contentTransition(.numericText())
            }
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

/// Isolated sidebar Watchlists list so high-frequency drag hover / drop-indicator updates
/// only re-evaluate the watchlist rows — never the entire `PortfolioWindowView` or `detail` pane.
private struct SidebarWatchlistsSection: View {
    @ObservedObject var storageService: StorageService
    let isWatchlistSectionSelected: Bool
    var navNamespace: Namespace.ID
    let onSelect: (Watchlist) -> Void
    let onAddSymbol: (Watchlist) -> Void
    let onRename: (Watchlist) -> Void
    let onDelete: (Watchlist) -> Void

    @State private var draggingId: UUID? = nil
    @State private var dropIndicator: DropIndicator<UUID>? = nil

    var body: some View {
        let watchlists = storageService.watchlists
        let canDrag = watchlists.count > 1
        VStack(alignment: .leading, spacing: 0) {
            ForEach(watchlists) { wl in
                ReorderRow(
                    id: wl.id,
                    draggingId: $draggingId,
                    dropIndicator: $dropIndicator,
                    isHorizontal: false,
                    attachDragToContent: canDrag,
                    makeDragItem: {
                        DispatchQueue.main.async {
                            draggingId = wl.id
                        }
                        return NSItemProvider(object: wl.id.uuidString as NSString)
                    },
                    onMove: { srcId, tgtId, placement in
                        storageService.moveWatchlist(from: srcId, relativeTo: tgtId, placement: placement)
                    },
                    onCommit: {}
                ) {
                    NavRow(icon: "star", title: wl.name,
                           trailing: "\(wl.symbols.count)",
                           trailingTint: DS.inkTertiary,
                           helpText: "Open “\(wl.name)” watchlist · Drag to reorder",
                           selected: isWatchlistSectionSelected && storageService.selectedWatchlistId == wl.id,
                           namespace: navNamespace) {
                        onSelect(wl)
                    }
                    .padding(.vertical, 1)
                    .contextMenu {
                        Button { onAddSymbol(wl) } label: {
                            Label("Add Symbol…", systemImage: "plus")
                        }
                        Button { onRename(wl) } label: {
                            Label("Rename Watchlist…", systemImage: "pencil")
                        }
                        if let idx = watchlists.firstIndex(where: { $0.id == wl.id }), idx > 0 {
                            let prevId = watchlists[idx - 1].id
                            Button { storageService.moveWatchlist(from: wl.id, beforeOrAfter: prevId) } label: {
                                Label("Move Up", systemImage: "arrow.up")
                            }
                        }
                        if let idx = watchlists.firstIndex(where: { $0.id == wl.id }), idx < watchlists.count - 1 {
                            let nextId = watchlists[idx + 1].id
                            Button { storageService.moveWatchlist(from: nextId, beforeOrAfter: wl.id) } label: {
                                Label("Move Down", systemImage: "arrow.down")
                            }
                        }
                        if watchlists.count > 1 {
                            Divider()
                            Button(role: .destructive) {
                                onDelete(wl)
                            } label: {
                                Label("Delete Watchlist", systemImage: "trash")
                            }
                        }
                    }
                }
            }
        }
        .onDrop(of: [.text], delegate: ReorderContainerDropDelegate(
            draggingId: $draggingId,
            dropIndicator: $dropIndicator,
            onMove: { srcId, tgtId, placement in
                storageService.moveWatchlist(from: srcId, relativeTo: tgtId, placement: placement)
            }
        ))
        .cleanupDragSession(draggingId: $draggingId, dropIndicator: $dropIndicator)
    }
}

/// Isolated sidebar Portfolios list so high-frequency drag hover / drop-indicator updates
/// only re-evaluate the portfolio rows — never the entire `PortfolioWindowView` or `detail` pane.
private struct SidebarPortfoliosSection: View {
    @ObservedObject var storageService: StorageService
    let selectedPortfolioId: UUID?
    var navNamespace: Namespace.ID
    let statsProvider: (Portfolio) -> (text: String?, percent: Double)
    let onSelect: (Portfolio) -> Void
    let onAddHolding: (Portfolio) -> Void
    let onRename: (Portfolio) -> Void
    let onNotifications: (Portfolio) -> Void
    let onDelete: (Portfolio) -> Void

    @State private var draggingId: UUID? = nil
    @State private var dropIndicator: DropIndicator<UUID>? = nil

    var body: some View {
        let portfolios = storageService.portfolios
        let canDrag = portfolios.count > 1
        VStack(alignment: .leading, spacing: 0) {
            ForEach(portfolios) { portfolio in
                ReorderRow(
                    id: portfolio.id,
                    draggingId: $draggingId,
                    dropIndicator: $dropIndicator,
                    isHorizontal: false,
                    attachDragToContent: canDrag,
                    makeDragItem: {
                        DispatchQueue.main.async {
                            draggingId = portfolio.id
                        }
                        return NSItemProvider(object: portfolio.id.uuidString as NSString)
                    },
                    onMove: { srcId, tgtId, placement in
                        storageService.movePortfolio(from: srcId, relativeTo: tgtId, placement: placement)
                    },
                    onCommit: {}
                ) {
                    let stats = statsProvider(portfolio)
                    NavRow(icon: "briefcase", title: portfolio.name,
                           trailing: stats.text,
                           trailingTint: DS.pnlColor(stats.percent),
                           helpText: "Open “\(portfolio.name)” · Drag to reorder · right-click for rename, notifications",
                           selected: selectedPortfolioId == portfolio.id,
                           namespace: navNamespace) {
                        onSelect(portfolio)
                    }
                    .padding(.vertical, 1)
                    .contextMenu {
                        Button { onAddHolding(portfolio) } label: {
                            Label("Add Holding…", systemImage: "plus")
                        }
                        Button { onRename(portfolio) } label: {
                            Label("Rename…", systemImage: "pencil")
                        }
                        Button { onNotifications(portfolio) } label: {
                            Label("Notifications…", systemImage: "bell")
                        }
                        if portfolios.count > 1 {
                            Divider()
                            if let idx = portfolios.firstIndex(where: { $0.id == portfolio.id }), idx > 0 {
                                let prevId = portfolios[idx - 1].id
                                Button { storageService.movePortfolio(from: portfolio.id, beforeOrAfter: prevId) } label: {
                                    Label("Move Up", systemImage: "arrow.up")
                                }
                            }
                            if let idx = portfolios.firstIndex(where: { $0.id == portfolio.id }), idx < portfolios.count - 1 {
                                let nextId = portfolios[idx + 1].id
                                Button { storageService.movePortfolio(from: nextId, beforeOrAfter: portfolio.id) } label: {
                                    Label("Move Down", systemImage: "arrow.down")
                                }
                            }
                        }
                        Divider()
                        Button(role: .destructive) {
                            onDelete(portfolio)
                        } label: { Label("Delete Portfolio", systemImage: "trash") }
                    }
                }
            }
        }
        .onDrop(of: [.text], delegate: ReorderContainerDropDelegate(
            draggingId: $draggingId,
            dropIndicator: $dropIndicator,
            onMove: { srcId, tgtId, placement in
                storageService.movePortfolio(from: srcId, relativeTo: tgtId, placement: placement)
            }
        ))
        .cleanupDragSession(draggingId: $draggingId, dropIndicator: $dropIndicator)
    }
}
