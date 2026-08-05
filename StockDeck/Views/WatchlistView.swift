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
    @State private var addToPortfolio: (symbol: String, portfolioId: UUID)? = nil
    @State private var alertSymbol: String? = nil
    @State private var sortColumn: SortColumn = .manual
    @State private var sortAscending: Bool = true
    @State private var confirmDeleteWatchlist: Watchlist? = nil
    @State private var confirmRemoveSymbol: String? = nil

    enum SortColumn {
        case manual, symbol, price, absoluteChange, changePercent
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
                HStack(spacing: 0) {
                    sortHeader("Symbol", column: .symbol)
                        .frame(width: 105, alignment: .center)
                    sortHeader("Price", column: .price)
                        .frame(width: 70, alignment: .center)
                    if storageService.showAbsoluteChange {
                        sortHeader("Change", column: .absoluteChange)
                            .frame(width: 80, alignment: .center)
                    }
                    sortHeader("Today %", column: .changePercent)
                        .frame(width: 70, alignment: .center)
                    Text("Ext")
                        .font(.inter(10, weight: .medium, relativeTo: .caption))
                        .foregroundColor(.secondary)
                        .tracking(0.8)
                        .textCase(.uppercase)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                .font(.inter(10, weight: .medium, relativeTo: .caption))
                .foregroundColor(.secondary)
                .tracking(0.8)
                .textCase(.uppercase)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)

                Divider()

            List {
                ForEach(filteredSymbols, id: \.self) { symbol in
                    if let quote = stockService.quotes[symbol] {
                        QuoteRow(quote: quote)
                            .contentShape(Rectangle())
                            .pointingHandCursor()
                            .contextMenu {
                                watchlistContextMenu(symbol: symbol)
                            }
                    } else {
                        // Placeholder row matches QuoteRow's column structure so
                        // the symbol column stays aligned while data is loading.
                        HStack(spacing: 0) {
                            HStack(spacing: 5) {
                                SymbolLogo(symbol: symbol, size: 20)
                                Text(StockService.beautifiedSymbol(symbol))
                                    .font(.inter(12, relativeTo: .body).monospacedDigit())
                                    .fontWeight(.bold)
                                    .lineLimit(1)
                            }
                            .frame(width: 105, alignment: .leading)

                            Color.clear
                                .frame(width: 70) // Price
                            if storageService.showAbsoluteChange {
                                Color.clear
                                    .frame(width: 80) // Change
                            }
                            Color.clear
                                .frame(width: 70) // Today %

                            ProgressView()
                                .scaleEffect(0.6)
                                .frame(maxWidth: .infinity, alignment: .trailing)
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
                .onDelete { offsets in
                    let currentList = filteredSymbols
                    let symbols = offsets.compactMap { idx in
                        idx < currentList.count ? currentList[idx] : nil
                    }
                    symbols.forEach { storageService.removeFromWatchlist($0) }
                }
                .onMove { indices, newOffset in
                    let currentList = filteredSymbols
                    if sortColumn != .manual || !sortAscending {
                        sortColumn = .manual
                        sortAscending = true
                    }
                    storageService.reorderWatchlist(fromOffsets: indices, toOffset: newOffset, currentProjections: currentList)
                }


            }
            .listStyle(.plain)

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
    }

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
                                confirmDeleteWatchlist = wl
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
                sortAscending.toggle()
            } else {
                sortColumn = column
                sortAscending = (column == .manual || column == .symbol)
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

struct WatchlistTabDropDelegate: DropDelegate {
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

    var body: some View {
        HStack(spacing: 0) {

            // Col 1: Logo + symbol + name
            let isDisplayAsset = StockService.isDisplayNameAsset(quote.symbol)
            HStack(spacing: 5) {
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
            .frame(width: 105, alignment: .leading)

            // Col 2: Price (regular closing price formatted compact, unified with Portfolio)
            let displayPrice = quote.price
            VStack(alignment: .trailing, spacing: 0) {
                Text(StorageService.formatCompactNumber(displayPrice, decimals: storageService.resolvedPriceDecimals(symbol: quote.symbol, price: displayPrice)))
                    .font(.inter(12, relativeTo: .body).monospacedDigit())
                    .fontWeight(.medium)
                if storageService.showDayRange, let high = quote.dayHigh, let low = quote.dayLow {
                    Text("\(StorageService.formatCompactNumber(low, decimals: storageService.resolvedPriceDecimals(symbol: quote.symbol, price: low))) – \(StorageService.formatCompactNumber(high, decimals: storageService.resolvedPriceDecimals(symbol: quote.symbol, price: high)))")
                        .font(.inter(9, relativeTo: .caption).monospacedDigit())
                        .foregroundColor(.secondary)
                }
            }
            .frame(width: 70, alignment: .trailing)

            // Col 3: Change (Absolute change value, follows valueDecimals/format settings)
            if storageService.showAbsoluteChange {
                Text((quote.change >= 0 ? "+" : "") + StorageService.formatCompactNumber(quote.change, decimals: storageService.resolvedPriceDecimals(symbol: quote.symbol, price: quote.change)))
                    .font(.inter(12, relativeTo: .body).monospacedDigit())
                    .fontWeight(.medium)
                    .foregroundColor(quote.isPositive ? DS.up : DS.down)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(width: 80, alignment: .trailing)
            }

            // Col 4: Today % (Percent change)
            Text(String(format: "%+.\(storageService.percentDecimals)f%%", quote.changePercent))
                .font(.inter(12, relativeTo: .body).monospacedDigit())
                .fontWeight(.bold)
                .foregroundColor(quote.isPositive ? DS.up : DS.down)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(width: 70, alignment: .trailing)

            // Col 5: Ext (Extended hours % change)
            VStack(alignment: .trailing, spacing: 0) {
                if storageService.showExtendedHours,
                   let extPct = quote.extendedChangePercent {
                    Text(String(format: "%+.\(storageService.percentDecimals)f%%", extPct))
                        .font(.inter(11, relativeTo: .caption).monospacedDigit())
                        .fontWeight(.medium)
                        .foregroundColor(extPct >= 0 ? DS.up : DS.down)
                } else {
                    Text("—")
                        .font(.inter(11, relativeTo: .caption).monospacedDigit())
                        .foregroundColor(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
    }
}
