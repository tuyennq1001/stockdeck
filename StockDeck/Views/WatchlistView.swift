import SwiftUI

private enum WatchlistCol {
    static let symbol: CGFloat = 114
    static let price: CGFloat = 80
    static let change: CGFloat = 68
    static let oneYear: CGFloat = 67
    static let threeYears: CGFloat = 67
}

#if os(iOS)
private func iosMetricColumnWidth(_ metric: WatchlistMetric) -> CGFloat {
    switch metric {
    case .price: return 82
    case .today: return 68
    case .todayChange: return 78
    case .oneMonth, .threeMonths, .sixMonths, .ytd, .oneYear, .twoYears, .threeYears, .fiveYears: return 68
    case .ath, .atl: return 78
    case .fromAth, .fromAtl: return 68
    case .marketCap: return 78
    case .chart24h, .chart7d, .chart30d, .chart60d, .chart90d, .chartYtd, .chart1y: return 70
    }
}
#endif

struct WatchlistView: View {
    @EnvironmentObject var stockService: StockService
    @EnvironmentObject var storageService: StorageService
    @Environment(\.showSymbolDetail) private var showSymbolDetail
    @State private var viewModel = WatchlistViewModel()
    @Binding var showSearch: Bool
    @State private var showNewWatchlistAlert = false
    @State private var newWatchlistName = ""
    @State private var renamingWatchlist: Watchlist? = nil
    @State private var renameWatchlistName = ""
    @State private var draggingWatchlistId: UUID? = nil
    /// Live display order while dragging a watchlist tab: reordering only
    /// touches this local array (no storage writes during drag) and the final
    /// order is committed once on drop.
    @State private var previewWatchlistIds: [UUID] = []
    @State private var draggingSymbol: String? = nil
    /// Local-only preview of the flat symbol order while dragging (mirrors the
    /// wide view): no storage writes until the drop lands.
    @State private var previewSymbolOrder: [String] = []
    @State private var dropIndicator: DropIndicator<String>? = nil
    @State private var addToPortfolio: (symbol: String, portfolioId: UUID)? = nil
    @State private var alertSymbol: String? = nil
    @State private var confirmDeleteWatchlist: Watchlist? = nil
    @State private var confirmRemoveSymbol: String? = nil

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
        if draggingSymbol != nil && !previewSymbolOrder.isEmpty {
            return previewSymbolOrder
        }
        return viewModel.displaySymbols
    }

    /// The flat list: drag/drop column sort, delete, move.
    private var flatList: some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(spacing: 0) {
                ForEach(Array(displaySymbols.enumerated()), id: \.element) { _, symbol in
                    ReorderRow(
                        id: symbol,
                        draggingId: $draggingSymbol,
                        isHorizontal: false,
                        makeDragItem: {
                            if currentSortKey != .order || !currentSortAsc {
                                setSort(.order, ascending: true)
                            }
                            if previewSymbolOrder.isEmpty { previewSymbolOrder = storageService.watchlist }
                            return NSItemProvider(object: symbol as NSString)
                        },
                        onMove: { src, tgt, placement in
                            if currentSortKey != .order || !currentSortAsc {
                                setSort(.order, ascending: true)
                            }
                            moveSymbolInPreview(src, beforeOrAfter: tgt, placement: placement)
                        },
                        onCommit: { commitSymbolPreview() },
                        content: {
                            if draggingSymbol == symbol {
                                quoteOrPlaceholderRow(symbol).opacity(0)
                            } else {
                                quoteOrPlaceholderRow(symbol)
                            }
                        },
                        dropIndicator: $dropIndicator
                    )
                    if symbol != displaySymbols.last {
                        Divider().padding(.leading, 74)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    /// Assembles the row used by the flat list: a real QuoteRow when quotes are
    /// loaded, else a column-aligned placeholder.
    @ViewBuilder
    private func quoteOrPlaceholderRow(_ symbol: String) -> some View {
        if let quote = stockService.quotes[symbol] {
            Button(action: {
                showSymbolDetail.perform(quote.symbol)
            }) {
                QuoteRow(quote: quote)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .contextMenu {
                watchlistContextMenu(symbol: symbol)
            }
        } else {
            Button(action: {
                showSymbolDetail.perform(symbol)
            }) {
                #if os(iOS)
                let activeCols = storageService.resolvedIOSWatchlistMetrics
                HStack(spacing: 0) {
                    HStack(spacing: 4) {
                        SymbolLogo(symbol: symbol, size: 20)
                        Text(StockService.beautifiedSymbol(symbol))
                            .font(.inter(14.5, relativeTo: .body).monospacedDigit())
                            .fontWeight(.bold)
                            .lineLimit(1)
                    }
                    .frame(width: 78, alignment: .leading)

                    ForEach(activeCols, id: \.self) { metric in
                        ProgressView()
                            .scaleEffect(0.6)
                            .frame(width: iosMetricColumnWidth(metric), alignment: .trailing)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 3)
                .contentShape(Rectangle())
                #else
                HStack(spacing: 0) {
                    HStack(spacing: 5) {
                        SymbolLogo(symbol: symbol, size: 20)
                        Text(StockService.beautifiedSymbol(symbol))
                            .font(.inter(12.5, relativeTo: .body).monospacedDigit())
                            .fontWeight(.bold)
                            .lineLimit(1)
                    }
                    .frame(width: WatchlistCol.symbol, alignment: .leading)

                    Color.clear.frame(width: WatchlistCol.price)
                    Color.clear.frame(width: WatchlistCol.change)
                    Color.clear.frame(width: WatchlistCol.oneYear)
                    ProgressView()
                        .scaleEffect(0.6)
                        .frame(width: WatchlistCol.threeYears, alignment: .trailing)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 3)
                .contentShape(Rectangle())
                #endif
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .contextMenu {
                watchlistContextMenu(symbol: symbol)
            }
        }
    }

    #if os(iOS)
    private var headerRow: some View {
        let activeCols = storageService.resolvedIOSWatchlistMetrics
        return HStack(spacing: 0) {
            sortHeader("Symbol", column: .symbol)
                .frame(width: 78, alignment: .leading)
            ForEach(activeCols, id: \.self) { metric in
                iosMetricHeader(metric)
            }
        }
        .font(.inter(12.5, weight: .semibold, relativeTo: .caption))
        .foregroundColor(.secondary)
        .tracking(0.8)
        .textCase(.uppercase)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func iosMetricHeader(_ metric: WatchlistMetric) -> some View {
        let width = iosMetricColumnWidth(metric)
        switch metric {
        case .price:
            sortHeader("Price", column: .price)
                .frame(width: width, alignment: .trailing)
        case .today, .todayChange:
            sortHeader("Today %", column: .metric(.today))
                .frame(width: width, alignment: .trailing)
        case .oneMonth, .threeMonths, .sixMonths, .ytd, .oneYear, .twoYears, .threeYears, .fiveYears:
            sortHeader(metric.title, column: .metric(metric))
                .frame(width: width, alignment: .trailing)
        case .ath:
            sortHeader("ATH", column: .metric(.ath))
                .frame(width: width, alignment: .trailing)
        case .fromAth:
            sortHeader("From ATH", column: .metric(.fromAth))
                .frame(width: width, alignment: .trailing)
        case .atl:
            sortHeader("ATL", column: .metric(.atl))
                .frame(width: width, alignment: .trailing)
        case .fromAtl:
            sortHeader("From ATL", column: .metric(.fromAtl))
                .frame(width: width, alignment: .trailing)
        case .marketCap:
            sortHeader("Mkt Cap", column: .metric(.marketCap))
                .frame(width: width, alignment: .trailing)
        case .chart24h, .chart7d, .chart30d, .chart60d, .chart90d, .chartYtd, .chart1y:
            Text(metric.title)
                .frame(width: width, alignment: .center)
        }
    }
    #else
    private var headerRow: some View {
        HStack(spacing: 0) {
            sortHeader("Symbol", column: .symbol)
                .frame(width: WatchlistCol.symbol, alignment: .leading)
            sortHeader("Price", column: .price)
                .frame(width: WatchlistCol.price, alignment: .trailing)
            sortHeader("Today %", column: .metric(.today))
                .frame(width: WatchlistCol.change, alignment: .trailing)
            sortHeader("1Y", column: .metric(.oneYear))
                .frame(width: WatchlistCol.oneYear, alignment: .trailing)
            sortHeader("3Y", column: .metric(.threeYears))
                .frame(width: WatchlistCol.threeYears, alignment: .trailing)
        }
        .font(.inter(10.5, weight: .semibold, relativeTo: .caption2))
        .foregroundColor(.secondary)
        .tracking(0.8)
        .textCase(.uppercase)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }
    #endif

    var body: some View {
        VStack(spacing: 0) {
            watchlistPickerBar

            Divider()

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
                #if os(iOS)
                ScrollView(.horizontal, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        headerRow

                        Divider()

                        flatList
                    }
                }
                #else
                headerRow

                Divider()

                flatList
                #endif

                Divider()

                HStack(spacing: 12) {
                    Button(action: {
                        newWatchlistName = ""
                        showNewWatchlistAlert = true
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "plus.circle.fill")
                            Text("Add Watchlist")
                        }
                        #if os(iOS)
                        .font(.inter(12, relativeTo: .caption))
                        #else
                        .font(.inter(10, relativeTo: .caption))
                        #endif
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
                        #if os(iOS)
                        .font(.inter(12, relativeTo: .caption))
                        #else
                        .font(.inter(10, relativeTo: .caption))
                        #endif
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
            .alert("Remove Symbol", isPresented: Binding(get: { confirmRemoveSymbol != nil }, set: { if !$0 { confirmRemoveSymbol = nil } })) {
                Button("Cancel", role: .cancel) { confirmRemoveSymbol = nil }
                Button("Remove", role: .destructive) {
                    if let sym = confirmRemoveSymbol {
                        storageService.removeFromWatchlist(sym)
                    }
                    confirmRemoveSymbol = nil
                }
            } message: {
                Text("Are you sure you want to remove \(confirmRemoveSymbol ?? "") from '\(storageService.currentWatchlist.name)'?")
            }
            .onChange(of: draggingSymbol) { _, newValue in
                if newValue == nil {
                    previewSymbolOrder = []
                    dropIndicator = nil
                }
            }
            .onChange(of: draggingWatchlistId) { _, newValue in
                if newValue == nil { previewWatchlistIds = [] }
            }
            .onDrop(of: [.text], delegate: WatchlistCommitDelegate(
                onCommit: { commitSymbolPreview() }
            ))
            .onAppear {
                Task {
                    viewModel.setup(stockService: stockService, storageService: storageService)
                    await stockService.ensureSparklines(for: storageService.watchlist)
                }
            }
            .onChange(of: storageService.selectedWatchlistId) { _, _ in
                Task {
                    await stockService.ensureSparklines(for: storageService.watchlist)
                }
            }
            .onChange(of: storageService.watchlist) { _, newWatchlist in
                Task {
                    await stockService.ensureSparklines(for: newWatchlist)
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
                            #if os(macOS)
                            .frame(width: 370, height: 430)
                            #else
                            .frame(maxWidth: 360, maxHeight: 520)
                            .padding(.horizontal, 16)
                            #endif
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

    /// The watchlist tabs in order: the local drag preview while dragging, else the
    /// persisted order.
    private var displayedWatchlists: [Watchlist] {
        if draggingWatchlistId != nil, !previewWatchlistIds.isEmpty {
            let byId = Dictionary(uniqueKeysWithValues: storageService.watchlists.map { ($0.id, $0) })
            return previewWatchlistIds.compactMap { byId[$0] }
        }
        return storageService.watchlists
    }

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
                                    proxy.scrollTo(wl.id, anchor: .center)
                                }
                            }) {
                                Text(wl.name)
                                    #if os(iOS)
                                    .font(.inter(13, weight: selected ? .bold : .medium, relativeTo: .subheadline))
                                    #else
                                    .font(.inter(11.5, weight: selected ? .semibold : .medium, relativeTo: .caption))
                                    #endif
                                    .foregroundColor(selected ? .white : DS.ink)
                                    .padding(.horizontal, 11)
                                    .padding(.vertical, 5)
                                    .background(
                                        Capsule()
                                            .fill(selected ? DS.brand : Color.primary.opacity(0.06))
                                    )
                                    .contentShape(Capsule())
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
                                    confirmDeleteWatchlist = wl
                                }
                            }
                        }
                    }

                    Button(action: {
                        newWatchlistName = ""
                        showNewWatchlistAlert = true
                    }) {
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
                    .help("New watchlist")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
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

    @ViewBuilder
    private func sortHeader(_ title: String, column: WatchlistSortKey) -> some View {
        Button(action: {
            toggleSort(column)
        }) {
            HStack(spacing: 2) {
                Text(title)
                if currentSortKey == column {
                    Image(systemName: currentSortAsc ? "chevron.up" : "chevron.down")
                        .font(.inter(8, relativeTo: .caption2))
                }
            }
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
            alertSymbol = symbol
        } label: {
            Label("Set Price Alert…", systemImage: "bell")
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
            confirmRemoveSymbol = symbol
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

    /// Live, local-only reorder of the symbol preview while dragging. No storage
    /// writes (mirrors the wide view) — the drop commits once.
    private func moveSymbolInPreview(_ sourceSymbol: String, beforeOrAfter targetSymbol: String, placement: InsertPlacement) {
        if previewSymbolOrder.isEmpty { previewSymbolOrder = storageService.watchlist }
        guard sourceSymbol != targetSymbol,
              let srcIndex = previewSymbolOrder.firstIndex(of: sourceSymbol),
              let tgtIndex = previewSymbolOrder.firstIndex(of: targetSymbol) else { return }
        let item = previewSymbolOrder.remove(at: srcIndex)
        let newTargetIndex = previewSymbolOrder.firstIndex(of: targetSymbol) ?? tgtIndex
        let insertIndex = placement == .before ? newTargetIndex : newTargetIndex + 1
        guard insertIndex >= 0, insertIndex <= previewSymbolOrder.count else { return }
        previewSymbolOrder.insert(item, at: insertIndex)
    }

    /// Persists the previewed watchlist order exactly once, when the drop lands.
    private func commitSymbolPreview() {
        guard !previewSymbolOrder.isEmpty else {
            draggingSymbol = nil
            dropIndicator = nil
            return
        }
        let final = previewSymbolOrder
        previewSymbolOrder = []
        dropIndicator = nil
        if final != storageService.watchlist {
            storageService.watchlist = final
        }
        draggingSymbol = nil
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

}

/// Top-level fallback so a drop anywhere in the popover list (between rows,
/// below the last row, on the header) still commits the symbol drag preview once.
private struct WatchlistCommitDelegate: DropDelegate {
    let onCommit: () -> Void

    func performDrop(info: DropInfo) -> Bool {
        onCommit()
        return true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
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

struct QuoteRow: View {
    @EnvironmentObject var stockService: StockService
    @EnvironmentObject var storageService: StorageService
    let quote: StockQuote

    private func periodChange(_ metric: WatchlistMetric) -> Double? {
        let calendar = Calendar.current
        let now = Date()
        let boundary: Date?
        switch metric {
        case .oneMonth: boundary = calendar.date(byAdding: .month, value: -1, to: now)
        case .threeMonths: boundary = calendar.date(byAdding: .month, value: -3, to: now)
        case .sixMonths: boundary = calendar.date(byAdding: .month, value: -6, to: now)
        case .oneYear: boundary = calendar.date(byAdding: .year, value: -1, to: now)
        case .twoYears: boundary = calendar.date(byAdding: .year, value: -2, to: now)
        case .threeYears: boundary = calendar.date(byAdding: .year, value: -3, to: now)
        case .fiveYears: boundary = calendar.date(byAdding: .year, value: -5, to: now)
        case .ytd: boundary = calendar.date(from: calendar.dateComponents([.year], from: now))
        default: boundary = nil
        }
        guard let boundary else { return nil }
        let hist = stockService.watchlistHistory[quote.symbol] ?? stockService.priceHistoryMax[quote.symbol] ?? []
        return PriceHistory.percentChange(points: hist, currentPrice: quote.price, since: boundary)
    }

    #if os(iOS)
    private var iosSymbolCell: some View {
        let isDisplayAsset = StockService.isDisplayNameAsset(quote.symbol)
        return HStack(spacing: 4) {
            SymbolLogo(symbol: quote.symbol, size: 20)
            VStack(alignment: .leading, spacing: 0) {
                Text(isDisplayAsset ? quote.displayName : quote.symbol)
                    .font(.inter(14.5, relativeTo: .body).monospacedDigit())
                    .fontWeight(.bold)
                    .lineLimit(1)
                if storageService.showCompanyName {
                    Text(isDisplayAsset ? quote.symbol : quote.name)
                        .font(.inter(11.5, relativeTo: .caption))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .frame(width: 78, alignment: .leading)
    }

    @ViewBuilder
    private func iosMetricCell(for metric: WatchlistMetric) -> some View {
        let width = iosMetricColumnWidth(metric)
        switch metric {
        case .price:
            let displayPrice = quote.price
            let dec = storageService.resolvedPriceDecimals(symbol: quote.symbol, price: displayPrice)
            let formattedChange = StorageService.formatCompactNumber(quote.change, decimals: dec, stripTrailingZeros: true)

            VStack(alignment: .trailing, spacing: 1) {
                Text(StorageService.formatCompactNumber(displayPrice, decimals: dec))
                    .font(.inter(14, relativeTo: .body).monospacedDigit())
                    .fontWeight(.medium)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)

                Text((quote.change >= 0 ? "+" : "") + formattedChange)
                    .font(.inter(11.5, relativeTo: .caption).monospacedDigit())
                    .fontWeight(.semibold)
                    .foregroundColor(quote.isPositive ? DS.up : DS.down)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .frame(width: width, alignment: .trailing)

        case .today, .todayChange:
            VStack(alignment: .trailing, spacing: 1) {
                Text(String(format: "%+.\(storageService.percentDecimals)f%%", quote.changePercent))
                    .font(.inter(14, relativeTo: .body).monospacedDigit())
                    .fontWeight(.medium)
                    .foregroundColor(quote.isPositive ? DS.up : DS.down)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)

                if storageService.showExtendedHours, quote.isExtendedHours, let extChange = quote.extendedChangePercent {
                    let isPre = quote.marketState.hasPrefix("PRE")
                    HStack(spacing: 2) {
                        Image(systemName: isPre ? "sun.max.fill" : "moon.fill")
                            .font(.system(size: 8, weight: .semibold))
                        Text(String(format: "%+.\(storageService.percentDecimals)f%%", extChange))
                            .font(.inter(11, relativeTo: .caption2).monospacedDigit())
                            .fontWeight(.semibold)
                    }
                    .foregroundColor(extChange >= 0 ? DS.up : DS.down)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                }
            }
            .frame(width: width, alignment: .trailing)

        case .oneMonth, .threeMonths, .sixMonths, .ytd, .oneYear, .twoYears, .threeYears, .fiveYears:
            let pct = periodChange(metric)
            if let pct {
                Text(String(format: "%+.\(storageService.percentDecimals)f%%", pct))
                    .font(.inter(14, relativeTo: .body).monospacedDigit())
                    .fontWeight(.medium)
                    .foregroundColor(pct >= 0 ? DS.up : DS.down)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .frame(width: width, alignment: .trailing)
            } else {
                Text("—")
                    .font(.inter(14, relativeTo: .body).monospacedDigit())
                    .fontWeight(.medium)
                    .foregroundColor(.secondary)
                    .frame(width: width, alignment: .trailing)
            }

        case .marketCap:
            if let mc = quote.marketCap, mc > 0 {
                Text(StorageService.formatMarketCap(mc, currency: quote.currency))
                    .font(.inter(14, relativeTo: .body).monospacedDigit())
                    .fontWeight(.medium)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(width: width, alignment: .trailing)
            } else {
                Text("—")
                    .font(.inter(14, relativeTo: .body).monospacedDigit())
                    .fontWeight(.medium)
                    .foregroundColor(.secondary)
                    .frame(width: width, alignment: .trailing)
            }

        case .chart24h:
            Sparkline(symbol: quote.symbol, days: 1, width: width, height: 20)
                .frame(width: width, alignment: .center)
        case .chart7d:
            Sparkline(symbol: quote.symbol, days: 7, width: width, height: 20)
                .frame(width: width, alignment: .center)
        case .chart30d:
            Sparkline(symbol: quote.symbol, days: 30, width: width, height: 20)
                .frame(width: width, alignment: .center)
        case .chart60d:
            Sparkline(symbol: quote.symbol, days: 60, width: width, height: 20)
                .frame(width: width, alignment: .center)
        case .chart90d:
            Sparkline(symbol: quote.symbol, days: 90, width: width, height: 20)
                .frame(width: width, alignment: .center)
        case .chartYtd:
            Sparkline(symbol: quote.symbol, isYTD: true, width: width, height: 20)
                .frame(width: width, alignment: .center)
        case .chart1y:
            Sparkline(symbol: quote.symbol, days: 365, width: width, height: 20)
                .frame(width: width, alignment: .center)

        case .ath:
            let hist = stockService.priceHistoryMax[quote.symbol] ?? stockService.watchlistHistory[quote.symbol] ?? []
            let histHigh = hist.map(\.effectiveHigh).max()
            let quoteHigh = max(quote.fiftyTwoWeekHigh ?? 0, quote.price)
            let ath = histHigh != nil ? max(histHigh!, quoteHigh) : quoteHigh
            if ath > 0 {
                Text(StorageService.formatCompactNumber(ath, decimals: storageService.resolvedPriceDecimals(symbol: quote.symbol, price: ath)))
                    .font(.inter(14, relativeTo: .body).monospacedDigit())
                    .fontWeight(.medium)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .frame(width: width, alignment: .trailing)
            } else {
                Text("—")
                    .font(.inter(14, relativeTo: .body).monospacedDigit())
                    .fontWeight(.medium)
                    .foregroundColor(.secondary)
                    .frame(width: width, alignment: .trailing)
            }

        case .fromAth:
            let hist = stockService.priceHistoryMax[quote.symbol] ?? stockService.watchlistHistory[quote.symbol] ?? []
            let histHigh = hist.map(\.effectiveHigh).max()
            let quoteHigh = max(quote.fiftyTwoWeekHigh ?? 0, quote.price)
            let ath = histHigh != nil ? max(histHigh!, quoteHigh) : quoteHigh
            if ath > 0, quote.price > 0 {
                let fromAth = quote.price >= ath ? 0.0 : min(0.0, (quote.price - ath) / ath * 100)
                Text(String(format: "%+.\(storageService.percentDecimals)f%%", fromAth))
                    .font(.inter(14, relativeTo: .body).monospacedDigit())
                    .fontWeight(.medium)
                    .foregroundColor(fromAth >= 0 ? DS.up : DS.down)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .frame(width: width, alignment: .trailing)
            } else {
                Text("—")
                    .font(.inter(14, relativeTo: .body).monospacedDigit())
                    .fontWeight(.medium)
                    .foregroundColor(.secondary)
                    .frame(width: width, alignment: .trailing)
            }

        case .atl:
            let hist = stockService.priceHistoryMax[quote.symbol] ?? stockService.watchlistHistory[quote.symbol] ?? []
            let histLow = hist.map(\.effectiveLow).min()
            let qLow = quote.fiftyTwoWeekLow != nil ? min(quote.fiftyTwoWeekLow!, quote.price) : quote.price
            let atl = (histLow != nil && qLow > 0) ? min(histLow!, qLow) : (histLow ?? qLow)
            if atl > 0 {
                Text(StorageService.formatCompactNumber(atl, decimals: storageService.resolvedPriceDecimals(symbol: quote.symbol, price: atl)))
                    .font(.inter(14, relativeTo: .body).monospacedDigit())
                    .fontWeight(.medium)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .frame(width: width, alignment: .trailing)
            } else {
                Text("—")
                    .font(.inter(14, relativeTo: .body).monospacedDigit())
                    .fontWeight(.medium)
                    .foregroundColor(.secondary)
                    .frame(width: width, alignment: .trailing)
            }

        case .fromAtl:
            let hist = stockService.priceHistoryMax[quote.symbol] ?? stockService.watchlistHistory[quote.symbol] ?? []
            let histLow = hist.map(\.effectiveLow).min()
            let qLow = quote.fiftyTwoWeekLow != nil ? min(quote.fiftyTwoWeekLow!, quote.price) : quote.price
            let atl = (histLow != nil && qLow > 0) ? min(histLow!, qLow) : (histLow ?? qLow)
            if atl > 0, quote.price > 0 {
                let fromAtl = quote.price <= atl ? 0.0 : max(0.0, (quote.price - atl) / atl * 100)
                Text(String(format: "%+.\(storageService.percentDecimals)f%%", fromAtl))
                    .font(.inter(14, relativeTo: .body).monospacedDigit())
                    .fontWeight(.medium)
                    .foregroundColor(fromAtl >= 0 ? DS.up : DS.down)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .frame(width: width, alignment: .trailing)
            } else {
                Text("—")
                    .font(.inter(14, relativeTo: .body).monospacedDigit())
                    .fontWeight(.medium)
                    .foregroundColor(.secondary)
                    .frame(width: width, alignment: .trailing)
            }
        }
    }
    #endif

    #if !os(iOS)
    private var macOSSymbolCell: some View {
        let isDisplayAsset = StockService.isDisplayNameAsset(quote.symbol)
        return HStack(spacing: 5) {
            SymbolLogo(symbol: quote.symbol, size: 20)
            VStack(alignment: .leading, spacing: 0) {
                Text(isDisplayAsset ? quote.displayName : quote.symbol)
                    .font(.inter(12.5, relativeTo: .body).monospacedDigit())
                    .fontWeight(.bold)
                    .lineLimit(1)
                if storageService.showCompanyName {
                    Text(isDisplayAsset ? quote.symbol : quote.name)
                        .font(.inter(10, relativeTo: .caption2))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .frame(width: WatchlistCol.symbol, alignment: .leading)
    }

    private var macOSPriceCell: some View {
        let displayPrice = quote.price
        let dec = storageService.resolvedPriceDecimals(symbol: quote.symbol, price: displayPrice)
        let formattedChange = StorageService.formatCompactNumber(quote.change, decimals: dec, stripTrailingZeros: true)

        return VStack(alignment: .trailing, spacing: 1) {
            Text(StorageService.formatCompactNumber(displayPrice, decimals: dec))
                .font(.inter(11.5, relativeTo: .body).monospacedDigit())
                .fontWeight(.medium)
            Text((quote.change >= 0 ? "+" : "") + formattedChange)
                .font(.inter(10, relativeTo: .caption2).monospacedDigit())
                .fontWeight(.semibold)
                .foregroundColor(quote.isPositive ? DS.up : DS.down)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
    }

    private var macOSChangeCell: some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(String(format: "%+.\(storageService.percentDecimals)f%%", quote.changePercent))
                .font(.inter(11.5, relativeTo: .body).monospacedDigit())
                .fontWeight(.medium)
                .foregroundColor(quote.isPositive ? DS.up : DS.down)
                .lineLimit(1)
                .minimumScaleFactor(0.85)

            if storageService.showExtendedHours, quote.isExtendedHours, let extPct = quote.extendedChangePercent {
                let isPre = quote.marketState.hasPrefix("PRE")
                HStack(spacing: 1) {
                    Image(systemName: isPre ? "sun.max.fill" : "moon.fill")
                        .font(.system(size: 8, weight: .semibold))
                    Text(String(format: "%+.\(storageService.percentDecimals)f%%", extPct))
                        .font(.inter(10, relativeTo: .caption2).monospacedDigit())
                        .fontWeight(.semibold)
                }
                .foregroundColor(extPct >= 0 ? DS.up : DS.down)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            }
        }
    }
    private func macOSPeriodCell(for metric: WatchlistMetric, width: CGFloat) -> some View {
        let pct = periodChange(metric)
        return Group {
            if let pct {
                Text(String(format: "%+.\(storageService.percentDecimals)f%%", pct))
                    .font(.inter(11.5, relativeTo: .body).monospacedDigit())
                    .fontWeight(.medium)
                    .foregroundColor(pct >= 0 ? DS.up : DS.down)
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
    #endif

    var body: some View {
        #if os(iOS)
        let activeCols = storageService.resolvedIOSWatchlistMetrics
        HStack(spacing: 0) {
            iosSymbolCell

            ForEach(activeCols, id: \.self) { metric in
                iosMetricCell(for: metric)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4.5)
        #else
        HStack(spacing: 0) {
            macOSSymbolCell
            macOSPriceCell.frame(width: WatchlistCol.price, alignment: .trailing)
            macOSChangeCell.frame(width: WatchlistCol.change, alignment: .trailing)
            macOSPeriodCell(for: .oneYear, width: WatchlistCol.oneYear)
            macOSPeriodCell(for: .threeYears, width: WatchlistCol.threeYears)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4.5)
        #endif
    }
}
