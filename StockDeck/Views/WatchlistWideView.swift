import SwiftUI
import UniformTypeIdentifiers

/// Fully custom, desktop-grade watchlist: a hand-built sortable list (clickable
/// column headers, hover rows, right-click actions, Move Up/Down reorder) dressed
/// as a white card over the paper ground — no native `Table`.
struct WatchlistWideView: View {
    @EnvironmentObject var stockService: StockService
    @EnvironmentObject var storageService: StorageService
    @Binding var showSearch: Bool

    enum SortKey { case order, symbol, name, changePercent, extChangePercent }

    @State private var showNewWatchlistAlert = false
    @State private var newWatchlistName = ""
    @State private var renamingWatchlist: Watchlist? = nil
    @State private var renameWatchlistName = ""
    @State private var draggingWatchlistId: UUID? = nil
    // Default to the manual "as added" order so Move Up/Down is meaningful;
    // clicking a column header re-sorts by that column (toggles direction).
    @State private var sortKey: SortKey = .order
    @State private var sortAsc = true
    @State private var draggingSymbol: String? = nil
    @State private var addToPortfolio: AddTarget?
    @State private var alertSymbol: AlertTarget?

    struct WatchRow: Identifiable {
        let id: String
        let order: Int
        let symbol: String
        let name: String
        let currency: String
        let price: Double            // regular market price
        let extPrice: Double?        // pre/post-market price, if any
        let extChangePercent: Double? // pre/post-market % move vs regular close
        let extLabel: String         // "Pre" / "Post"
        let change: Double
        let changePercent: Double
        let loaded: Bool
        let quote: StockQuote?
    }
    struct AddTarget: Identifiable { let symbol: String; let portfolioId: UUID; var id: String { "\(symbol)-\(portfolioId)" } }
    struct AlertTarget: Identifiable { let symbol: String; var id: String { symbol } }
    struct DetailTarget: Identifiable { let symbol: String; var id: String { symbol } }
    @State private var detailSymbol: DetailTarget?

    @State private var selectedSymbols: Set<String> = []
    @State private var activeDetailSymbol: String? = nil
    @State private var lastClickedSymbol: String? = nil

    private var rows: [WatchRow] {
        storageService.watchlist.enumerated().map { index, symbol in
            let q = stockService.quotes[symbol]
            let rate = q.map { stockService.priceRate(from: $0.currency) } ?? 1
            let ext: Double? = q.flatMap { $0.isExtendedHours ? $0.effectivePrice * rate : nil }
            return WatchRow(
                id: symbol, order: index, symbol: symbol,
                name: q?.name ?? "",
                currency: (storageService.stockPriceCurrency.isEmpty ? q?.currency : storageService.stockPriceCurrency) ?? "",
                price: (q?.price ?? 0) * rate,
                extPrice: ext,
                extChangePercent: ext != nil ? q?.extendedChangePercent : nil,
                extLabel: q?.marketStateLabel ?? "",
                change: (q?.change ?? 0) * rate,
                changePercent: q?.changePercent ?? 0,
                loaded: q != nil, quote: q
            )
        }
    }

    private var visibleRows: [WatchRow] { sortedRows() }

    /// True when any watchlist quote is trading pre/post-market. Drives the row
    /// hierarchy: during extended hours the After-hrs price/% reads first and the
    /// regular price dims to context; during regular hours it's the reverse.
    private var extendedSession: Bool {
        storageService.showExtendedHours &&
        storageService.watchlist.contains { stockService.quotes[$0]?.isExtendedHours == true }
    }

    private func sortedRows() -> [WatchRow] {
        let base = rows
        let asc = sortAsc
        func by<T: Comparable>(_ key: (WatchRow) -> T) -> [WatchRow] {
            base.sorted { asc ? key($0) < key($1) : key($0) > key($1) }
        }
        switch sortKey {
        case .order:         return asc ? base : base.reversed()
        case .symbol:        return by { $0.symbol }
        case .name:          return by { $0.name }
        case .changePercent: return by { $0.changePercent }
        case .extChangePercent:
            // The After-hrs column is hidden when Extended Hours is off, so its
            // sort key would be stranded — fall back to the manual order.
            guard storageService.showExtendedHours else { return asc ? base : base.reversed() }
            // Sort by the pre/post-market % move, not the raw extended price.
            // Rows without an extended-hours quote sink to the bottom either way.
            return StorageService.sortedByExtendedPercent(base, ascending: asc) { $0.extChangePercent }
        }
    }

    private func toggleSort(_ key: SortKey) {
        if sortKey == key { sortAsc.toggle() } else { sortKey = key; sortAsc = (key == .order || key == .symbol || key == .name) }
    }

    var body: some View {
        PageScaffold(storageService.currentWatchlist.name, caption: "\(storageService.watchlist.count) symbols") {
            HStack(spacing: 12) {
                Button {
                    PortfolioIO.exportWatchlists(storageService.watchlists, stockService: stockService, restoreActivationPolicy: false)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "square.and.arrow.up").font(.system(size: 11, weight: .medium))
                        Text("Export All").font(DS.caption)
                    }
                    .foregroundStyle(DS.inkSecondary)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(DS.cardAlt))
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                .help("Export all watchlists to Excel (.xlsx)")

                RefreshButton(isLoading: stockService.isLoading) {
                    Task { await stockService.refreshAll(storageService: storageService) }
                }
                addButton
            }
        } content: {
            if storageService.watchlist.isEmpty {
                emptyState
            } else {
                HStack(alignment: .top, spacing: 0) {
                    table
                        .frame(width: activeDetailSymbol != nil ? 300 : nil)
                        .frame(maxWidth: activeDetailSymbol != nil ? 300 : .infinity, maxHeight: .infinity)

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
        .task(id: storageService.watchlist) {
            // One batched spark request fills every row's sparkline.
            await stockService.ensureSparklines(for: storageService.watchlist)
        }
        .sheet(item: $addToPortfolio) { t in
            HoldingFormSheet(mode: .addSymbol(symbol: t.symbol, portfolioId: t.portfolioId)) { addToPortfolio = nil }
                .environmentObject(stockService).environmentObject(storageService)
        }
        .sheet(item: $alertSymbol) { t in
            PriceAlertSheet(symbol: t.symbol) { alertSymbol = nil }
                .environmentObject(stockService).environmentObject(storageService)
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
                VStack(alignment: .leading, spacing: 2) {
                    Text(symbol).font(DS.titleXL).tracking(-0.3).foregroundStyle(DS.ink)
                    if !quote.name.isEmpty {
                        Text(quote.name).font(DS.caption).foregroundStyle(DS.inkTertiary).lineLimit(1)
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
                    fiftyTwoWeekCard(quote)
                    factsCard(quote)
                }
                .padding(16)
            }
        }
        .background(DS.ground)
    }

    @ViewBuilder private func fiftyTwoWeekCard(_ quote: StockQuote) -> some View {
        if let pos = quote.fiftyTwoWeekPosition,
           let low = quote.fiftyTwoWeekLow, let high = quote.fiftyTwoWeekHigh {
            let priceSymbol = StorageService.currencySymbol(for: quote.currency)
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
                    ForEach(storageService.watchlists) { wl in
                        let selected = wl.id == storageService.currentWatchlist.id
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
                        .onDrag {
                            self.draggingWatchlistId = wl.id
                            return NSItemProvider(object: wl.id.uuidString as NSString)
                        }
                        .onDrop(of: [.text], delegate: WatchlistTabDropDelegate(
                            targetId: wl.id,
                            draggingId: $draggingWatchlistId,
                            onMove: { srcId, tgtId in
                                storageService.moveWatchlist(from: srcId, beforeOrAfter: tgtId)
                            }
                        ))
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
            headerRow
            Divider().overlay(DS.hairline)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(visibleRows.enumerated()), id: \.element.id) { idx, row in
                        WatchRowView(row: row,
                                     showExtended: storageService.showExtendedHours,
                                     extendedSession: extendedSession,
                                     percentDecimals: storageService.percentDecimals,
                                     valueDecimals: storageService.valueDecimals,
                                     isSelected: selectedSymbols.contains(row.symbol),
                                     compact: isCompact,
                                     onOpen: {
                                         handleRowClick(row.symbol)
                                     },
                                     menu: { rowMenu(row) })
                        .onDrag {
                            self.draggingSymbol = row.symbol
                            return NSItemProvider(object: row.symbol as NSString)
                        }
                        .onDrop(of: [.text], delegate: WatchlistDropDelegate(
                            targetSymbol: row.symbol,
                            draggingSymbol: $draggingSymbol,
                            onMove: { src, tgt in
                                if sortKey != .order || !sortAsc {
                                    sortKey = .order
                                    sortAsc = true
                                }
                                storageService.moveWatchlistSymbol(src, beforeOrAfter: tgt)
                            }
                        ))
                        if idx < visibleRows.count - 1 {
                            Divider().overlay(DS.hairline.opacity(0.5)).padding(.leading, 14)
                        }
                    }
                    if !visibleRows.isEmpty {
                        Divider().overlay(DS.hairline.opacity(0.5)).padding(.leading, 14)
                    }
                    Button(action: { showSearch = true }) {
                        HStack(spacing: 6) {
                            Image(systemName: "plus.circle.fill")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(DS.brand)
                            Text("Add stock")
                                .font(.inter(12, weight: .semibold, relativeTo: .body))
                                .foregroundStyle(DS.brand)
                            Spacer()
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                }
            }
        }
        .padding(.vertical, 6)
    }

    private func handleRowClick(_ symbol: String) {
        let isShift = NSEvent.modifierFlags.contains(.shift)
        let isCmd = NSEvent.modifierFlags.contains(.command)

        if isShift, let last = lastClickedSymbol,
           let lastIdx = visibleRows.firstIndex(where: { $0.symbol == last }),
           let currentIdx = visibleRows.firstIndex(where: { $0.symbol == symbol }) {
            let minIdx = min(lastIdx, currentIdx)
            let maxIdx = max(lastIdx, currentIdx)
            let rangeSymbols = visibleRows[minIdx...maxIdx].map(\.symbol)
            selectedSymbols.formUnion(rangeSymbols)
        } else if isCmd {
            if selectedSymbols.contains(symbol) {
                selectedSymbols.remove(symbol)
            } else {
                selectedSymbols.insert(symbol)
            }
            lastClickedSymbol = symbol
        } else {
            selectedSymbols = [symbol]
            lastClickedSymbol = symbol
        }

        withAnimation(.easeInOut(duration: 0.2)) {
            activeDetailSymbol = symbol
        }
    }

    private var isCompact: Bool { activeDetailSymbol != nil }

    private var headerRow: some View {
        HStack(spacing: WCol.spacing) {
            headerCell("#", .order, width: 24, align: .leading, help: "Sort by manual order")
            headerCell("Symbol", .symbol, width: WCol.symbol, align: .leading)
            if !isCompact {
                headerCell("Name", .name, width: nil, align: .leading)
                headerCell("Price", .changePercent, width: WCol.price, align: .trailing,
                           help: "Sort by today's % change")
                if storageService.showExtendedHours {
                    headerCell("After hrs", .extChangePercent, width: WCol.ext, align: .trailing,
                               help: "Sort by the pre/post-market % move")
                }
                Text("Trend").font(DS.label).foregroundStyle(DS.inkTertiary).frame(width: WCol.trend)
                Text("52-week").font(DS.label).foregroundStyle(DS.inkTertiary).frame(width: WCol.range, alignment: .leading)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    @ViewBuilder
    private func headerCell(_ title: String, _ key: SortKey, width: CGFloat?, align: Alignment,
                            help: LocalizedStringKey = "") -> some View {
        Button { withAnimation(.easeOut(duration: 0.15)) { toggleSort(key) } } label: {
            HStack(spacing: 3) {
                if align == .trailing { Spacer(minLength: 0) }
                Text(LocalizedStringKey(title)).font(DS.label).foregroundStyle(sortKey == key ? DS.brand : DS.inkTertiary)
                if sortKey == key {
                    Image(systemName: sortAsc ? "chevron.up" : "chevron.down")
                        .font(.system(size: 7, weight: .bold)).foregroundStyle(DS.brand)
                }
                if align == .leading { Spacer(minLength: 0) }
            }
            .frame(width: width, alignment: align)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
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
            sortKey = .order
            sortAsc = true
        }
        guard let i = storageService.watchlist.firstIndex(of: symbol) else { return }
        let j = i + delta
        guard j >= 0, j < storageService.watchlist.count else { return }
        storageService.watchlist.swapAt(i, j)
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
    static let symbol: CGFloat = 128
    static let price: CGFloat = 104
    static let ext: CGFloat = 116
    static let trend: CGFloat = 56
    static let range: CGFloat = 100
    static let spacing: CGFloat = 12
}

/// One custom watchlist row: hover tint, click-to-open, right-click actions.
private struct WatchRowView<Menu: View>: View {
    let row: WatchlistWideView.WatchRow
    let showExtended: Bool
    let extendedSession: Bool
    let percentDecimals: Int
    let valueDecimals: Int
    let isSelected: Bool
    var compact: Bool = false
    let onOpen: () -> Void
    @ViewBuilder let menu: () -> Menu
    @State private var hover = false

    /// Price decimals honoring the manual override (Auto = smart per #10).
    private func priceDec(_ price: Double) -> Int {
        valueDecimals >= 0 ? valueDecimals : StorageService.priceDecimals(symbol: row.symbol, price: price)
    }

    /// A price stacked over its own % move (same baseline, so they always agree).
    /// `emphasised` = the live session: the price goes ink-dark and the % becomes
    /// a coloured pill. Otherwise both dim so the active session reads first.
    @ViewBuilder
    private func pairedCell(price: Double, pct: Double?, label: String?, emphasised: Bool) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text("\(StorageService.currencySymbol(for: row.currency))\(StorageService.formatNumber(price, decimals: priceDec(price)))")
                .font(DS.figure)
                .foregroundStyle(emphasised ? DS.ink : DS.inkTertiary)
                .contentTransition(.numericText())
            if let pct {
                HStack(spacing: 4) {
                    if let label, !label.isEmpty {
                        Text(LocalizedStringKey(label)).font(DS.micro).foregroundStyle(DS.inkTertiary)
                    }
                    if emphasised {
                        ChangePill(value: pct, text: String(format: "%+.\(percentDecimals)f%%", pct))
                    } else {
                        Text(String(format: "%+.\(percentDecimals)f%%", pct))
                            .font(DS.micro).foregroundStyle(DS.pnlColor(pct).opacity(0.55))
                    }
                }
            }
        }
    }

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: WCol.spacing) {
                // Symbol chip — always visible
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 7, style: .continuous).fill(DS.brand.opacity(0.10))
                        .frame(width: 28, height: 28)
                        .overlay(Text(row.symbol.prefix(2))
                            .font(.inter(9.5, weight: .bold, relativeTo: .caption2))
                            .foregroundStyle(DS.brand))
                    Text(row.symbol).font(DS.figure).foregroundStyle(DS.ink)
                }
                .frame(width: WCol.symbol, alignment: .leading)

                if !compact {
                    // Name
                    Text(row.name.isEmpty ? "—" : row.name)
                        .font(DS.body).foregroundStyle(DS.inkSecondary).lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    // Regular price + today's % move.
                    Group {
                        if row.loaded {
                            pairedCell(price: row.price, pct: row.changePercent,
                                       label: nil, emphasised: !extendedSession)
                        } else {
                            DSSpinner(size: 12)
                        }
                    }
                    .frame(width: WCol.price, alignment: .trailing)

                    // After-hours price.
                    if showExtended {
                        Group {
                            if let ext = row.extPrice {
                                pairedCell(price: ext, pct: row.extChangePercent,
                                           label: row.extLabel, emphasised: extendedSession)
                            } else {
                                Text("—").font(DS.figure).foregroundStyle(DS.inkTertiary)
                            }
                        }
                        .frame(width: WCol.ext, alignment: .trailing)
                    }

                    // Trend sparkline
                    Sparkline(symbol: row.symbol).frame(width: WCol.trend)

                    // 52-week range
                    Group {
                        if let q = row.quote, let pos = q.fiftyTwoWeekPosition {
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(DS.cardAlt).frame(height: 5)
                                    Circle().fill(.white)
                                        .frame(width: 9, height: 9)
                                        .overlay(Circle().strokeBorder(DS.brand, lineWidth: 1.5))
                                        .shadow(color: .black.opacity(0.10), radius: 1.5, y: 0.5)
                                        .offset(x: CGFloat(pos) * (geo.size.width - 9))
                                }
                                .frame(maxHeight: .infinity, alignment: .center)
                            }
                            .frame(height: 12)
                        } else {
                            Text("—").foregroundStyle(DS.inkTertiary).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .frame(width: WCol.range)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            .frame(minHeight: 44)
            .background(isSelected ? DS.brand.opacity(0.12) : (hover ? DS.cardAlt.opacity(0.6) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .onHover { hover = $0 }
        .contextMenu { menu() }
    }
}

private struct WatchlistDropDelegate: DropDelegate {
    let targetSymbol: String
    @Binding var draggingSymbol: String?
    let onMove: (String, String) -> Void

    func performDrop(info: DropInfo) -> Bool {
        draggingSymbol = nil
        return true
    }

    func dropEntered(info: DropInfo) {
        guard let draggingSymbol = draggingSymbol, draggingSymbol != targetSymbol else { return }
        withAnimation(.easeOut(duration: 0.15)) {
            onMove(draggingSymbol, targetSymbol)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }
}

