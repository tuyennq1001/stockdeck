import SwiftUI

private enum WatchlistCol {
    static let symbol: CGFloat = 124
    static let price: CGFloat = 82
    static let change: CGFloat = 82
    static let period: CGFloat = 72
    static let buyTarget: CGFloat = 96
    static let marketCap: CGFloat = 88
    static let chart: CGFloat = 76
    static let valuation: CGFloat = 72
    static let pinnedWidth: CGFloat = 148
    static let headerHeight: CGFloat = 28
    static let rowHeight: CGFloat = 38

    static func width(for metric: WatchlistMetric) -> CGFloat {
        switch metric {
        case .price: return price
        case .today, .todayChange: return change
        case .buyTarget: return buyTarget
        case .marketCap, .ath, .atl: return marketCap
        case .pe, .forwardPe, .pb, .divYield, .eps: return valuation
        default: return metric.isChart ? chart : period
        }
    }
}

private struct WatchlistLaneEntry<Content: View>: View {
    let content: Content
    let leadingSeparatorInset: CGFloat
    let trailingSeparatorInset: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            content.frame(height: WatchlistCol.rowHeight)
            Rectangle()
                .fill(DS.hairline)
                .frame(height: 1)
                .padding(.leading, leadingSeparatorInset)
                .padding(.trailing, trailingSeparatorInset)
        }
        .frame(height: WatchlistCol.rowHeight + 1)
    }
}

private struct WatchlistSplitTable<FrozenHeader: View, MetricsHeader: View, FrozenRow: View, MetricsRow: View>: View {
    let watchlistID: UUID
    let symbols: [String]
    let contentReady: Bool
    let metricsTableWidth: CGFloat
    let draggingSymbol: Binding<String?>
    let dropIndicator: Binding<DropIndicator<String>?>
    let frozenHeader: () -> FrozenHeader
    let metricsHeader: () -> MetricsHeader
    let frozenRow: (String, RowHoverBox) -> FrozenRow
    let metricsRow: (String, RowHoverBox) -> MetricsRow
    let makeDragItem: (String) -> NSItemProvider
    let onMove: (String, String, InsertPlacement) -> Void
    let onRefresh: () async -> Void

    @StateObject private var scrollCoordinator: ScrollSyncCoordinator

    init(
        watchlistID: UUID,
        symbols: [String],
        contentReady: Bool,
        metricsTableWidth: CGFloat,
        draggingSymbol: Binding<String?>,
        dropIndicator: Binding<DropIndicator<String>?>,
        @ViewBuilder frozenHeader: @escaping () -> FrozenHeader,
        @ViewBuilder metricsHeader: @escaping () -> MetricsHeader,
        @ViewBuilder frozenRow: @escaping (String, RowHoverBox) -> FrozenRow,
        @ViewBuilder metricsRow: @escaping (String, RowHoverBox) -> MetricsRow,
        makeDragItem: @escaping (String) -> NSItemProvider,
        onMove: @escaping (String, String, InsertPlacement) -> Void,
        onRefresh: @escaping () async -> Void
    ) {
        self.watchlistID = watchlistID
        self.symbols = symbols
        self.contentReady = contentReady
        self.metricsTableWidth = metricsTableWidth
        self.draggingSymbol = draggingSymbol
        self.dropIndicator = dropIndicator
        self.frozenHeader = frozenHeader
        self.metricsHeader = metricsHeader
        self.frozenRow = frozenRow
        self.metricsRow = metricsRow
        self.makeDragItem = makeDragItem
        self.onMove = onMove
        self.onRefresh = onRefresh
        _scrollCoordinator = StateObject(wrappedValue: ScrollSyncCoordinator(watchlistID: watchlistID))
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                frozenHeader()
                Divider().overlay(DS.hairline)
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 0) {
                        ForEach(symbols, id: \.self) { symbol in
                            ReorderRow(
                                id: symbol,
                                draggingId: draggingSymbol,
                                dropIndicator: dropIndicator,
                                isHorizontal: false,
                                attachDragToContent: false,
                                makeDragItem: { makeDragItem(symbol) },
                                onMove: onMove,
                                onCommit: {},
                                content: {
                                    WatchlistLaneEntry(
                                        content: frozenRow(symbol, scrollCoordinator.hoverBox(for: symbol)),
                                        leadingSeparatorInset: 12,
                                        trailingSeparatorInset: 0
                                    )
                                }
                            )
                        }
                    }
                    .padding(.vertical, 4)
                    .background(ScrollViewSyncAttachment(
                        onAttach: { scrollCoordinator.registerVerticalFrozen($0) },
                        onDetach: { scrollCoordinator.unregisterVerticalFrozen($0) }
                    ))
                }
                .frame(width: WatchlistCol.pinnedWidth)
            }
            .frame(width: WatchlistCol.pinnedWidth)
            .overlay(alignment: .trailing) {
                HStack(spacing: 0) {
                    Spacer()
                    Divider()
                }
            }
            .background(DS.card)

            VStack(spacing: 0) {
                ScrollView(.horizontal, showsIndicators: false) {
                    metricsHeader()
                        .frame(minWidth: metricsTableWidth, alignment: .leading)
                        .background(ScrollViewSyncAttachment(
                            onAttach: { scrollCoordinator.registerHorizontalHeader($0) },
                            onDetach: { scrollCoordinator.unregisterHorizontalHeader($0) }
                        ))
                }
                .frame(height: WatchlistCol.headerHeight)
                Divider().overlay(DS.hairline)
                ScrollView([.horizontal, .vertical], showsIndicators: true) {
                    LazyVStack(spacing: 0) {
                        ForEach(symbols, id: \.self) { symbol in
                            ReorderRow(
                                id: symbol,
                                draggingId: draggingSymbol,
                                dropIndicator: dropIndicator,
                                isHorizontal: false,
                                attachDragToContent: false,
                                makeDragItem: { makeDragItem(symbol) },
                                onMove: onMove,
                                onCommit: {},
                                content: {
                                    WatchlistLaneEntry(
                                        content: metricsRow(symbol, scrollCoordinator.hoverBox(for: symbol)),
                                        leadingSeparatorInset: 12,
                                        trailingSeparatorInset: 12
                                    )
                                }
                            )
                        }
                    }
                    .padding(.vertical, 4)
                    .frame(minWidth: metricsTableWidth, alignment: .leading)
                    .background(ScrollViewSyncAttachment(
                        onAttach: { scrollCoordinator.register2DBody($0) },
                        onDetach: { scrollCoordinator.unregister2DBody($0) }
                    ))
                }
                .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            }
        }
        .background(DS.card)
        .frame(maxHeight: .infinity)
        .refreshable { await onRefresh() }
        .onAppear {
            if contentReady { scrollCoordinator.watchlistContentDidLoad(scopeID: watchlistID) }
        }
        .onChange(of: contentReady) { _, ready in
            if ready { scrollCoordinator.watchlistContentDidLoad(scopeID: watchlistID) }
        }
        .onDisappear { scrollCoordinator.reset() }
    }
}


struct WatchlistView: View {
    @EnvironmentObject var stockService: StockService
    @EnvironmentObject var storageService: StorageService
    @Environment(\.showSymbolDetail) private var showSymbolDetail
    let viewModel: WatchlistViewModel
    @Binding var showSearch: Bool

    @State private var showNewWatchlistAlert = false
    @State private var newWatchlistName = ""
    @State private var renamingWatchlist: Watchlist? = nil
    @State private var renameWatchlistName = ""
    @State private var draggingSymbol: String? = nil
    @State private var dropIndicator: DropIndicator<String>? = nil
    @State private var addToPortfolio: (symbol: String, portfolioId: UUID)? = nil
    @State private var alertSymbol: String? = nil
    struct TargetSheetItem: Identifiable { let symbol: String; var id: String { symbol } }
    @State private var targetSymbol: TargetSheetItem? = nil
    @State private var alertTarget: TargetSheetItem? = nil
    @State private var confirmDeleteWatchlist: Watchlist? = nil

    private var selectedMetrics: [WatchlistMetric] {
        storageService.watchlistMetrics
    }

    private var metricsTableWidth: CGFloat {
        let otherMetrics = selectedMetrics.filter { $0 != .price }
        let metricWidth = otherMetrics.reduce(CGFloat.zero) { $0 + WatchlistCol.width(for: $1) }
        return WatchlistCol.price + metricWidth + 24
    }

    private var tableWidth: CGFloat {
        let base = WatchlistCol.symbol + WatchlistCol.price
        let otherMetrics = selectedMetrics.filter { $0 != .price }
        let metricWidth = otherMetrics.reduce(CGFloat.zero) { $0 + WatchlistCol.width(for: $1) }
        return max(462, base + metricWidth + 24)
    }

    private var currentSortKey: WatchlistSortKey {
        WatchlistSortKey.from(rawString: storageService.currentWatchlist.sortKey)
    }

    private var currentSortAsc: Bool {
        storageService.currentWatchlist.sortAsc ?? true
    }

    private func setSort(_ key: WatchlistSortKey, ascending: Bool) {
        storageService.setWatchlistSort(key: key.rawString, ascending: ascending, for: storageService.currentWatchlist.id)
    }

    private func toggleSort(_ key: WatchlistSortKey) {
        let newAsc: Bool
        if currentSortKey == key {
            newAsc = !currentSortAsc
        } else {
            newAsc = (key == .order || key == .symbol)
        }
        setSort(key, ascending: newAsc)
    }

    private var displaySymbols: [String] {
        viewModel.displaySymbols
    }

    private var tableSymbols: [String] {
        snapshotMatchesSelection ? displaySymbols : storageService.watchlist
    }

    private var snapshotMatchesSelection: Bool {
        !viewModel.snapshot.isLoading && viewModel.snapshot.scope == storageService.currentWatchlist.id
    }


    private var frozenHeaderRow: some View {
        HStack(spacing: 0) {
            sortHeader("Symbol", column: .symbol, align: .leading, leadingIndent: 25)
                .frame(width: WatchlistCol.symbol, alignment: .leading)
        }
        .font(.inter(10.5, weight: .semibold, relativeTo: .caption2))
        .foregroundColor(.secondary)
        .tracking(0.8)
        .textCase(.uppercase)
        .padding(.horizontal, 12)
        .frame(width: WatchlistCol.pinnedWidth, height: WatchlistCol.headerHeight, alignment: .leading)
    }

    private var metricsHeaderRow: some View {
        HStack(spacing: 0) {
            sortHeader("Price", column: .price, align: .trailing)
                .frame(width: WatchlistCol.price, alignment: .trailing)
            ForEach(selectedMetrics.filter { $0 != .price }) { metric in
                if metric.isChart {
                    Text(LocalizedStringKey(metric.title))
                        .frame(width: WatchlistCol.width(for: metric), alignment: .trailing)
                } else {
                    let sortK: WatchlistSortKey = (metric == .today || metric == .todayChange) ? .changePercent : .metric(metric)
                    sortHeader(LocalizedStringKey(metric.title), column: sortK, align: .trailing)
                        .frame(width: WatchlistCol.width(for: metric), alignment: .trailing)
                }
            }
        }
        .font(.inter(10.5, weight: .semibold, relativeTo: .caption2))
        .foregroundColor(.secondary)
        .tracking(0.8)
        .textCase(.uppercase)
        .padding(.horizontal, 12)
        .frame(height: WatchlistCol.headerHeight, alignment: .leading)
    }

    @ViewBuilder
    private func frozenRowContent(_ symbol: String, hoverBox: RowHoverBox) -> some View {
        let isDraggingThis = draggingSymbol == symbol
        if let row = viewModel.rowsBySymbol[symbol] {
            QuoteFrozenRow(
                row: row,
                showCompanyName: storageService.showCompanyName,
                valueDecimals: storageService.valueDecimals,
                hoverBox: hoverBox,
                isReordering: draggingSymbol != nil,
                onOpen: { showSymbolDetail.perform(row.symbol) },
                onStartDrag: { startDrag(for: symbol) },
                menu: { watchlistContextMenu(symbol: symbol) }
            )
            .opacity(isDraggingThis ? 0.35 : 1.0)
        } else {
            HStack(spacing: 5) {
                SymbolLogo(symbol: symbol, size: 20)
                VStack(alignment: .leading, spacing: 0) {
                    Text(StockService.beautifiedSymbol(symbol))
                        .font(.inter(12.5, relativeTo: .body).monospacedDigit())
                        .fontWeight(.bold)
                        .lineLimit(1)
                    if storageService.showCompanyName {
                        Text(" ")
                            .font(.inter(10, relativeTo: .caption2))
                            .lineLimit(1)
                    }
                }
            }
            .frame(width: WatchlistCol.symbol, alignment: .leading)
            .padding(.horizontal, 12)
            .frame(width: WatchlistCol.pinnedWidth, height: WatchlistCol.rowHeight, alignment: .leading)
            .background(hoverBox.isHovered ? DS.cardAlt.opacity(0.6) : Color.clear)
            .contentShape(Rectangle())
            .onTapGesture { showSymbolDetail.perform(symbol) }
            .pointingHandCursor()
            .onHover { hoverBox.isHovered = $0 }
            .contextMenu { watchlistContextMenu(symbol: symbol) }
            .opacity(isDraggingThis ? 0.35 : 1.0)
        }
    }

    @ViewBuilder
    private func metricsRowContent(_ symbol: String, hoverBox: RowHoverBox) -> some View {
        let isDraggingThis = draggingSymbol == symbol
        if let row = viewModel.rowsBySymbol[symbol] {
            QuoteMetricsRow(
                row: row,
                metrics: selectedMetrics,
                showExtendedHours: storageService.showExtendedHours,
                percentDecimals: storageService.percentDecimals,
                valueDecimals: storageService.valueDecimals,
                hoverBox: hoverBox,
                isReordering: draggingSymbol != nil,
                dropIndicator: nil,
                onOpen: { showSymbolDetail.perform(row.symbol) },
                menu: { watchlistContextMenu(symbol: symbol) }
            )
            .opacity(isDraggingThis ? 0.35 : 1.0)
        } else {
            HStack(spacing: 0) {
                ForEach([WatchlistMetric.price] + selectedMetrics.filter { $0 != .price }) { metric in
                    VStack(alignment: .trailing, spacing: 4) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(DS.hairline.opacity(0.7))
                            .frame(width: max(18, WatchlistCol.width(for: metric) * 0.42), height: 8)
                        RoundedRectangle(cornerRadius: 3)
                            .fill(DS.hairline.opacity(0.55))
                            .frame(width: max(12, WatchlistCol.width(for: metric) * 0.28), height: 6)
                    }
                    .frame(width: WatchlistCol.width(for: metric), alignment: .trailing)
                }
            }
            .padding(.horizontal, 12)
            .frame(
                minWidth: metricsTableWidth,
                maxWidth: .infinity,
                minHeight: WatchlistCol.rowHeight,
                maxHeight: WatchlistCol.rowHeight,
                alignment: .leading
            )
            .background(hoverBox.isHovered ? DS.cardAlt.opacity(0.6) : Color.clear)
            .contentShape(Rectangle())
            .onTapGesture { showSymbolDetail.perform(symbol) }
            .pointingHandCursor()
            .onHover { hoverBox.isHovered = $0 }
            .contextMenu { watchlistContextMenu(symbol: symbol) }
            .opacity(isDraggingThis ? 0.35 : 1.0)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            WatchlistTabPickerBar(
                storageService: storageService,
                onSelectWatchlist: { viewModel.selectWatchlist(id: $0) },
                onNewWatchlist: {
                    newWatchlistName = ""
                    showNewWatchlistAlert = true
                },
                onRename: { wl in
                    renamingWatchlist = wl
                    renameWatchlistName = wl.name
                },
                onDelete: { wl in
                    confirmDeleteWatchlist = wl
                }
            )

            Divider().overlay(DS.hairline)

            if storageService.watchlist.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "star")
                        .font(.inter(32, relativeTo: .largeTitle))
                        .foregroundColor(.secondary)
                    Text("No symbols in \(storageService.currentWatchlist.name)")
                        .foregroundColor(.secondary)
                    Button("Add symbol") {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showSearch = true
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .pointingHandCursor()
                    Spacer()
                }
            } else {
                WatchlistSplitTable(
                    watchlistID: storageService.currentWatchlist.id,
                    symbols: tableSymbols,
                    contentReady: snapshotMatchesSelection,
                    metricsTableWidth: metricsTableWidth,
                    draggingSymbol: $draggingSymbol,
                    dropIndicator: $dropIndicator,
                    frozenHeader: { frozenHeaderRow },
                    metricsHeader: { metricsHeaderRow },
                    frozenRow: { symbol, box in frozenRowContent(symbol, hoverBox: box) },
                    metricsRow: { symbol, box in metricsRowContent(symbol, hoverBox: box) },
                    makeDragItem: { startDrag(for: $0) },
                    onMove: { source, target, placement in
                        commitSymbolDrop(sourceSymbol: source, targetSymbol: target, placement: placement)
                    },
                    onRefresh: {
                        if storageService.iCloudSyncEnabled {
                            iCloudSyncService.shared.pullAndMerge(force: false)
                        }
                        await stockService.refreshAll(storageService: storageService)
                    }
                )
                .id(storageService.currentWatchlist.id)

                Divider().overlay(DS.hairline)

                HStack(spacing: 12) {
                    Button(action: {
                        newWatchlistName = ""
                        showNewWatchlistAlert = true
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "plus.circle.fill")
                            Text("Add Watchlist")
                        }
                        .font(.inter(10, relativeTo: .caption))
                    }
                    .buttonStyle(.borderless)
                    .pointingHandCursor()

                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showSearch = true
                        }
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "plus.circle.fill")
                            Text("Add Symbol")
                        }
                        .font(.inter(10, relativeTo: .caption))
                    }
                    .buttonStyle(.borderless)
                    .pointingHandCursor()

                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
        .sheet(item: Binding<AddToPortfolioItem?>(
                get: {
                    if let atp = addToPortfolio {
                        return AddToPortfolioItem(symbol: atp.symbol, portfolioId: atp.portfolioId)
                    }
                    return nil
                },
                set: { addToPortfolio = $0.map { ($0.symbol, $0.portfolioId) } }
            )) { item in
                QuickAddHoldingView(symbol: item.symbol, portfolioId: item.portfolioId) {
                    addToPortfolio = nil
                }
                .environmentObject(stockService)
                .environmentObject(storageService)
                .frame(width: 300, height: storageService.advancedPositions ? 290 : 220)
            }
            .sheet(item: $alertTarget) { item in
                PriceAlertSheet(symbol: item.symbol) { alertTarget = nil }
                    .environmentObject(stockService)
                    .environmentObject(storageService)
            }
            // In-popover overlay instead of `.sheet`: an attached sheet window on the
            // transient NSPopover loses key status after an app switch, which left the
            // popover unresponsive to clicks / right-clicks.
            .overlay {
                if let item = targetSymbol {
                    ZStack {
                        Color.black.opacity(0.25)
                            .contentShape(Rectangle())
                            .onTapGesture { targetSymbol = nil }
                        ScrollView(.vertical, showsIndicators: false) {
                            StockTargetSheet(symbol: item.symbol) { targetSymbol = nil }
                                .environmentObject(stockService)
                                .environmentObject(storageService)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                    }
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
            .alert("Delete Watchlist", isPresented: Binding(get: { confirmDeleteWatchlist != nil }, set: { if !$0 { confirmDeleteWatchlist = nil } })) {
                Button("Cancel", role: .cancel) { confirmDeleteWatchlist = nil }
                Button("Delete", role: .destructive) {
                    if let w = confirmDeleteWatchlist {
                        storageService.deleteWatchlist(id: w.id)
                    }
                    confirmDeleteWatchlist = nil
                }
            } message: {
                Text("Are you sure you want to delete watchlist '\(confirmDeleteWatchlist?.name ?? "")'?")
            }
            .onDrop(of: [.text], delegate: ReorderContainerDropDelegate(
                draggingId: $draggingSymbol,
                dropIndicator: $dropIndicator,
                onCommit: {}
            ))
            .cleanupDragSession(draggingId: $draggingSymbol, dropIndicator: $dropIndicator)
            .onAppear {
                viewModel.setup(stockService: stockService, storageService: storageService)
                Task {
                    await stockService.ensureSparklines(for: storageService.watchlist)
                }
            }
            .onDisappear {
                viewModel.setActive(false)
            }
            .onChange(of: storageService.selectedWatchlistId) { _, _ in
                Task {
                    await stockService.ensureSparklines(for: storageService.watchlist)
                }
            }
            .onChange(of: storageService.watchlists.map(\.id)) { _, watchlistIDs in
                WatchlistScrollPositionStore.shared.retain(watchlistIDs: Set(watchlistIDs))
            }
            .onChange(of: storageService.watchlist) { _, newWatchlist in
                Task {
                    await stockService.ensureSparklines(for: newWatchlist)
                }
            }
            .task(id: selectedMetrics) {
                guard selectedMetrics.contains(where: { $0.category == .price }) else { return }
                for symbol in storageService.watchlist where stockService.priceHistoryMax[symbol] == nil {
                    await stockService.ensurePriceHistoryMax(for: symbol)
                }
            }
            .overlay {
                if showSearch {
                    ZStack {
                        Color.black.opacity(0.4)
                            .ignoresSafeArea()
                            .contentShape(Rectangle())
                            .onTapGesture {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    showSearch = false
                                }
                            }

                        SearchView(mode: .watchlist, isPresented: $showSearch)
                            .frame(width: 370, height: 430)
                            .background(DS.ground)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .strokeBorder(DS.hairline.opacity(0.8), lineWidth: 1)
                            )
                            .shadow(color: .black.opacity(0.22), radius: 20, y: 10)
                            .transition(.scale(scale: 0.95).combined(with: .opacity))
                    }
                    .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: showSearch)
    }

    @ViewBuilder
    private func sortHeader(_ title: LocalizedStringKey, column: WatchlistSortKey, align: Alignment = .trailing, leadingIndent: CGFloat = 0) -> some View {
        Button(action: {
            toggleSort(column)
        }) {
            HStack(spacing: 2) {
                if align == .trailing { Spacer(minLength: 0) }
                Text(title)
                if currentSortKey == column {
                    Image(systemName: currentSortAsc ? "chevron.up" : "chevron.down")
                        .font(.inter(8, relativeTo: .caption2))
                }
                if align == .leading { Spacer(minLength: 0) }
            }
            .padding(.leading, leadingIndent)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
    }

    @ViewBuilder
    private func watchlistContextMenu(symbol: String) -> some View {
        Button {
            showSymbolDetail.perform(symbol)
        } label: {
            Label("View Details", systemImage: "chart.xyaxis.line")
        }
        Divider()

        Menu {
            ForEach(storageService.watchlists) { wl in
                Button {
                    storageService.addToWatchlist(symbol, targetWatchlistId: wl.id)
                } label: {
                    if wl.symbols.contains(symbol) {
                        Label(wl.name, systemImage: "checkmark")
                    } else {
                        Text(wl.name)
                    }
                }
            }
        } label: {
            Label("Add to Watchlist", systemImage: "star.bubble")
        }

        if !storageService.portfolios.isEmpty {
            Menu {
                ForEach(storageService.portfolios) { portfolio in
                    Button(portfolio.name) {
                        addToPortfolio = (symbol, portfolio.id)
                    }
                }
            } label: {
                Label("Add to Portfolio", systemImage: "plus.rectangle.on.folder")
            }
        }
        Divider()

        Button {
            alertTarget = TargetSheetItem(symbol: symbol)
        } label: {
            Label("Set Price Alert…", systemImage: "bell")
        }

        Button {
            targetSymbol = TargetSheetItem(symbol: symbol)
        } label: {
            Label(storageService.buyTarget(for: symbol) != nil ? LocalizedStringKey("Edit Buy Target…") : LocalizedStringKey("Set Buy Target…"), systemImage: "target")
        }
        if storageService.buyTarget(for: symbol) != nil {
            Button(role: .destructive) {
                storageService.removeBuyTarget(for: symbol)
            } label: {
                Label("Remove Buy Target", systemImage: "trash")
            }
        }
        if let idx = storageService.watchlist.firstIndex(of: symbol) {
            Divider()
            Button {
                if currentSortKey != .order || !currentSortAsc {
                    setSort(.order, ascending: true)
                }
                moveSymbolInWatchlist(symbol, by: -1)
            } label: {
                Label("Move Up", systemImage: "arrow.up")
            }
            .disabled(idx == 0)

            Button {
                if currentSortKey != .order || !currentSortAsc {
                    setSort(.order, ascending: true)
                }
                moveSymbolInWatchlist(symbol, by: 1)
            } label: {
                Label("Move Down", systemImage: "arrow.down")
            }
            .disabled(idx == storageService.watchlist.count - 1)
        }
        Divider()
        Button(role: .destructive) {
            storageService.removeFromWatchlist(symbol)
        } label: {
            Label("Remove from Watchlist", systemImage: "trash")
        }
    }

    private func moveSymbolInWatchlist(_ symbol: String, by delta: Int) {
        guard let i = storageService.watchlist.firstIndex(of: symbol) else { return }
        let j = i + delta
        guard j >= 0, j < storageService.watchlist.count else { return }
        storageService.watchlist.swapAt(i, j)
    }

    private func startDrag(for symbol: String) -> NSItemProvider {
        DispatchQueue.main.async {
            draggingSymbol = symbol
        }
        return NSItemProvider(object: symbol as NSString)
    }

    /// Commits the reordered symbol order once on drop without intermediate live-swapping.
    private func commitSymbolDrop(sourceSymbol: String, targetSymbol: String, placement: InsertPlacement) {
        guard sourceSymbol != targetSymbol else { return }
        let currentVisible = displaySymbols
        if let updated = storageService.moveWatchlistSymbols(
            [sourceSymbol],
            relativeTo: targetSymbol,
            placement: placement,
            in: currentVisible
        ) {
            viewModel.applyManualOrder(updated)
        }
    }

}

/// Isolated horizontal tab bar for Watchlist selection & drag-and-drop reordering in the popover.
/// Keeps drag hover / drop-indicator state isolated from the symbol rows table below.
private struct WatchlistTabPickerBar: View {
    @ObservedObject var storageService: StorageService
    let onSelectWatchlist: (UUID) -> Void
    let onNewWatchlist: () -> Void
    let onRename: (Watchlist) -> Void
    let onDelete: (Watchlist) -> Void

    @State private var draggingWatchlistId: UUID? = nil
    @State private var dropIndicator: DropIndicator<UUID>? = nil

    var body: some View {
        let watchlists = storageService.watchlists
        let canDrag = watchlists.count > 1
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(watchlists) { wl in
                        let selected = wl.id == storageService.currentWatchlist.id
                        ReorderRow(
                            id: wl.id,
                            draggingId: $draggingWatchlistId,
                            dropIndicator: $dropIndicator,
                            isHorizontal: true,
                            attachDragToContent: canDrag,
                            makeDragItem: {
                                DispatchQueue.main.async {
                                    draggingWatchlistId = wl.id
                                }
                                return NSItemProvider(object: wl.id.uuidString as NSString)
                            },
                            onMove: { srcId, tgtId, placement in
                                storageService.moveWatchlist(from: srcId, relativeTo: tgtId, placement: placement)
                            },
                            onCommit: {}
                        ) {
                            Text(wl.name)
                                .font(.inter(11.5, weight: selected ? .semibold : .medium, relativeTo: .caption))
                                .foregroundColor(selected ? .white : DS.ink)
                                .padding(.horizontal, 11)
                                .padding(.vertical, 5)
                                .background(
                                    Capsule()
                                        .fill(selected ? DS.brand : Color.primary.opacity(0.06))
                                )
                                .contentShape(Capsule())
                                .onTapGesture {
                                    onSelectWatchlist(wl.id)
                                }
                                .accessibilityAddTraits(.isButton)
                                .pointingHandCursor()
                                .padding(.horizontal, 3)
                                .animation(.easeInOut(duration: 0.15), value: selected)
                                .id(wl.id)
                                .help("Select “\(wl.name)” · Drag to reorder")
                                .contextMenu {
                                    Button("Rename…") {
                                        onRename(wl)
                                    }
                                    if let idx = watchlists.firstIndex(where: { $0.id == wl.id }) {
                                        if idx > 0 {
                                            Button("Move Left") {
                                                let prevId = watchlists[idx - 1].id
                                                storageService.moveWatchlist(from: wl.id, beforeOrAfter: prevId)
                                            }
                                        }
                                        if idx < watchlists.count - 1 {
                                            Button("Move Right") {
                                                let nextId = watchlists[idx + 1].id
                                                storageService.moveWatchlist(from: nextId, beforeOrAfter: wl.id)
                                            }
                                        }
                                    }
                                    if watchlists.count > 1 {
                                        Divider()
                                        Button("Delete Watchlist", role: .destructive) {
                                            onDelete(wl)
                                        }
                                    }
                                }
                        }
                    }

                    Button(action: onNewWatchlist) {
                        Image(systemName: "plus")
                            .font(.inter(10, weight: .bold, relativeTo: .caption))
                            .foregroundColor(DS.brand)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(DS.brand.opacity(0.12)))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                    .padding(.leading, 3)
                    .help("New watchlist")
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 6)
                .onDrop(of: [.text], delegate: ReorderContainerDropDelegate(
                    draggingId: $draggingWatchlistId,
                    dropIndicator: $dropIndicator,
                    onMove: { srcId, tgtId, placement in
                        storageService.moveWatchlist(from: srcId, relativeTo: tgtId, placement: placement)
                    }
                ))
            }
            .cleanupDragSession(draggingId: $draggingWatchlistId, dropIndicator: $dropIndicator)
            .onAppear {
                DispatchQueue.main.async {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        proxy.scrollTo(storageService.currentWatchlist.id, anchor: .center)
                    }
                }
            }
            .onChange(of: storageService.currentWatchlist.id) { _, newId in
                DispatchQueue.main.async {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        proxy.scrollTo(newId, anchor: .center)
                    }
                }
            }
        }
    }
}

private struct AddToPortfolioItem: Identifiable {
    let symbol: String
    let portfolioId: UUID
    var id: String { "\(symbol)-\(portfolioId)" }
}

private struct AlertSheetItem: Identifiable {
    let symbol: String
    var id: String { symbol }
}

struct QuickAddHoldingView: View {
    @EnvironmentObject var stockService: StockService
    @EnvironmentObject var storageService: StorageService

    let symbol: String
    let portfolioId: UUID
    let onDismiss: () -> Void

    @State private var quantityText = ""
    @State private var avgPriceText = ""
    @State private var leverageText = ""
    @State private var isShort = false
    @State private var purchaseDate = Date()

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Add \(symbol)")
                    .font(.inter(13, weight: .bold, relativeTo: .headline))
                Spacer()
                Button("Cancel") { onDismiss() }
                    .buttonStyle(.borderless)
            }

            if storageService.advancedPositions {
                VStack(alignment: .leading) {
                    Text("Position").font(.inter(10, relativeTo: .caption)).foregroundColor(.secondary)
                    Picker("Position", selection: $isShort) {
                        Text("Long").tag(false)
                        Text("Short").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
            }

            HStack(spacing: 12) {
                VStack(alignment: .leading) {
                    Text("Quantity").font(.inter(10, relativeTo: .caption)).foregroundColor(.secondary)
                    TextField("0", text: $quantityText)
                        .textFieldStyle(.roundedBorder)
                }
                VStack(alignment: .leading) {
                    Text("Avg cost").font(.inter(10, relativeTo: .caption)).foregroundColor(.secondary)
                    TextField("0.00", text: $avgPriceText)
                        .textFieldStyle(.roundedBorder)
                }
                if storageService.advancedPositions {
                    VStack(alignment: .leading) {
                        Text("Leverage").font(.inter(10, relativeTo: .caption)).foregroundColor(.secondary)
                        TextField("1\u{00D7}", text: $leverageText)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 56)
                    }
                }
            }

            VStack(alignment: .leading) {
                Text("Purchase date").font(.inter(10, relativeTo: .caption)).foregroundColor(.secondary)
                DatePicker("", selection: $purchaseDate, displayedComponents: .date)
                    .datePickerStyle(.compact)
                    .labelsHidden()
            }

            Spacer()

            Button("Add") {
                guard let qty = Double(quantityText.replacingOccurrences(of: ",", with: ".")),
                      let price = Double(avgPriceText.replacingOccurrences(of: ",", with: ".")),
                      abs(qty) > 0, price > 0
                else { return }
                let advanced = storageService.advancedPositions
                let signedQty = (advanced && isShort) ? -abs(qty) : abs(qty)
                let leverage: Double? = {
                    guard advanced,
                          let l = Double(leverageText.replacingOccurrences(of: ",", with: ".")),
                          l > 0, l != 1
                    else { return nil }
                    return l
                }()
                storageService.addHolding(to: portfolioId, symbol: symbol, quantity: signedQty, avgPrice: price, purchaseDate: purchaseDate, leverage: leverage)
                Task { await stockService.refreshAll(storageService: storageService) }
                onDismiss()
            }
            .buttonStyle(.borderedProminent)
            .disabled(quantityText.isEmpty || avgPriceText.isEmpty)
        }
        .padding()
        .onAppear {
            // Pre-fill current price
            if let quote = stockService.quotes[symbol] {
                avgPriceText = String(format: "%.2f", quote.price)
            }
        }
    }
}

struct QuoteFrozenRow<Menu: View>: View {
    let row: WatchlistWideView.WatchRow
    let showCompanyName: Bool
    let valueDecimals: Int
    @ObservedObject var hoverBox: RowHoverBox
    var isReordering: Bool = false
    let onOpen: () -> Void
    var onStartDrag: (() -> NSItemProvider)? = nil
    @ViewBuilder let menu: () -> Menu

    private var dragPreviewBadge: some View {
        HStack(spacing: 6) {
            SymbolLogo(symbol: row.symbol, size: 18)
            let isDisplayAsset = StockService.isDisplayNameAsset(row.symbol)
            Text(isDisplayAsset ? (row.quote?.displayName ?? row.symbol) : StockService.displayTicker(for: row.symbol))
                .font(.inter(12, weight: .bold, relativeTo: .body))
                .foregroundStyle(DS.ink)
            let dec = valueDecimals >= 0 ? valueDecimals : StorageService.priceDecimals(symbol: row.symbol, price: row.price)
            Text(StorageService.formatCompactNumber(row.price, decimals: dec))
                .font(.inter(11, relativeTo: .body).monospacedDigit())
                .foregroundStyle(DS.inkSecondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(DS.ground)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(DS.brand.opacity(0.6), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.2), radius: 6, y: 3)
    }

    private var symbolLogoOrHandle: some View {
        ZStack {
            SymbolLogo(symbol: row.symbol, size: 20)
                .opacity(hoverBox.isHovered ? 0 : 1)
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(DS.inkSecondary)
                .opacity(hoverBox.isHovered ? 1 : 0)
        }
        .frame(width: 20, height: 20)
        .animation(.easeInOut(duration: 0.15), value: hoverBox.isHovered)
        .contentShape(Rectangle())
        .onDrag({
            onStartDrag?() ?? NSItemProvider(object: row.symbol as NSString)
        }, preview: {
            dragPreviewBadge
        })
        .dragHandleCursor()
        .help("Drag to reorder")
    }

    private var macOSSymbolCell: some View {
        let isDisplayAsset = StockService.isDisplayNameAsset(row.symbol)
        let isBuyZone = row.isInBuyZone

        return HStack(spacing: 5) {
            symbolLogoOrHandle
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 3) {
                    Text(isDisplayAsset ? (row.quote?.displayName ?? row.symbol) : StockService.displayTicker(for: row.symbol))
                        .font(.inter(12.5, relativeTo: .body).monospacedDigit())
                        .fontWeight(.bold)
                        .lineLimit(1)
                    UpcomingEarningsBadge(symbol: row.symbol)
                    if isBuyZone {
                        Text("🎯 MUA")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(DS.up)
                            .padding(.horizontal, 3)
                            .padding(.vertical, 0.5)
                            .background(DS.up.opacity(0.15), in: RoundedRectangle(cornerRadius: 3))
                    }
                }
                if let target = row.buyTarget {
                    let currSym = row.currency.isEmpty ? "" : StorageService.currencySymbol(for: row.currency)
                    let dec = valueDecimals >= 0 ? valueDecimals : StorageService.priceDecimals(symbol: row.symbol, price: target.targetPrice)
                    let priceStr = StorageService.formatCompactNumber(target.targetPrice, decimals: dec, stripTrailingZeros: true)
                    if isBuyZone {
                        Text("🎯 \(currSym)\(priceStr)")
                            .font(.inter(10, relativeTo: .caption2).monospacedDigit())
                            .fontWeight(.medium)
                            .foregroundStyle(DS.up)
                            .lineLimit(1)
                    } else if let dist = row.toBuyTargetPercent {
                        Text(String(format: "🎯 %@%@ (%+.1f%%)", currSym, priceStr, dist))
                            .font(.inter(9.5, relativeTo: .caption2).monospacedDigit())
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    } else {
                        Text("🎯 \(currSym)\(priceStr)")
                            .font(.inter(10, relativeTo: .caption2).monospacedDigit())
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                } else if showCompanyName {
                    Text(isDisplayAsset ? row.symbol : row.name)
                        .font(.inter(10, relativeTo: .caption2))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .frame(width: WatchlistCol.symbol, alignment: .leading)
    }

    var body: some View {
        macOSSymbolCell
            .padding(.horizontal, 12)
            .frame(width: WatchlistCol.pinnedWidth, height: WatchlistCol.rowHeight, alignment: .leading)
            .background(hoverBox.isHovered && !isReordering ? DS.cardAlt.opacity(0.6) : Color.clear)
            .contentShape(Rectangle())
            .onTapGesture {
                onOpen()
            }
            .pointingHandCursor()
            .onHover { hoverBox.isHovered = $0 }
            .contextMenu { menu() }
    }
}

struct QuoteMetricsRow<Menu: View>: View {
    let row: WatchlistWideView.WatchRow
    let metrics: [WatchlistMetric]
    let showExtendedHours: Bool
    let percentDecimals: Int
    let valueDecimals: Int
    @ObservedObject var hoverBox: RowHoverBox
    var isReordering: Bool = false
    let dropIndicator: DropIndicator<String>?
    let onOpen: () -> Void
    @ViewBuilder let menu: () -> Menu

    private func priceDec(_ price: Double) -> Int {
        valueDecimals >= 0 ? valueDecimals : StorageService.priceDecimals(symbol: row.symbol, price: price)
    }

    private var macOSPriceCell: some View {
        let displayPrice = row.price
        let dec = valueDecimals >= 0 ? valueDecimals : StorageService.priceDecimals(symbol: row.symbol, price: displayPrice)
        let formattedChange = StorageService.formatCompactNumber(row.change, decimals: dec, stripTrailingZeros: true)

        return VStack(alignment: .trailing, spacing: 1) {
            Text(StorageService.formatCompactNumber(displayPrice, decimals: dec))
                .font(.inter(11.5, relativeTo: .body).monospacedDigit())
                .fontWeight(.medium)
            Text((row.change >= 0 ? "+" : "") + formattedChange)
                .font(.inter(10, relativeTo: .caption2).monospacedDigit())
                .fontWeight(.semibold)
                .foregroundColor(row.change >= 0 ? DS.up : DS.down)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
    }

    private var macOSChangeCell: some View {
        VStack(alignment: .trailing, spacing: 1) {
            let isMarketActive = MarketCategory.isTradingDay(symbol: row.symbol, quote: row.quote, isCrypto: row.isCrypto)
            let isSessionOpen = MarketCategory.isSessionOpen(symbol: row.symbol, quote: row.quote, isCrypto: row.isCrypto)

            let pctColor: Color = isMarketActive ? (row.changePercent >= 0 ? DS.up : DS.down) : DS.inkTertiary
            Text(String(format: "%+.\(percentDecimals)f%%", row.changePercent))
                .font(.inter(11.5, relativeTo: .body).monospacedDigit())
                .fontWeight(.medium)
                .foregroundColor(pctColor)
                .lineLimit(1)
                .minimumScaleFactor(0.85)

            if showExtendedHours, let q = row.quote, q.isExtendedHours, let extPct = q.extendedChangePercent {
                let isPre = q.marketState.hasPrefix("PRE")
                HStack(spacing: 1) {
                    Image(systemName: isPre ? "sun.max.fill" : "moon.fill")
                        .font(.system(size: 8, weight: .semibold))
                    Text(String(format: "%+.\(percentDecimals)f%%", extPct))
                        .font(.inter(10, relativeTo: .caption2).monospacedDigit())
                        .fontWeight(.semibold)
                }
                .foregroundColor(extPct >= 0 ? DS.up : DS.down)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            } else if !isSessionOpen {
                HStack(spacing: 1) {
                    Image(systemName: "moon.fill")
                        .font(.system(size: 7, weight: .semibold))
                    Text("Closed")
                        .font(.inter(10, relativeTo: .caption2).monospacedDigit())
                        .fontWeight(.semibold)
                }
                .foregroundColor(DS.inkTertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            }
        }
    }

    private func macOSPeriodCell(value: Double?, width: CGFloat) -> some View {
        Group {
            if let value {
                Text(String(format: "%+.\(percentDecimals)f%%", value))
                    .font(.inter(11.5, relativeTo: .body).monospacedDigit())
                    .fontWeight(.medium)
                    .foregroundColor(value >= 0 ? DS.up : DS.down)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            } else {
                Text("—")
                    .font(.inter(11.5, relativeTo: .body).monospacedDigit())
                    .fontWeight(.medium)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(width: width, alignment: .trailing)
    }

    @ViewBuilder
    private func macOSPriceMetricCell(value: Double?, width: CGFloat) -> some View {
        Group {
            if let value {
                let dec = priceDec(value)
                Text(StorageService.formatNumber(value, decimals: dec))
                    .font(.inter(11.5, relativeTo: .body).monospacedDigit())
                    .fontWeight(.medium)
                    .foregroundStyle(DS.ink)
                    .lineLimit(1)
            } else {
                Text("—")
                    .font(.inter(11.5, relativeTo: .body).monospacedDigit())
                    .fontWeight(.medium)
                    .foregroundColor(.secondary)
            }
        }
        .frame(width: width, alignment: .trailing)
    }

    @ViewBuilder
    private var macOSBuyTargetCell: some View {
        if let target = row.buyTarget {
            let currSym = row.isIndex ? "" : (row.currency.isEmpty ? "" : StorageService.currencySymbol(for: row.currency))
            let dec = priceDec(target.targetPrice)
            let formattedPrice = StorageService.formatNumber(target.targetPrice, decimals: dec, stripTrailingZeros: true)
            VStack(alignment: .trailing, spacing: 1) {
                Text("\(currSym)\(formattedPrice)")
                    .font(.inter(11.5, relativeTo: .body).monospacedDigit())
                    .fontWeight(.medium)
                    .foregroundStyle(DS.ink)
                    .lineLimit(1)
                if row.isInBuyZone {
                    Text("🎯 MUA")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(DS.up)
                        .padding(.horizontal, 3)
                        .padding(.vertical, 0.5)
                        .background(DS.up.opacity(0.12), in: RoundedRectangle(cornerRadius: 3))
                } else if let pct = row.toBuyTargetPercent {
                    Text(String(format: "%+.\(percentDecimals)f%%", pct))
                        .font(.inter(10, relativeTo: .caption2).monospacedDigit())
                        .fontWeight(.semibold)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
        } else {
            Text("—")
                .font(.inter(11.5, relativeTo: .body).monospacedDigit())
                .fontWeight(.medium)
                .foregroundColor(.secondary)
        }
    }

    @ViewBuilder
    private var macOSMarketCapCell: some View {
        if let mc = row.quote?.marketCap, mc > 0 {
            Text(StorageService.formatMarketCap(mc, currency: row.currency))
                .font(.inter(11.5, relativeTo: .body).monospacedDigit())
                .fontWeight(.medium)
                .foregroundStyle(DS.ink)
                .lineLimit(1)
        } else {
            Text("—")
                .font(.inter(11.5, relativeTo: .body).monospacedDigit())
                .fontWeight(.medium)
                .foregroundColor(.secondary)
        }
    }

    @ViewBuilder
    private func macOSValuationRatioCell(value: Double?) -> some View {
        if let value, value.isFinite, value > 0 {
            Text(StorageService.formatNumber(value, decimals: 2))
                .font(.inter(11.5, relativeTo: .body).monospacedDigit())
                .fontWeight(.medium)
                .foregroundStyle(DS.ink)
                .lineLimit(1)
                .frame(width: WatchlistCol.valuation, alignment: .trailing)
        } else {
            Text("—")
                .font(.inter(11.5, relativeTo: .body).monospacedDigit())
                .fontWeight(.medium)
                .foregroundColor(.secondary)
                .frame(width: WatchlistCol.valuation, alignment: .trailing)
        }
    }

    @ViewBuilder
    private func macOSValuationYieldCell(value: Double?) -> some View {
        if let value, value.isFinite, value >= 0 {
            Text("\(StorageService.formatNumber(value, decimals: 2))%")
                .font(.inter(11.5, relativeTo: .body).monospacedDigit())
                .fontWeight(.medium)
                .foregroundStyle(DS.ink)
                .lineLimit(1)
                .frame(width: WatchlistCol.valuation, alignment: .trailing)
        } else {
            Text("—")
                .font(.inter(11.5, relativeTo: .body).monospacedDigit())
                .fontWeight(.medium)
                .foregroundColor(.secondary)
                .frame(width: WatchlistCol.valuation, alignment: .trailing)
        }
    }

    @ViewBuilder
    private func macOSEpsCell(value: Double?) -> some View {
        if let value, value.isFinite {
            let sym = row.isIndex ? "" : StorageService.currencySymbol(for: row.currency)
            let dec = (row.currency == "VND" || row.currency == "JPY") ? 0 : 2
            Text(StorageService.formatAmount(value, symbol: sym, decimals: dec))
                .font(.inter(11.5, relativeTo: .body).monospacedDigit())
                .fontWeight(.medium)
                .foregroundStyle(DS.ink)
                .lineLimit(1)
                .frame(width: WatchlistCol.valuation, alignment: .trailing)
        } else {
            Text("—")
                .font(.inter(11.5, relativeTo: .body).monospacedDigit())
                .fontWeight(.medium)
                .foregroundColor(.secondary)
                .frame(width: WatchlistCol.valuation, alignment: .trailing)
        }
    }

    @ViewBuilder
    private func metricCell(_ metric: WatchlistMetric) -> some View {
        Group {
            switch metric {
            case .price:
                macOSPriceCell.frame(width: WatchlistCol.price, alignment: .trailing)
            case .today, .todayChange:
                macOSChangeCell.frame(width: WatchlistCol.change, alignment: .trailing)
            case .oneMonth, .threeMonths, .sixMonths, .oneYear, .twoYears, .threeYears, .fiveYears, .tenYears, .ytd:
                macOSPeriodCell(value: row.metricValue(for: metric), width: WatchlistCol.width(for: metric))
            case .ath:
                macOSPriceMetricCell(value: row.allTimeHigh, width: WatchlistCol.width(for: .ath))
            case .atl:
                macOSPriceMetricCell(value: row.allTimeLow, width: WatchlistCol.width(for: .atl))
            case .fromAth:
                macOSPeriodCell(value: row.fromAthPercent, width: WatchlistCol.width(for: .fromAth))
            case .fromAtl:
                macOSPeriodCell(value: row.fromAtlPercent, width: WatchlistCol.width(for: .fromAtl))
            case .buyTarget:
                macOSBuyTargetCell.frame(width: WatchlistCol.buyTarget, alignment: .trailing)
            case .marketCap:
                macOSMarketCapCell.frame(width: WatchlistCol.marketCap, alignment: .trailing)
            case .pe:
                macOSValuationRatioCell(value: row.quote?.trailingPE)
            case .forwardPe:
                macOSValuationRatioCell(value: row.quote?.forwardPE)
            case .pb:
                macOSValuationRatioCell(value: row.quote?.priceToBook)
            case .divYield:
                macOSValuationYieldCell(value: row.quote?.dividendYield)
            case .eps:
                macOSEpsCell(value: row.quote?.epsTrailingTwelveMonths)
            case .chart24h:
                Sparkline(symbol: row.symbol, days: 1)
                    .frame(width: WatchlistCol.chart, alignment: .trailing)
            case .chart7d:
                Sparkline(symbol: row.symbol, days: 7)
                    .frame(width: WatchlistCol.chart, alignment: .trailing)
            case .chart30d:
                Sparkline(symbol: row.symbol, days: 30)
                    .frame(width: WatchlistCol.chart, alignment: .trailing)
            case .chart60d:
                Sparkline(symbol: row.symbol, days: 60)
                    .frame(width: WatchlistCol.chart, alignment: .trailing)
            case .chart90d:
                Sparkline(symbol: row.symbol, days: 90)
                    .frame(width: WatchlistCol.chart, alignment: .trailing)
            case .chartYtd:
                Sparkline(symbol: row.symbol, isYTD: true)
                    .frame(width: WatchlistCol.chart, alignment: .trailing)
            case .chart1y:
                Sparkline(symbol: row.symbol, days: 365)
                    .frame(width: WatchlistCol.chart, alignment: .trailing)
            case .volume50d, .volume50w:
                EmptyView()
            }
        }
    }

    private var dropAlignment: Alignment {
        guard let ind = dropIndicator, ind.target == row.symbol else { return .top }
        return ind.placement == .before ? .top : .bottom
    }

    var body: some View {
        HStack(spacing: 0) {
            macOSPriceCell.frame(width: WatchlistCol.price, alignment: .trailing)
            ForEach(metrics.filter { $0 != .price }) { metric in
                metricCell(metric)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: WatchlistCol.rowHeight, alignment: .leading)
        .background(hoverBox.isHovered && !isReordering ? DS.cardAlt.opacity(0.6) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture {
            onOpen()
        }
        .pointingHandCursor()
        .onHover { hoverBox.isHovered = $0 }
        .contextMenu { menu() }
        .overlay(alignment: dropAlignment) {
            if let ind = dropIndicator, ind.target == row.symbol {
                Rectangle()
                    .fill(ind.color)
                    .frame(height: 2)
            }
        }
    }
}
