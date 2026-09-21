import SwiftUI
import UniformTypeIdentifiers

/// Fully custom, desktop-grade watchlist: a hand-built sortable list (clickable
/// column headers, hover rows, right-click actions, Move Up/Down reorder) dressed
/// as a white card over the paper ground — no native `Table`.
struct WatchlistWideView: View {
    @EnvironmentObject var stockService: StockService
    @EnvironmentObject var storageService: StorageService
    @State private var viewModel = WatchlistViewModel()
    @Binding var showSearch: Bool

    typealias SortKey = WatchlistSortKey

    @State private var showNewWatchlistAlert = false
    @State private var newWatchlistName = ""
    @State private var renamingWatchlist: Watchlist? = nil
    @State private var renameWatchlistName = ""
    @State private var draggingWatchlistId: UUID? = nil
    private var sortKey: WatchlistSortKey {
        WatchlistSortKey.from(rawString: storageService.currentWatchlist.sortKey)
    }
    private var sortAsc: Bool {
        storageService.currentWatchlist.sortAsc ?? true
    }
    @State private var draggingSymbol: String? = nil
    /// The full set of symbols travelling during a drag. When the dragged row is
    /// part of a multi-selection this is the whole selection (TradingView-style
    /// group drag); otherwise just the single row.
    @State private var draggingSymbols: Set<String> = []
    /// Live display order of the watchlist tabs while dragging: no storage
    /// writes during the drag — the final order is committed once on drop.
    @State private var previewWatchlistIds: [UUID] = []
    /// Live display order while dragging: reordering only touches this local
    /// array (no storage writes / objectWillChange churn / task restarts), and
    /// the final order is committed once on drop.
    @State private var previewOrder: [String] = []
    /// Which row the drag hovers over and where the symbol would land (before/after).
    @State private var dropIndicator: DropIndicator<String>? = nil
    @State private var addToPortfolio: AddTarget?
    @State private var alertSymbol: AlertTarget?
    @State private var multiAlertSymbols: [String] = []
    @State private var showMetricCustomizer = false

    struct WatchRow: Identifiable {
        let id: String
        let order: Int
        let symbol: String
        let name: String
        let currency: String
        let isIndex: Bool            // indices have no currency unit
        let rate: Double             // price currency conversion rate
        let price: Double            // regular market price
        let extPrice: Double?        // pre/post-market price, if any
        let extChangePercent: Double? // pre/post-market % move vs regular close
        let extLabel: String         // "Pre" / "Post"
        let change: Double
        let changePercent: Double
        let oneMonthChangePercent: Double?
        let threeMonthChangePercent: Double?
        let sixMonthChangePercent: Double?
        let ytdChangePercent: Double?
        let oneYearChangePercent: Double?
        let twoYearChangePercent: Double?
        let threeYearChangePercent: Double?
        let fiveYearChangePercent: Double?
        let tenYearChangePercent: Double?
        let allTimeHigh: Double?
        let allTimeLow: Double?
        let fromAthPercent: Double?
        let fromAtlPercent: Double?
        let history: [PricePoint]
        let allTimeHistory: [PricePoint]
        let loaded: Bool
        let quote: StockQuote?
        let marketCap: Double?         // market cap in target currency for fair cross-currency sorting

        func metricValue(for metric: WatchlistMetric) -> Double? {
            switch metric {
            case .price:
                return price
            case .today:
                return changePercent
            case .todayChange:
                return change
            case .oneMonth:
                return oneMonthChangePercent
            case .threeMonths:
                return threeMonthChangePercent
            case .sixMonths:
                return sixMonthChangePercent
            case .ytd:
                return ytdChangePercent
            case .oneYear:
                return oneYearChangePercent
            case .twoYears:
                return twoYearChangePercent
            case .threeYears:
                return threeYearChangePercent
            case .fiveYears:
                return fiveYearChangePercent
            case .tenYears:
                return tenYearChangePercent
            case .ath:
                return allTimeHigh
            case .atl:
                return allTimeLow
            case .marketCap:
                return marketCap
            case .fromAth:
                return fromAthPercent
            case .fromAtl:
                return fromAtlPercent
            case .chart24h, .chart7d, .chart30d, .chart60d, .chart90d, .chartYtd, .chart1y:
                return nil
            }
        }
    }
    struct AddTarget: Identifiable { let symbol: String; let portfolioId: UUID; var id: String { "\(symbol)-\(portfolioId)" } }
    struct AlertTarget: Identifiable { let symbol: String; var id: String { symbol } }
    struct DetailTarget: Identifiable { let symbol: String; var id: String { symbol } }
    @State private var detailSymbol: DetailTarget?

    @State private var selectedSymbols: Set<String> = []
    @State private var activeDetailSymbol: String? = nil

    private var visibleRows: [WatchRow] {
        if draggingSymbol != nil && !previewOrder.isEmpty {
            let bySymbol = Dictionary(uniqueKeysWithValues: viewModel.rows.map { ($0.symbol, $0) })
            return previewOrder.compactMap { bySymbol[$0] }
        }
        return viewModel.visibleRows
    }

    private var selectedMetrics: [WatchlistMetric] { storageService.watchlistMetrics }

    /// True when any watchlist quote is trading pre/post-market. Drives the row
    /// hierarchy: during extended hours the After-hrs price/% reads first and the
    /// regular price dims to context; during regular hours it's the reverse.
    private var extendedSession: Bool {
        storageService.showExtendedHours &&
        storageService.watchlist.contains { stockService.quotes[$0]?.isExtendedHours == true }
    }

    private func toggleSort(_ key: WatchlistSortKey) {
        let currentKey = sortKey
        let currentAsc = sortAsc
        let newAsc: Bool
        if currentKey == key {
            newAsc = !currentAsc
        } else {
            newAsc = (key == .order || key == .symbol)
        }
        storageService.setWatchlistSort(key: key.rawString, ascending: newAsc, for: storageService.currentWatchlist.id)
    }

    var body: some View {
        PageScaffold(storageService.currentWatchlist.name) {
            if storageService.watchlist.isEmpty {
                emptyState
            } else {
                HStack(alignment: .top, spacing: 0) {
                    table
                        .frame(width: activeDetailSymbol != nil ? 350 : nil)
                        .frame(maxWidth: activeDetailSymbol != nil ? 350 : .infinity, maxHeight: .infinity)

                    if let sym = activeDetailSymbol, let q = stockService.quotes[sym] {
                        Divider().overlay(DS.hairline)
                        sideChartPane(symbol: sym, quote: q)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .premiumCard()
                .padding(.horizontal, DS.gutter)
                .padding(.bottom, DS.gutter)
                .frame(maxWidth: DS.contentMaxWidth + DS.gutter * 2)
            }
        }
        .navigationTitle(storageService.currentWatchlist.name)
        .task {
            viewModel.setup(stockService: stockService, storageService: storageService)
        }
        .task(id: Set(storageService.watchlist)) {
            // One batched spark request fills every row's sparkline.
            await stockService.ensureSparklines(for: storageService.watchlist)
        }
        .task(id: selectedMetrics) {
            guard selectedMetrics.contains(where: { $0.category == .price }) else { return }
            for symbol in storageService.watchlist where stockService.priceHistoryMax[symbol] == nil {
                await stockService.ensurePriceHistoryMax(for: symbol)
            }
        }
        .onAppear {
            if previewOrder.isEmpty { previewOrder = storageService.watchlist }
        }
        .onChange(of: storageService.watchlist) { _, newList in
            // Keep the preview in sync with outside changes (add/remove/switch) —
            // but never clobber an in-flight drag preview.
            if draggingSymbol == nil { previewOrder = newList }
        }
        .onChange(of: draggingSymbol) { _, newValue in
            if newValue == nil {
                draggingSymbols = []
                previewOrder = []
                dropIndicator = nil
            }
        }
        .onChange(of: draggingWatchlistId) { _, newValue in
            if newValue == nil { previewWatchlistIds = [] }
        }
        .onDrop(of: [.text], delegate: WatchlistListCommitDelegate(
            draggingSymbol: $draggingSymbol,
            onCommit: { commitPreviewOrder() }
        ))
        .sheet(item: $addToPortfolio) { t in
            HoldingFormSheet(mode: .addSymbol(symbol: t.symbol, portfolioId: t.portfolioId)) { addToPortfolio = nil }
                .environmentObject(stockService).environmentObject(storageService)
        }
        .sheet(item: $alertSymbol) { t in
            PriceAlertSheet(symbol: t.symbol) { alertSymbol = nil }
                .environmentObject(stockService).environmentObject(storageService)
        }
        .sheet(isPresented: Binding(
            get: { !multiAlertSymbols.isEmpty },
            set: { if !$0 { multiAlertSymbols = [] } }
        )) {
            if let first = multiAlertSymbols.first {
                PriceAlertSheet(symbol: first, suggestedSymbols: multiAlertSymbols) { multiAlertSymbols = [] }
                    .environmentObject(stockService).environmentObject(storageService)
            }
        }
        .sheet(isPresented: $showMetricCustomizer) {
            WatchlistMetricCustomizer(initialMetrics: selectedMetrics) {
                storageService.setWatchlistMetrics($0)
            }
        }
        .alert("New Watchlist", isPresented: $showNewWatchlistAlert) {
            TextField("Watchlist name", text: $newWatchlistName)
            Button("Cancel", role: .cancel) { }
            Button("Create") {
                storageService.createWatchlist(name: newWatchlistName)
            }
        } message: {
            Text("Enter a name for the new watchlist:")
        }
        .alert("Rename Watchlist", isPresented: Binding(
            get: { renamingWatchlist != nil },
            set: { if !$0 { renamingWatchlist = nil } }
        )) {
            TextField("Watchlist name", text: $renameWatchlistName)
            Button("Cancel", role: .cancel) { renamingWatchlist = nil }
            Button("Save") {
                if let wl = renamingWatchlist {
                    storageService.renameWatchlist(id: wl.id, newName: renameWatchlistName)
                    renamingWatchlist = nil
                }
            }
        } message: {
            Text("Enter a new name for this watchlist:")
        }
    }

    // MARK: - Side Chart Pane

    @ViewBuilder
    private func sideChartPane(symbol: String, quote: StockQuote) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                SymbolLogo(symbol: symbol, size: 36)
                let isJpFund = quote.isJapaneseFund || stockService.isJapaneseMutualFund(symbol)
                let isDisplayAsset = StockService.isDisplayNameAsset(symbol)
                let titleText = (isJpFund || isDisplayAsset) ? quote.displayName : symbol
                let subTitleText = isDisplayAsset ? symbol : (isJpFund ? "" : quote.name)
                VStack(alignment: .leading, spacing: 2) {
                    Text(titleText).font(DS.titleXL).tracking(-0.3).foregroundStyle(DS.ink).lineLimit(1)
                    if !subTitleText.isEmpty {
                        Text(subTitleText).font(DS.caption).foregroundStyle(DS.inkTertiary).lineLimit(1)
                    }
                }
                Spacer()
                if !storageService.portfolios.isEmpty {
                    DSMenu(width: 200, sections: [storageService.portfolios.map { p in
                        DSMenuAction(title: p.name, icon: "briefcase") {
                            addToPortfolio = AddTarget(symbol: symbol, portfolioId: p.id)
                        }
                    }]) {
                        HStack(spacing: 4) {
                            Image(systemName: "plus").font(.system(size: 10, weight: .bold))
                            Text("Portfolio").font(.inter(11.5, weight: .semibold, relativeTo: .caption))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Capsule().fill(DS.brand))
                    }
                    .pointingHandCursor()
                    .help("Add this stock as a position in a portfolio")
                }
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        activeDetailSymbol = nil
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(DS.inkSecondary)
                        .padding(6)
                        .background(Circle().fill(DS.cardAlt))
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                .help("Close chart")
            }
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)

            Divider().overlay(DS.hairline)

            ScrollView {
                VStack(spacing: DS.gap) {
                    PriceChartCard(symbol: symbol, quote: quote)
                    if storageService.show52WeekBar { fiftyTwoWeekCard(quote) }
                    factsCard(quote)
                    InsiderTradingCard(symbol: symbol)
                    SymbolNotesCard(storageService: storageService, symbol: symbol)
                    SymbolNewsCard(stockService: stockService, symbol: symbol)
                }
                .padding(16)
            }
        }
        .background(DS.ground)
    }

    @ViewBuilder private func fiftyTwoWeekCard(_ quote: StockQuote) -> some View {
        if let pos = quote.fiftyTwoWeekPosition,
           let low = quote.fiftyTwoWeekLow, let high = quote.fiftyTwoWeekHigh {
            let idxFlag = StorageService.isIndex(symbol: quote.symbol, type: storageService.type(for: quote.symbol))
            let priceSymbol = idxFlag ? "" : StorageService.currencySymbol(for: quote.currency)
            Card(title: "52-week range") {
                VStack(spacing: 10) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(DS.cardAlt).frame(height: 6)
                            Circle()
                                .fill(.white)
                                .frame(width: 10, height: 10)
                                .overlay(Circle().strokeBorder(DS.brand, lineWidth: 2))
                                .shadow(color: .black.opacity(0.10), radius: 2, y: 1)
                                .offset(x: CGFloat(pos) * (geo.size.width - 10))
                        }
                        .frame(maxHeight: .infinity, alignment: .center)
                    }
                    .frame(height: 16)
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            SectionLabel("Low")
                            Text(StorageService.formatAmount(low, symbol: priceSymbol))
                                .font(DS.figure).foregroundStyle(DS.ink)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            SectionLabel("High")
                            Text(StorageService.formatAmount(high, symbol: priceSymbol))
                                .font(DS.figure).foregroundStyle(DS.ink)
                        }
                    }
                }
            }
        }
    }

    private func factsCard(_ quote: StockQuote) -> some View {
        Card(title: "Today") {
            VStack(spacing: 0) {
                if let low = quote.dayLow, let high = quote.dayHigh {
                    factRow("Day range", "\(StorageService.formatNumber(low, decimals: 2)) – \(StorageService.formatNumber(high, decimals: 2))")
                    Divider().overlay(DS.hairline.opacity(0.6)).padding(.horizontal, 8)
                }
                factRow("Currency", quote.currency)
                if quote.isExtendedHours, !quote.marketStateLabel.isEmpty {
                    Divider().overlay(DS.hairline.opacity(0.6)).padding(.horizontal, 8)
                    factRow("Session", quote.marketStateLabel)
                }
            }
        }
    }

    private func factRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(LocalizedStringKey(label)).font(DS.caption).foregroundStyle(DS.inkSecondary)
            Spacer()
            Text(value).font(DS.figure).foregroundStyle(DS.ink)
        }
        .padding(.vertical, 8)
    }

    // MARK: - Header controls

    private var watchlistPickerBar: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(displayedWatchlists) { wl in
                        let selected = wl.id == storageService.currentWatchlist.id
                        ReorderRow(
                            id: wl.id,
                            draggingId: $draggingWatchlistId,
                            isHorizontal: true,
                            makeDragItem: {
                                if previewWatchlistIds.isEmpty { previewWatchlistIds = storageService.watchlists.map(\.id) }
                                return NSItemProvider(object: wl.id.uuidString as NSString)
                            },
                            onMove: { srcId, tgtId, placement in
                                moveWatchlistInPreview(srcId, relativeTo: tgtId, placement: placement)
                            },
                            onCommit: { commitWatchlistPreview() }
                        ) {
                            Button(action: {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    storageService.selectWatchlist(id: wl.id)
                                }
                            }) {
                                Text(wl.name)
                                    .font(DS.bodyStrong)
                                    .foregroundStyle(selected ? .white : DS.ink)
                                    .padding(.horizontal, 11)
                                    .padding(.vertical, 5)
                                    .background(
                                        Capsule()
                                            .fill(selected ? DS.brand : Color.primary.opacity(0.06))
                                    )
                            }
                            .buttonStyle(.plain)
                            .pointingHandCursor()
                            .id(wl.id)
                            .contextMenu {
                                Button("Rename…") {
                                    renamingWatchlist = wl
                                    renameWatchlistName = wl.name
                                }
                                if let idx = storageService.watchlists.firstIndex(where: { $0.id == wl.id }) {
                                    if idx > 0 {
                                        Button("Move Left") {
                                            let prevId = storageService.watchlists[idx - 1].id
                                            storageService.moveWatchlist(from: wl.id, beforeOrAfter: prevId)
                                        }
                                    }
                                    if idx < storageService.watchlists.count - 1 {
                                        Button("Move Right") {
                                            let nextId = storageService.watchlists[idx + 1].id
                                            storageService.moveWatchlist(from: nextId, beforeOrAfter: wl.id)
                                        }
                                    }
                                }
                                Divider()
                                Button("Delete Watchlist", role: .destructive) {
                                    storageService.deleteWatchlist(id: wl.id)
                                }
                            }
                        }
                    }

                    Button(action: {
                        newWatchlistName = ""
                        showNewWatchlistAlert = true
                    }) {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(DS.brand)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(DS.brand.opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                    .help("Create new watchlist")
                }
                .padding(.vertical, 2)
            }
            .frame(maxWidth: 320)
            .onChange(of: storageService.selectedWatchlistId) { _, newId in
                if let newId {
                    withAnimation { proxy.scrollTo(newId, anchor: .center) }
                }
            }
        }
    }

    private var addButton: some View {
        Button { showSearch = true } label: {
            HStack(spacing: 5) {
                Image(systemName: "plus").font(.system(size: 10, weight: .bold))
                Text("Add").font(.inter(12, weight: .semibold, relativeTo: .body))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 13).padding(.vertical, 6)
            .background(Capsule().fill(DS.brand))
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .help("Add a symbol to your watchlist")
    }

    // MARK: - Custom list

    private var table: some View {
        VStack(spacing: 0) {
            tableToolbar
            Divider().overlay(DS.hairline)
            if isCompact {
                tableContents
            } else {
                ScrollView(.horizontal, showsIndicators: true) {
                    tableContents
                        .frame(minWidth: tableWidth, alignment: .leading)
                }
                .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var tableWidth: CGFloat {
        let base = 22 + 24 + WCol.symbol + WCol.price
        let otherMetrics = selectedMetrics.filter { $0 != .price }
        let metricWidth = otherMetrics.reduce(CGFloat.zero) { $0 + WCol.width(for: $1) }
        let columns = 4 + otherMetrics.count
        return base + metricWidth + CGFloat(columns - 1) * WCol.spacing + 28
    }

    private var tableToolbar: some View {
        HStack(spacing: 8) {
            if selectedSymbols.isEmpty {
                Text("\(storageService.watchlist.count) symbols")
                    .font(DS.caption)
                    .foregroundStyle(DS.inkSecondary)
            } else {
                let countSet = selectedSymbols
                let count = countSet.sorted()
                HStack(spacing: 8) {
                    Text("\(count.count) selected")
                        .font(DS.caption)
                        .foregroundStyle(DS.ink)
                    Text("·").font(DS.caption).foregroundStyle(DS.inkTertiary)
                    Button {
                        multiAlertSymbols = count
                    } label: {
                        Text("Set alert (\(count.count))")
                            .font(.inter(11.5, weight: .semibold, relativeTo: .caption))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(DS.brand)
                    .pointingHandCursor()

                    Text("·").font(DS.caption).foregroundStyle(DS.inkTertiary)
                    Button {
                        storageService.removeMultipleFromWatchlist(countSet)
                        selectedSymbols.removeAll()
                    } label: {
                        Text("Remove (\(count.count))")
                            .font(.inter(11.5, weight: .semibold, relativeTo: .caption))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(DS.down)
                    .pointingHandCursor()

                    Text("·").font(DS.caption).foregroundStyle(DS.inkTertiary)
                    Button {
                        selectedSymbols.removeAll()
                    } label: {
                        Text("Clear")
                            .font(.inter(11.5, weight: .semibold, relativeTo: .caption))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(DS.inkSecondary)
                    .pointingHandCursor()
                }
            }

            Spacer()

            if !isCompact {
                Button {
                    PortfolioIO.exportWatchlists(storageService.watchlists, stockService: stockService, restoreActivationPolicy: false)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "square.and.arrow.up").font(.system(size: 11, weight: .medium))
                        Text("Export").font(DS.caption)
                    }
                    .foregroundStyle(DS.inkSecondary)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(DS.cardAlt))
                }
                .buttonStyle(.plain)
                .pointingHandCursor()

                Button { showMetricCustomizer = true } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "slider.horizontal.3").font(.system(size: 11, weight: .bold))
                        Text("Columns").font(.inter(12, weight: .semibold, relativeTo: .body))
                    }
                    .foregroundStyle(DS.brand)
                    .padding(.horizontal, 11).padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(DS.brand.opacity(0.12)))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(DS.brand.opacity(0.25), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                .help("Customize watchlist columns")

                addButton
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
    }

    private var tableContents: some View {
        VStack(spacing: 0) {
            headerRow
            Divider().overlay(DS.hairline)
            flatContents
        }
        .padding(.vertical, 6)
    }

    private var flatContents: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(visibleRows.enumerated()), id: \.element.id) { idx, row in
                    ReorderRow(
                        id: row.symbol,
                        draggingId: $draggingSymbol,
                        isHorizontal: false,
                        makeDragItem: {
                            previewOrder = storageService.watchlist
                            draggingSymbols = groupForDrag(row.symbol)
                            return NSItemProvider(object: row.symbol as NSString)
                        },
                        onMove: { src, tgt, placement in
                            if sortKey != .order || !sortAsc {
                                storageService.setWatchlistSort(key: WatchlistSortKey.order.rawString, ascending: true, for: storageService.currentWatchlist.id)
                            }
                            moveGroupInPreview(draggingSymbols.isEmpty ? [src] : draggingSymbols,
                                               beforeOrAfter: tgt, placement: placement)
                        },
                        onCommit: { commitPreviewOrder() },
                        dropIndicator: $dropIndicator
                    ) {
                        if draggingSymbols.contains(row.symbol) {
                            WatchRowView(row: row,
                                         position: idx + 1,
                                         showExtended: storageService.showExtendedHours,
                                         extendedSession: extendedSession,
                                         percentDecimals: storageService.percentDecimals,
                                         valueDecimals: storageService.valueDecimals,
                                         metrics: selectedMetrics,
                                         isSelected: selectedSymbols.contains(row.symbol),
                                         compact: isCompact,
                                         onOpen: {
                                             handleRowClick(row.symbol)
                                         },
                                         onToggleSelect: {
                                             toggleSelection(of: row.symbol)
                                         },
                                         menu: { rowMenu(row) })
                                .opacity(0)
                        } else {
                            WatchRowView(row: row,
                                         position: idx + 1,
                                         showExtended: storageService.showExtendedHours,
                                         extendedSession: extendedSession,
                                         percentDecimals: storageService.percentDecimals,
                                         valueDecimals: storageService.valueDecimals,
                                         metrics: selectedMetrics,
                                         isSelected: selectedSymbols.contains(row.symbol),
                                         compact: isCompact,
                                         onOpen: {
                                             handleRowClick(row.symbol)
                                         },
                                         onToggleSelect: {
                                             toggleSelection(of: row.symbol)
                                         },
                                         menu: { rowMenu(row) })
                        }
                    }
                    if idx < visibleRows.count - 1 {
                        Divider().overlay(DS.hairline.opacity(0.5)).padding(.leading, 14)
                    }
                }
                if !visibleRows.isEmpty {
                    Divider().overlay(DS.hairline.opacity(0.5)).padding(.leading, 14)
                }
            }
        }
    }

    private func handleRowClick(_ symbol: String) {
        // Selection is handled exclusively by the row checkboxes; clicking a row
        // only opens the detail chart.
        withAnimation(.easeInOut(duration: 0.2)) {
            activeDetailSymbol = symbol
        }
    }

    private func toggleSelection(of symbol: String) {
        if selectedSymbols.contains(symbol) {
            selectedSymbols.remove(symbol)
        } else {
            selectedSymbols.insert(symbol)
        }
    }

    private var isCompact: Bool { activeDetailSymbol != nil }

    /// The header checkbox: select or clear all watchlist rows.
    private var selectAllButton: some View {
        Image(systemName: selectAllIcon)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(!selectedSymbols.isEmpty ? DS.brand : DS.inkTertiary)
            .frame(width: 22, alignment: .leading)
            .contentShape(Rectangle())
            .highPriorityGesture(
                TapGesture().onEnded {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        if selectedSymbols.count == visibleRows.count && !visibleRows.isEmpty {
                            selectedSymbols.removeAll()
                        } else {
                            selectedSymbols = Set(visibleRows.map(\.symbol))
                        }
                    }
                }
            )
            .pointingHandCursor()
            .help(selectedSymbols.count == visibleRows.count && !visibleRows.isEmpty ? "Deselect all" : "Select all")
    }

    private var selectAllIcon: String {
        if selectedSymbols.isEmpty { return "square" }
        if selectedSymbols.count == visibleRows.count && !visibleRows.isEmpty { return "checkmark.square.fill" }
        return "minus.square.fill"
    }

    private var headerRow: some View {
        HStack(spacing: WCol.spacing) {
            // Frozen columns: select all + rank (#) + symbol + price
            HStack(spacing: WCol.spacing) {
                selectAllButton
                Text("#").font(DS.label).foregroundStyle(DS.inkTertiary).frame(width: 24, alignment: .leading)
                if isCompact {
                    headerCell("Symbol", .symbol, width: nil, align: .leading, help: "Sort by symbol")
                    headerCell("Price", .price, width: 96, align: .trailing, help: "Sort by price")
                } else {
                    headerCell("Symbol", .symbol, width: WCol.symbol, align: .leading, help: "Sort by symbol")
                    headerCell("Price", .price, width: WCol.price, align: .trailing, help: "Sort by price")
                }
            }
            .frame(maxWidth: isCompact ? .infinity : nil, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            if !isCompact {
                ForEach(selectedMetrics.filter { $0 != .price }) { metric in
                    metricHeader(metric)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 10)
        .textCase(.uppercase)
        .contextMenu {
            Button {
                showMetricCustomizer = true
            } label: {
                Label("Customize Columns…", systemImage: "slider.horizontal.3")
            }
            Divider()
            ForEach(WatchlistMetric.allCases.filter { $0 != .today && $0 != .price }) { metric in
                Button {
                    var updated = selectedMetrics
                    if updated.contains(metric) {
                        updated.removeAll { $0 == metric }
                    } else {
                        updated.append(metric)
                    }
                    storageService.setWatchlistMetrics(updated)
                } label: {
                    HStack {
                        if selectedMetrics.contains(metric) {
                            Image(systemName: "checkmark")
                        }
                        Text(metric.title)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func metricHeader(_ metric: WatchlistMetric) -> some View {
        if metric.isChart {
            Text(metric.title)
                .font(DS.label)
                .foregroundStyle(DS.inkTertiary)
                .frame(width: WCol.width(for: metric), alignment: .trailing)
        } else {
            headerCell(metric.title, .metric(metric), width: WCol.width(for: metric), align: .trailing,
                       help: LocalizedStringKey("Sort by \(metric.title)"))
        }
    }

    @ViewBuilder
    private func headerCell(_ title: String, _ key: SortKey, width: CGFloat?, align: Alignment,
                            help: LocalizedStringKey = "") -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) {
                toggleSort(key)
            }
        } label: {
            HStack(spacing: 3) {
                if align == .trailing { Spacer(minLength: 0) }
                Text(LocalizedStringKey(title))
                    .font(DS.label)
                    .foregroundStyle(sortKey == key ? DS.brand : DS.inkTertiary)
                if sortKey == key {
                    Image(systemName: sortAsc ? "chevron.up" : "chevron.down")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(DS.brand)
                }
                if align == .leading { Spacer(minLength: 0) }
            }
            .frame(width: width, alignment: align)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .contentShape(Rectangle())
        .frame(maxWidth: width == nil ? .infinity : nil, alignment: align)
        .help(help)
    }

    @ViewBuilder
    private func rowMenu(_ row: WatchRow) -> some View {
        let targets = selectedSymbols.contains(row.symbol) && selectedSymbols.count > 1 ? selectedSymbols : [row.symbol]
        let count = targets.count

        if count == 1 {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    activeDetailSymbol = row.symbol
                }
            } label: { Label("View Chart", systemImage: "chart.xyaxis.line") }
        }

        Menu {
            ForEach(storageService.watchlists) { wl in
                Button {
                    if count == 1 {
                        storageService.addToWatchlist(row.symbol, targetWatchlistId: wl.id)
                    } else {
                        storageService.addMultipleToWatchlist(targets, targetWatchlistId: wl.id)
                    }
                } label: {
                    if count == 1 && wl.symbols.contains(row.symbol) {
                        Label(wl.name, systemImage: "checkmark")
                    } else {
                        Text(wl.name)
                    }
                }
            }
        } label: {
            Label(count > 1 ? "Add \(count) symbols to Watchlist" : "Add to Watchlist", systemImage: "star.bubble")
        }

        let availPortfolios = storageService.portfolios
        if !availPortfolios.isEmpty {
            Menu {
                ForEach(availPortfolios, id: \.id) { (p: Portfolio) in
                    Button(p.name) {
                        if count == 1 {
                            addToPortfolio = AddTarget(symbol: row.symbol, portfolioId: p.id)
                        } else {
                            for s in targets {
                                storageService.addHolding(to: p.id, symbol: s, quantity: 1, avgPrice: stockService.quotes[s]?.price ?? 0)
                            }
                        }
                    }
                }
            } label: {
                Label(count > 1 ? "Add \(count) symbols to Portfolio" : "Add to Portfolio", systemImage: "plus.rectangle.on.folder")
            }
        }

        if count == 1 {
            Button { alertSymbol = AlertTarget(symbol: row.symbol) } label: { Label("Set Price Alert…", systemImage: "bell") }
            if let idx = storageService.watchlist.firstIndex(of: row.symbol) {
                Divider()
                Button { move(row.symbol, by: -1) } label: { Label("Move Up", systemImage: "arrow.up") }
                    .disabled(idx == 0)
                Button { move(row.symbol, by: 1) } label: { Label("Move Down", systemImage: "arrow.down") }
                    .disabled(idx == storageService.watchlist.count - 1)
            }
        }

        Divider()
        Button(role: .destructive) {
            if count == 1 {
                storageService.removeFromWatchlist(row.symbol)
            } else {
                storageService.removeMultipleFromWatchlist(targets)
                selectedSymbols.removeAll()
            }
            if let active = activeDetailSymbol, targets.contains(active) {
                activeDetailSymbol = nil
            }
        } label: {
            Label(count > 1 ? "Remove \(count) symbols from Watchlist" : "Remove from Watchlist", systemImage: "trash")
        }
    }

    /// Moves a symbol up/down in the manual watchlist order (persisted).
    private func move(_ symbol: String, by delta: Int) {
        if sortKey != .order || !sortAsc {
            storageService.setWatchlistSort(key: WatchlistSortKey.order.rawString, ascending: true, for: storageService.currentWatchlist.id)
        }
        guard let i = storageService.watchlist.firstIndex(of: symbol) else { return }
        let j = i + delta
        guard j >= 0, j < storageService.watchlist.count else { return }
        storageService.watchlist.swapAt(i, j)
    }

    /// The set of symbols that travel together when `symbol` is dragged.
    /// TradingView-style: if the row is part of a live multi-selection, the whole
    /// selection moves as one block; otherwise just that row.
    private func groupForDrag(_ symbol: String) -> Set<String> {
        if selectedSymbols.contains(symbol), selectedSymbols.count > 1 {
            return selectedSymbols
        }
        return [symbol]
    }

    /// Live, local-only reorder of the preview while dragging. Moves a whole
    /// group into a single contiguous block at the drop position, preserving the
    /// group's pre-drag relative order. No storage writes.
    private func moveGroupInPreview(_ group: Set<String>, beforeOrAfter targetSymbol: String, placement: InsertPlacement) {
        if previewOrder.isEmpty { previewOrder = storageService.watchlist }
        guard !group.contains(targetSymbol),
              let tgtIndex = previewOrder.firstIndex(of: targetSymbol) else { return }
        // Extract the group (in list order) and drop the target's old index so
        // the anchor stays correct after removal.
        let members = previewOrder.filter { group.contains($0) }
        let afterRemoval = previewOrder.filter { !group.contains($0) }
        let targetAfterRemoval = afterRemoval.firstIndex(of: targetSymbol) ?? tgtIndex
        let insertIndex = placement == .before ? targetAfterRemoval : targetAfterRemoval + 1
        guard insertIndex >= 0, insertIndex <= afterRemoval.count else { return }
        previewOrder = afterRemoval
        previewOrder.insert(contentsOf: members, at: insertIndex)
    }

    /// The watchlist tabs in order: the local drag preview while dragging, else the
    /// persisted order.
    private var displayedWatchlists: [Watchlist] {
        if draggingWatchlistId != nil, !previewWatchlistIds.isEmpty {
            let byId = Dictionary(uniqueKeysWithValues: storageService.watchlists.map { ($0.id, $0) })
            return previewWatchlistIds.compactMap { byId[$0] }
        }
        return storageService.watchlists
    }

    /// Live, local-only reorder of the watchlist tab preview while dragging.
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

    /// Persists the previewed watchlist order exactly once, when the tab drop
    /// lands (or the drag ends outside the picker bar).
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

    /// Commits the previewed order to storage exactly once, when the drop lands.
    private func commitPreviewOrder() {
        guard !previewOrder.isEmpty else { return }
        let final = previewOrder
        previewOrder = []
        dropIndicator = nil
        draggingSymbol = nil
        if final != storageService.watchlist {
            storageService.watchlist = final
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "star").font(.system(size: 34)).foregroundStyle(DS.inkTertiary)
            Text("No stocks in your watchlist").font(DS.bodyStrong).foregroundStyle(DS.inkSecondary)
            addButton
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Shared column widths so the header lines up with every row.
/// File-scope `private` = visible to both `WatchlistWideView` and `WatchRowView`.
private enum WCol {
    static let symbol: CGFloat = 180
    static let price: CGFloat = 116
    static let period: CGFloat = 68
    static let trend: CGFloat = 56
    static let range: CGFloat = 100
    static let spacing: CGFloat = 12

    static func width(for metric: WatchlistMetric) -> CGFloat {
        switch metric {
        case .price: return price
        case .today, .todayChange: return 82
        default: return metric.isChart ? 76 : (metric.category == .price ? 92 : period)
        }
    }
}

/// One custom watchlist row: hover tint, click-to-open, right-click actions.
private struct WatchRowView<Menu: View>: View {
    @EnvironmentObject private var storageService: StorageService
    let row: WatchlistWideView.WatchRow
    let position: Int
    let showExtended: Bool
    let extendedSession: Bool
    let percentDecimals: Int
    let valueDecimals: Int
    let metrics: [WatchlistMetric]
    let isSelected: Bool
    var compact: Bool = false
    let onOpen: () -> Void
    var onToggleSelect: () -> Void = {}
    @ViewBuilder let menu: () -> Menu
    @State private var hover = false

    /// Price decimals honoring the manual override (Auto = smart per #10).
    private func priceDec(_ price: Double) -> Int {
        valueDecimals >= 0 ? valueDecimals : StorageService.priceDecimals(symbol: row.symbol, price: price)
    }

    @ViewBuilder
    private var priceCell: some View {
        let dec = priceDec(row.price)
        let formattedChange = StorageService.formatNumber(row.change, decimals: dec, stripTrailingZeros: true)
        VStack(alignment: .trailing, spacing: 2) {
            Text("\(StorageService.formatNumber(row.price, decimals: dec))")
                .font(DS.figure)
                .foregroundStyle(DS.ink)
                .lineLimit(1)
            Text((row.change >= 0 ? "+" : "") + formattedChange)
                .font(DS.micro)
                .fontWeight(.semibold)
                .foregroundStyle(DS.pnlColor(row.change))
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private var todayPercentCell: some View {
        if row.loaded {
            let isCrypto = storageService.type(for: row.symbol) == "CRYPTOCURRENCY" || HomeAIInsightService.cryptoBaseAsset(for: row.symbol) != nil
            let isMarketActive = MarketCategory.isTradingDay(symbol: row.symbol, quote: row.quote, isCrypto: isCrypto)
            let isSessionOpen = MarketCategory.isSessionOpen(symbol: row.symbol, quote: row.quote, isCrypto: isCrypto)

            VStack(alignment: .trailing, spacing: 2) {
                let pctColor = isMarketActive ? DS.pnlColor(row.changePercent) : DS.inkTertiary
                Text(String(format: "%+.\(percentDecimals)f%%", row.changePercent))
                    .font(DS.figure.monospacedDigit())
                    .fontWeight(.medium)
                    .foregroundStyle(pctColor)
                    .lineLimit(1)
                if showExtended, let q = row.quote, q.isExtendedHours, let extPct = q.extendedChangePercent {
                    let isPre = q.marketState.hasPrefix("PRE")
                    HStack(spacing: 2) {
                        Image(systemName: isPre ? "sun.max.fill" : "moon.fill")
                            .font(.system(size: 9))
                        Text(String(format: "%+.\(percentDecimals)f%%", extPct))
                            .font(DS.micro)
                            .fontWeight(.semibold)
                    }
                    .foregroundStyle(DS.pnlColor(extPct))
                    .lineLimit(1)
                } else if !isSessionOpen {
                    HStack(spacing: 2) {
                        Image(systemName: "moon.fill")
                            .font(.system(size: 8))
                        Text("Closed")
                            .font(DS.micro)
                            .fontWeight(.semibold)
                    }
                    .foregroundStyle(DS.inkTertiary)
                    .lineLimit(1)
                }
            }
        } else {
            Text("—").font(DS.figure).foregroundStyle(DS.inkTertiary)
        }
    }

    @ViewBuilder
    private func periodCell(_ percent: Double?) -> some View {
        if let percent {
            Text(String(format: "%+.\(percentDecimals)f%%", percent))
                .font(DS.figure.monospacedDigit())
                .foregroundStyle(DS.pnlColor(percent))
        } else {
            Text("—").font(DS.figure).foregroundStyle(DS.inkTertiary)
        }
    }

    private func periodChange(_ metric: WatchlistMetric) -> Double? {
        row.metricValue(for: metric)
    }

    private func metricCell(_ metric: WatchlistMetric) -> some View {
        Group {
            switch metric {
            case .price:
                if row.loaded {
                    priceCell
                } else {
                    DSSpinner(size: 12)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            case .today, .todayChange:
                todayPercentCell
            case .oneMonth, .threeMonths, .sixMonths, .oneYear, .twoYears, .threeYears, .fiveYears, .tenYears, .ytd:
                periodCell(periodChange(metric))
            case .ath:
                priceMetric(row.allTimeHigh)
            case .atl:
                priceMetric(row.allTimeLow)
            case .fromAth:
                periodCell(row.fromAthPercent)
            case .fromAtl:
                periodCell(row.fromAtlPercent)
            case .marketCap:
                marketCapCell
            case .chart24h:
                Sparkline(symbol: row.symbol, days: 1)
            case .chart7d:
                Sparkline(symbol: row.symbol, days: 7)
            case .chart30d:
                Sparkline(symbol: row.symbol, days: 30)
            case .chart60d:
                Sparkline(symbol: row.symbol, days: 60)
            case .chart90d:
                Sparkline(symbol: row.symbol, days: 90)
            case .chartYtd:
                Sparkline(symbol: row.symbol, isYTD: true)
            case .chart1y:
                Sparkline(symbol: row.symbol, days: 365)
            }
        }
        .frame(width: WCol.width(for: metric), alignment: .trailing)
    }

    @ViewBuilder
    private var marketCapCell: some View {
        if let mc = row.quote?.marketCap, mc > 0 {
            Text(StorageService.formatMarketCap(mc, currency: row.currency))
                .font(DS.figure.monospacedDigit())
                .foregroundStyle(DS.ink)
        } else {
            Text("—").font(DS.figure).foregroundStyle(DS.inkTertiary)
        }
    }

    /// The absolute (signed) today's change, formatted like price (no currency
    /// symbol), e.g. "+1.23", stripping redundant trailing zeros.
    @ViewBuilder
    private var todayChangeCell: some View {
        if row.loaded {
            let dec = priceDec(row.price)
            let formatted = StorageService.formatNumber(row.change, decimals: dec, stripTrailingZeros: true)
            Text("\(row.change >= 0 ? "+" : "")\(formatted)")
                .font(DS.figure.monospacedDigit())
                .foregroundStyle(DS.pnlColor(row.change))
        } else {
            Text("—").font(DS.figure).foregroundStyle(DS.inkTertiary)
        }
    }

    @ViewBuilder
    private func priceMetric(_ value: Double?) -> some View {
        if let value {
            Text("\(StorageService.formatNumber(value, decimals: priceDec(value)))")
                .font(DS.figure.monospacedDigit()).foregroundStyle(DS.ink)
        } else {
            Text("—").font(DS.figure).foregroundStyle(DS.inkTertiary)
        }
    }

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: WCol.spacing) {
                // Frozen columns: position + symbol + price, with opaque background & zIndex
                HStack(spacing: WCol.spacing) {
                    // Checkbox: toggling selection must not open the detail pane,
                    // so it swallows the tap with a high-priority gesture.
                    Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(isSelected ? DS.brand : DS.inkTertiary)
                        .frame(width: 22, alignment: .leading)
                        .contentShape(Rectangle())
                        .highPriorityGesture(TapGesture().onEnded { onToggleSelect() })
                    Text("\(position)")
                        .font(DS.micro.monospacedDigit())
                        .foregroundStyle(DS.inkTertiary)
                        .frame(width: 24, alignment: .leading)

                    let isJpFund = (row.quote?.isJapaneseFund == true) || (StockService.codeToFundNameMap[row.symbol] != nil)
                    let isDisplayAsset = StockService.isDisplayNameAsset(row.symbol)
                    let titleText = (isJpFund || isDisplayAsset) ? (row.quote?.displayName ?? StockService.beautifiedSymbol(row.symbol)) : row.symbol
                    let subTitleText = isDisplayAsset ? row.symbol : (isJpFund ? "" : row.name)
                    HStack(spacing: 9) {
                        SymbolLogo(symbol: row.symbol, size: 28)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(titleText)
                                .font(DS.figure)
                                .foregroundStyle(DS.ink)
                                .lineLimit(1)
                            if !subTitleText.isEmpty {
                                Text(subTitleText)
                                    .font(DS.micro)
                                    .foregroundStyle(DS.inkTertiary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .frame(maxWidth: compact ? .infinity : nil, alignment: .leading)
                    .frame(width: compact ? nil : WCol.symbol, alignment: .leading)

                    if compact {
                        if row.loaded {
                            priceCell
                                .frame(width: 96, alignment: .trailing)
                        } else {
                            DSSpinner(size: 12)
                                .frame(width: 96, alignment: .center)
                        }
                    } else {
                        metricCell(.price)
                    }
                }
                .frame(maxWidth: compact ? .infinity : nil, alignment: .leading)
                .padding(.horizontal, 14).padding(.vertical, 9)
                .frame(minHeight: 44)

                if !compact {
                    ForEach(metrics.filter { $0 != .price }) { metric in
                        metricCell(metric)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 9)
            .background(hover ? DS.cardAlt.opacity(0.6) : Color.clear)
            .contentShape(Rectangle())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .buttonStyle(.plain)
        .pointingHandCursor()
        .onHover { hover = $0 }
        .contextMenu { menu() }
    }
}

/// Top-level fallback so a drop anywhere in the watchlist page (between rows,
/// below the last row, on the toolbar) still commits the drag preview once.
private struct WatchlistListCommitDelegate: DropDelegate {
    @Binding var draggingSymbol: String?
    let onCommit: () -> Void

    func performDrop(info: DropInfo) -> Bool {
        onCommit()
        draggingSymbol = nil
        return true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }
}

