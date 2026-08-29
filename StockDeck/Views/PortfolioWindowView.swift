#if os(macOS)
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
        case home, watchlist, portfoliosAll, importExport, settings, aiReview, alerts
        case portfolio(UUID)
    }

    /// Scope passed to the portfolio overview.
    typealias Scope = PortfolioScope

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
    @State private var showNewPortfolioAlert = false
    @State private var showBinanceSheet = false
    @State private var newPortfolioName = ""
    @State private var showNewWatchlistAlert = false
    @State private var newWatchlistName = ""
    @State private var renamingWatchlist: Watchlist? = nil
    @State private var renameWatchlistName = ""
    @State private var deletePortfolioTarget: PortfolioRef? = nil
    @State private var deleteWatchlistTarget: Watchlist? = nil
    @State private var draggingWatchlistId: UUID? = nil
    /// Live display order of sidebar watchlists while dragging: no storage writes
    /// during the drag — the final order is committed once on drop.
    @State private var previewWatchlistIds: [UUID] = []
    @State private var draggingPortfolioId: UUID? = nil
    /// Live display order of sidebar portfolios while dragging: no storage writes
    /// during the drag — the final order is committed once on drop.
    @State private var previewPortfolioIds: [UUID] = []
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
        // Clicking an alert notification lands the user on the Alerts tab.
        .onReceive(NotificationCenter.default.publisher(for: .stockDeckAlertTapped)) { _ in
            navigate(to: .alerts)
        }
        .onChange(of: draggingWatchlistId) { _, newValue in
            if newValue == nil { previewWatchlistIds = [] }
        }
        .onChange(of: draggingPortfolioId) { _, newValue in
            if newValue == nil { previewPortfolioIds = [] }
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
    /// ⌘1 Home · ⌘2 Watchlist · ⌘3 Portfolios · ⌘4 Settings · ⌘R Refresh · ⌘N New portfolio.
    private var keyboardShortcuts: some View {
        Group {
            Button("") { navigate(to: .home) }.keyboardShortcut("1", modifiers: .command)
            Button("") { navigate(to: .watchlist) }.keyboardShortcut("2", modifiers: .command)
            Button("") { navigate(to: .portfoliosAll) }.keyboardShortcut("3", modifiers: .command)
            Button("") { navigate(to: .settings) }.keyboardShortcut("4", modifiers: .command)
            Button("") { navigate(to: .aiReview) }.keyboardShortcut("5", modifiers: .command)
            Button("") {
                Task { await stockService.refreshAll(storageService: storageService) }
            }.keyboardShortcut("r", modifiers: .command)
            Button("") { showNewPortfolioAlert = true }.keyboardShortcut("n", modifiers: .command)
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
            Divider().overlay(DS.hairline)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    watchlistsHeader
                    ForEach(displayedWatchlists) { wl in
                        ReorderRow(
                            id: wl.id,
                            draggingId: $draggingWatchlistId,
                            isHorizontal: false,
                            makeDragItem: {
                                if previewWatchlistIds.isEmpty { previewWatchlistIds = storageService.watchlists.map(\.id) }
                                return NSItemProvider(object: wl.id.uuidString as NSString)
                            },
                            onMove: { srcId, tgtId, placement in
                                moveWatchlistInPreview(srcId, relativeTo: tgtId, placement: placement)
                            },
                            onCommit: { commitWatchlistPreview() }
                        ) {
                            NavRow(icon: "star", title: wl.name,
                                   trailing: "\(wl.symbols.count)",
                                   trailingTint: DS.inkTertiary,
                                   helpText: "Open “\(wl.name)” watchlist · Drag to reorder",
                                   selected: selection == .watchlist && storageService.selectedWatchlistId == wl.id,
                                   namespace: navNamespace) {
                                storageService.selectedWatchlistId = wl.id
                                navigate(to: .watchlist)
                            }
                            .contextMenu {
                                Button {
                                    storageService.selectedWatchlistId = wl.id
                                    showSearch = true
                                } label: {
                                    Label("Add Symbol…", systemImage: "plus")
                                }
                                Button { renamingWatchlist = wl; renameWatchlistName = wl.name } label: {
                                    Label("Rename Watchlist…", systemImage: "pencil")
                                }
                                if let idx = storageService.watchlists.firstIndex(where: { $0.id == wl.id }), idx > 0 {
                                    let prevId = storageService.watchlists[idx - 1].id
                                    Button { storageService.moveWatchlist(from: wl.id, beforeOrAfter: prevId) } label: {
                                        Label("Move Up", systemImage: "arrow.up")
                                    }
                                }
                                if let idx = storageService.watchlists.firstIndex(where: { $0.id == wl.id }), idx < storageService.watchlists.count - 1 {
                                    let nextId = storageService.watchlists[idx + 1].id
                                    Button { storageService.moveWatchlist(from: nextId, beforeOrAfter: wl.id) } label: {
                                        Label("Move Down", systemImage: "arrow.down")
                                    }
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
                    }

                    portfoliosHeader
                    NavRow(icon: "square.grid.2x2", title: "All Portfolios",
                           trailing: trailingPercent(for: storageService.portfolios),
                           trailingTint: DS.pnlColor(aggregatePnlPercent(for: storageService.portfolios)),
                           helpText: "Combined view of every portfolio  ⌘3",
                           selected: selection == .portfoliosAll, namespace: navNamespace) { navigate(to: .portfoliosAll) }
                    ForEach(displayedPortfolios) { portfolio in
                        ReorderRow(
                            id: portfolio.id,
                            draggingId: $draggingPortfolioId,
                            isHorizontal: false,
                            makeDragItem: {
                                if previewPortfolioIds.isEmpty { previewPortfolioIds = storageService.portfolios.map(\.id) }
                                return NSItemProvider(object: portfolio.id.uuidString as NSString)
                            },
                            onMove: { srcId, tgtId, placement in
                                movePortfolioInPreview(srcId, relativeTo: tgtId, placement: placement)
                            },
                            onCommit: { commitPortfolioPreview() }
                        ) {
                            NavRow(icon: "briefcase", title: portfolio.name,
                                   trailing: trailingPercent(for: [portfolio]),
                                   trailingTint: DS.pnlColor(aggregatePnlPercent(for: [portfolio])),
                                   helpText: "Open “\(portfolio.name)” · Drag to reorder · right-click for rename, notifications",
                                   selected: selection == .portfolio(portfolio.id), namespace: navNamespace) {
                                navigate(to: .portfolio(portfolio.id))
                            }
                            .contextMenu {
                                Button { addHoldingTarget = AddHoldingTarget(portfolioId: portfolio.id, symbol: nil) } label: {
                                    Label("Add Holding…", systemImage: "plus")
                                }
                                Button { renameTarget = PortfolioRef(id: portfolio.id, name: portfolio.name) } label: {
                                    Label("Rename…", systemImage: "pencil")
                                }
                                Button { notifTarget = PortfolioRef(id: portfolio.id, name: portfolio.name) } label: {
                                    Label("Notifications…", systemImage: "bell")
                                }
                                if storageService.portfolios.count > 1 {
                                    Divider()
                                    if let idx = storageService.portfolios.firstIndex(where: { $0.id == portfolio.id }), idx > 0 {
                                        let prevId = storageService.portfolios[idx - 1].id
                                        Button { storageService.movePortfolio(from: portfolio.id, beforeOrAfter: prevId) } label: {
                                            Label("Move Up", systemImage: "arrow.up")
                                        }
                                    }
                                    if let idx = storageService.portfolios.firstIndex(where: { $0.id == portfolio.id }), idx < storageService.portfolios.count - 1 {
                                        let nextId = storageService.portfolios[idx + 1].id
                                        Button { storageService.movePortfolio(from: nextId, beforeOrAfter: portfolio.id) } label: {
                                            Label("Move Down", systemImage: "arrow.down")
                                        }
                                    }
                                }
                                Divider()
                                Button(role: .destructive) {
                                    deletePortfolioTarget = PortfolioRef(id: portfolio.id, name: portfolio.name)
                                } label: { Label("Delete Portfolio", systemImage: "trash") }
                            }
                        }
                    }

                    utilitiesHeader
                    NavRow(icon: "sparkles", title: "AI Review",
                           helpText: "Advise on your watchlists & portfolios with built-in context  ⌘5",
                           selected: selection == .aiReview, namespace: navNamespace) { navigate(to: .aiReview) }
                    NavRow(icon: "bell", title: "Alerts",
                           helpText: "Price alerts you've set on your watchlist symbols",
                           selected: selection == .alerts, namespace: navNamespace) { navigate(to: .alerts) }
                    NavRow(icon: "arrow.triangle.2.circlepath.icloud", title: "Import / Export", helpText: "iCloud Sync, import & export portfolios, watchlists, templates",
                           selected: selection == .importExport, namespace: navNamespace) { navigate(to: .importExport) }
                }
                .padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 12)
            }
            Divider().overlay(DS.hairline)
            VStack(alignment: .leading, spacing: 2) {
                NavRow(icon: "newspaper", title: "Home", helpText: "Financial news & AI market insights  ⌘1",
                       selected: selection == .home, namespace: navNamespace) { navigate(to: .home) }
                NavRow(icon: "gearshape", title: "Settings", helpText: "Preferences (shared with the menu bar)  ⌘4",
                       selected: selection == .settings, namespace: navNamespace) { navigate(to: .settings) }
            }
            .padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 6)
            TotalFooter(value: aggregateValue(for: storageService.portfolios),
                        cost: aggregateCost(for: storageService.portfolios),
                        pnl: totalPnlValue,
                        currency: storageService.preferredCurrency,
                        decimals: storageService.amountDecimals)
            quitRow
        }
        .background(DS.sidebarBG)
        .overlay(alignment: .trailing) { DS.hairline.frame(width: 1) }
    }

    /// The sidebar watchlists in order: the local drag preview while dragging,
    /// else the persisted order.
    private var displayedWatchlists: [Watchlist] {
        if draggingWatchlistId != nil, !previewWatchlistIds.isEmpty {
            let byId = Dictionary(uniqueKeysWithValues: storageService.watchlists.map { ($0.id, $0) })
            return previewWatchlistIds.compactMap { byId[$0] }
        }
        return storageService.watchlists
    }

    /// Live, local-only reorder of the sidebar watchlist preview while dragging.
    private func moveWatchlistInPreview(_ sourceId: UUID, relativeTo targetId: UUID, placement: InsertPlacement) {
        if previewWatchlistIds.isEmpty { previewWatchlistIds = storageService.watchlists.map(\.id) }
        guard sourceId != targetId,
              let srcIndex = previewWatchlistIds.firstIndex(of: sourceId),
              let tgtIndex = previewWatchlistIds.firstIndex(of: targetId) else { return }
        let item = previewWatchlistIds.remove(at: srcIndex)
        let newTargetIndex = previewWatchlistIds.firstIndex(of: targetId) ?? tgtIndex
        let insertIndex = placement == .before ? newTargetIndex : newTargetIndex + 1
        guard insertIndex >= 0, insertIndex <= previewWatchlistIds.count else { return }
        previewWatchlistIds.insert(item, at: insertIndex)
    }

    /// Persists the previewed sidebar watchlist order exactly once, on drop.
    private func commitWatchlistPreview() {
        guard !previewWatchlistIds.isEmpty else {
            draggingWatchlistId = nil
            return
        }
        let final = previewWatchlistIds
        previewWatchlistIds = []
        draggingWatchlistId = nil
        storageService.commitWatchlistOrder(final)
    }

    /// The sidebar portfolios in order: the local drag preview while dragging,
    /// else the persisted order.
    private var displayedPortfolios: [Portfolio] {
        if draggingPortfolioId != nil, !previewPortfolioIds.isEmpty {
            let byId = Dictionary(uniqueKeysWithValues: storageService.portfolios.map { ($0.id, $0) })
            return previewPortfolioIds.compactMap { byId[$0] }
        }
        return storageService.portfolios
    }

    /// Live, local-only reorder of the sidebar portfolio preview while dragging.
    private func movePortfolioInPreview(_ sourceId: UUID, relativeTo targetId: UUID, placement: InsertPlacement) {
        if previewPortfolioIds.isEmpty { previewPortfolioIds = storageService.portfolios.map(\.id) }
        guard sourceId != targetId,
              let srcIndex = previewPortfolioIds.firstIndex(of: sourceId),
              let tgtIndex = previewPortfolioIds.firstIndex(of: targetId) else { return }
        let item = previewPortfolioIds.remove(at: srcIndex)
        let newTargetIndex = previewPortfolioIds.firstIndex(of: targetId) ?? tgtIndex
        let insertIndex = placement == .before ? newTargetIndex : newTargetIndex + 1
        guard insertIndex >= 0, insertIndex <= previewPortfolioIds.count else { return }
        previewPortfolioIds.insert(item, at: insertIndex)
    }

    /// Persists the previewed sidebar portfolio order exactly once, on drop.
    private func commitPortfolioPreview() {
        guard !previewPortfolioIds.isEmpty else {
            draggingPortfolioId = nil
            return
        }
        let final = previewPortfolioIds
        previewPortfolioIds = []
        draggingPortfolioId = nil
        storageService.commitPortfolioOrder(final)
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
            HomeWideView(onOpenSettings: { navigate(to: .settings) })
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
        case .alerts:
            AlertsWideView()
        }
    }

    /// Sidebar navigation always exits a pushed portfolio detail first. Keeping
    /// this path explicit avoids SwiftUI retaining a stale HoldingDetailView when
    /// the user switches directly to a watchlist or another sidebar destination.
    private func navigate(to destination: Nav) {
        portfolioPath = NavigationPath()
        selection = destination
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

    private var totalPnlValue: Double {
        PortfolioValuation.totals(valued(storageService.portfolios)).pnl
    }

    private func aggregateValue(for portfolios: [Portfolio]) -> Double {
        PortfolioValuation.totals(valued(portfolios)).value
    }
    private func aggregateCost(for portfolios: [Portfolio]) -> Double {
        PortfolioValuation.totals(valued(portfolios)).cost
    }
    private func aggregatePnlPercent(for portfolios: [Portfolio]) -> Double {
        // Unify with every other surface: P&L = value − cost, where cost uses the
        // historical FX rate at purchase (same as the menu bar, popover, and overview).
        // Holdings without a known cost basis (e.g. Binance balances) contribute 0 P&L.
        let totals = PortfolioValuation.totals(valued(portfolios))
        return abs(totals.cost) >= 0.01 ? (totals.pnl / abs(totals.cost)) * 100 : 0
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
    let pnl: Double
    let currency: String
    var decimals: Int = 2

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
#endif

