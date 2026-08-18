import SwiftUI

struct WatchlistView: View {
    @EnvironmentObject var stockService: StockService
    @EnvironmentObject var storageService: StorageService
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
    @State private var sortColumn: SortColumn = .manual
    @State private var sortAscending: Bool = true
    @State private var confirmDeleteWatchlist: Watchlist? = nil
    @State private var confirmRemoveSymbol: String? = nil

    enum SortColumn: String {
        case manual, symbol, price, absoluteChange, changePercent
    }

    private func loadSortFromCurrentWatchlist() {
        let wl = storageService.currentWatchlist
        if let raw = wl.sortKey, let col = SortColumn(rawValue: raw) {
            sortColumn = col
        } else {
            sortColumn = .manual
        }
        sortAscending = wl.sortAsc ?? true
    }

    private func setSort(_ col: SortColumn, ascending: Bool) {
        sortColumn = col
        sortAscending = ascending
        storageService.setWatchlistSort(key: col.rawValue, ascending: ascending, for: storageService.currentWatchlist.id)
    }

    var sortedSymbols: [String] {
        if sortColumn == .manual {
            return sortAscending ? storageService.watchlist : Array(storageService.watchlist.reversed())
        }
        return storageService.watchlist.sorted { a, b in
            let qa = stockService.quotes[a]
            let qb = stockService.quotes[b]
            let result: Bool
            switch sortColumn {
            case .manual:
                result = true
            case .symbol:
                result = a.localizedCompare(b) == .orderedAscending
            case .price:
                let pa = qa?.price ?? 0
                let pb = qb?.price ?? 0
                result = pa < pb
            case .absoluteChange:
                let ca = qa?.change ?? 0
                let cb = qb?.change ?? 0
                result = ca < cb
            case .changePercent:
                let ca = qa?.changePercent ?? 0
                let cb = qb?.changePercent ?? 0
                result = ca < cb
            }
            return sortAscending ? result : !result
        }
    }

    var filteredSymbols: [String] { sortedSymbols }

    /// The rows to render: the local drag preview while dragging (live reorder,
    /// zero storage writes), else the sorted/column projection.
    private var displaySymbols: [String] {
        if draggingSymbol != nil && !previewSymbolOrder.isEmpty {
            return previewSymbolOrder
        }
        return filteredSymbols
    }

    /// The flat list: drag/drop column sort, delete, move.
    private var flatList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(displaySymbols.enumerated()), id: \.element) { _, symbol in
                    ReorderRow(
                        id: symbol,
                        draggingId: $draggingSymbol,
                        isHorizontal: false,
                        makeDragItem: {
                            if sortColumn != .manual || !sortAscending {
                                sortColumn = .manual
                                sortAscending = true
                            }
                            if previewSymbolOrder.isEmpty { previewSymbolOrder = storageService.watchlist }
                            return NSItemProvider(object: symbol as NSString)
                        },
                        onMove: { src, tgt, placement in
                            if sortColumn != .manual || !sortAscending {
                                sortColumn = .manual
                                sortAscending = true
                            }
                            moveSymbolInPreview(src, beforeOrAfter: tgt, placement: placement)
                        },
                        onCommit: { commitSymbolPreview() },
                        dropIndicator: $dropIndicator
                    ) {
                        if draggingSymbol == symbol {
                            quoteOrPlaceholderRow(symbol).opacity(0)
                        } else {
                            quoteOrPlaceholderRow(symbol)
                        }
                    }
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
            QuoteRow(quote: quote)
                .contentShape(Rectangle())
                .pointingHandCursor()
                .contextMenu {
                    watchlistContextMenu(symbol: symbol)
                }
        } else {
            HStack(spacing: 0) {
                HStack(spacing: 5) {
                    SymbolLogo(symbol: symbol, size: 20)
                    Text(StockService.beautifiedSymbol(symbol))
                        .font(.inter(12, relativeTo: .body).monospacedDigit())
                        .fontWeight(.bold)
                        .lineLimit(1)
                }
                .frame(width: 110, alignment: .leading)

                if storageService.showWatchlistSparkline {
                    Color.clear.frame(width: 64)
                }

                if storageService.showExtendedHours || storageService.showAbsoluteChange {
                    Color.clear.frame(width: 78)
                } else {
                    Color.clear.frame(maxWidth: .infinity)
                }

                if storageService.showAbsoluteChange {
                    if storageService.showExtendedHours {
                        Color.clear.frame(width: 60)
                    } else {
                        Color.clear.frame(maxWidth: .infinity)
                    }
                }

                if storageService.showExtendedHours {
                    ProgressView()
                        .scaleEffect(0.6)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
            .pointingHandCursor()
            .contextMenu {
                watchlistContextMenu(symbol: symbol)
            }
        }
    }

    private var headerRow: some View {
        HStack(spacing: 0) {
            sortHeader("Symbol", column: .symbol)
                .frame(width: 110, alignment: .leading)
            if storageService.showWatchlistSparkline {
                Text("30D")
                    .frame(width: 64, alignment: .center)
            }
            if storageService.showExtendedHours || storageService.showAbsoluteChange {
                sortHeader("Price", column: .price)
                    .frame(width: 78, alignment: .trailing)
            } else {
                sortHeader("Price", column: .price)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            if storageService.showAbsoluteChange {
                if storageService.showExtendedHours {
                    sortHeader("Change", column: .absoluteChange)
                        .frame(width: 60, alignment: .trailing)
                } else {
                    sortHeader("Change", column: .absoluteChange)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            if storageService.showExtendedHours {
                Text("Ext")
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .font(.inter(10, weight: .medium, relativeTo: .caption))
        .foregroundColor(.secondary)
        .tracking(0.8)
        .textCase(.uppercase)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

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
                    Text("No stocks in \(storageService.currentWatchlist.name)")
                        .foregroundColor(.secondary)
                    Button("Add stock") {
                        showSearch = true
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .pointingHandCursor()
                    Spacer()
                }
            } else {
                headerRow

                Divider()

                flatList

                Divider()

                Button(action: { showSearch = true }) {
                    HStack {
                        Image(systemName: "plus.circle.fill")
                        Text("Add stock")
                    }
                    .font(.inter(10, relativeTo: .caption))
                }
                .buttonStyle(.borderless)
                .pointingHandCursor()
                .padding(8)
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
                loadSortFromCurrentWatchlist()
                Task {
                    await stockService.ensureSparklines(for: storageService.watchlist)
                }
            }
            .onChange(of: storageService.selectedWatchlistId) { _, _ in
                loadSortFromCurrentWatchlist()
                Task {
                    await stockService.ensureSparklines(for: storageService.watchlist)
                }
            }
            .onChange(of: storageService.watchlist) { _, newWatchlist in
                Task {
                    await stockService.ensureSparklines(for: newWatchlist)
                }
            }
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
                                }
                            }) {
                                Text(wl.name)
                                    .font(.inter(11, weight: selected ? .bold : .medium, relativeTo: .caption))
                                    .foregroundColor(selected ? .white : DS.ink)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
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
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                    .help("Create new watchlist")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            .onChange(of: storageService.selectedWatchlistId) { _, newId in
                if let newId {
                    withAnimation { proxy.scrollTo(newId, anchor: .center) }
                }
            }
        }
    }

    @ViewBuilder
    private func sortHeader(_ title: String, column: SortColumn) -> some View {
        Button(action: {
            if sortColumn == column {
                setSort(column, ascending: !sortAscending)
            } else {
                setSort(column, ascending: (column == .manual || column == .symbol))
            }
        }) {
            HStack(spacing: 2) {
                Text(title)
                if sortColumn == column {
                    Image(systemName: sortAscending ? "chevron.up" : "chevron.down")
                        .font(.inter(8, relativeTo: .caption2))
                }
            }
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
    }

    @ViewBuilder
    private func watchlistContextMenu(symbol: String) -> some View {
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
                if sortColumn != .manual || !sortAscending {
                    sortColumn = .manual
                    sortAscending = true
                }
                moveSymbolInWatchlist(symbol, by: -1)
            } label: {
                Label("Move Up", systemImage: "arrow.up")
            }
            .disabled(idx == 0)

            Button {
                if sortColumn != .manual || !sortAscending {
                    sortColumn = .manual
                    sortAscending = true
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

    private var symbolCell: some View {
        let isDisplayAsset = StockService.isDisplayNameAsset(quote.symbol)
        return HStack(spacing: 5) {
            SymbolLogo(symbol: quote.symbol, size: 20)
            VStack(alignment: .leading, spacing: 0) {
                // Single stocks / ETFs keep the raw ticker as the primary label;
                // indices, FX pairs, and futures use their conventional name.
                Text(isDisplayAsset ? quote.displayName : quote.symbol)
                    .font(.inter(12, relativeTo: .body).monospacedDigit())
                    .fontWeight(.bold)
                    .lineLimit(1)
                if storageService.showCompanyName {
                    Text(isDisplayAsset ? quote.symbol : quote.name)
                        .font(.inter(9, relativeTo: .caption))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .frame(width: 110, alignment: .leading)
    }

    private var priceCell: some View {
        let displayPrice = quote.price
        return VStack(alignment: .trailing, spacing: 1) {
            Text(StorageService.formatCompactNumber(displayPrice, decimals: storageService.resolvedPriceDecimals(symbol: quote.symbol, price: displayPrice)))
                .font(.inter(12, relativeTo: .body).monospacedDigit())
                .fontWeight(.medium)
            Text(String(format: "%+.\(storageService.percentDecimals)f%%", quote.changePercent))
                .font(.inter(10, relativeTo: .caption).monospacedDigit())
                .fontWeight(.semibold)
                .foregroundColor(quote.isPositive ? DS.up : DS.down)
        }
    }

    @ViewBuilder
    private var changeCell: some View {
        Text((quote.change >= 0 ? "+" : "") + StorageService.formatCompactNumber(quote.change, decimals: storageService.resolvedPriceDecimals(symbol: quote.symbol, price: quote.change)))
            .font(.inter(12, relativeTo: .body).monospacedDigit())
            .fontWeight(.medium)
            .foregroundColor(quote.isPositive ? DS.up : DS.down)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }

    private var extCell: some View {
        let extPrice = (quote.isExtendedHours) ? quote.effectivePrice : nil
        let extPct = extPrice == nil ? nil : quote.extendedChangePercent
        let extLabel = extPrice == nil ? nil : quote.marketStateLabel

        return VStack(alignment: .trailing, spacing: 1) {
            if let extPrice {
                Text(StorageService.formatCompactNumber(extPrice, decimals: storageService.resolvedPriceDecimals(symbol: quote.symbol, price: extPrice)))
                    .font(.inter(12, relativeTo: .body).monospacedDigit())
                    .fontWeight(.medium)
                    .foregroundColor(.primary)
            } else {
                Text("—")
                    .font(.inter(12, relativeTo: .body).monospacedDigit())
                    .foregroundColor(.secondary)
            }
            if let extPct {
                Text(String(format: "%@%+.\(storageService.percentDecimals)f%%", (extLabel?.isEmpty ?? true) ? "" : "\(extLabel!) ", extPct))
                    .font(.inter(9, relativeTo: .caption2).monospacedDigit())
                    .foregroundColor(extPct >= 0 ? DS.up : DS.down)
            } else {
                Text("—")
                    .font(.inter(9, relativeTo: .caption2).monospacedDigit())
                    .foregroundColor(.secondary)
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            symbolCell

            // Col 2: 30D Sparkline
            if storageService.showWatchlistSparkline {
                Sparkline(symbol: quote.symbol, days: 30, width: 64, height: 22)
            }

            // Col 3: Price
            if storageService.showExtendedHours || storageService.showAbsoluteChange {
                priceCell.frame(width: 78, alignment: .trailing)
            } else {
                priceCell.frame(maxWidth: .infinity, alignment: .trailing)
            }

            // Col 4: Change
            if storageService.showAbsoluteChange {
                if storageService.showExtendedHours {
                    changeCell.frame(width: 60, alignment: .trailing)
                } else {
                    changeCell.frame(maxWidth: .infinity, alignment: .trailing)
                }
            }

            // Col 5: Ext
            if storageService.showExtendedHours {
                extCell.frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
    }
}
