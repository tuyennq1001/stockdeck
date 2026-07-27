import SwiftUI

struct WatchlistView: View {
    @EnvironmentObject var stockService: StockService
    @EnvironmentObject var storageService: StorageService
    @Binding var showSearch: Bool
    @State private var showNewWatchlistAlert = false
    @State private var newWatchlistName = ""
    @State private var renamingWatchlist: Watchlist? = nil
    @State private var renameWatchlistName = ""

    enum SortColumn {
        case manual, symbol, price, change
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
            case .change:
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
                    sortHeader("#", column: .manual)
                        .frame(width: 20, alignment: .leading)
                    sortHeader("Symbol", column: .symbol)
                        .frame(width: 70, alignment: .leading)
                    sortHeader("Price", column: .price)
                        .frame(maxWidth: .infinity)
                    sortHeader("Change", column: .change)
                        .frame(width: 110, alignment: .trailing)
                }
                .font(.inter(10, weight: .medium, relativeTo: .caption))
                .foregroundColor(.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 4)

                Divider()

            List {
                ForEach(filteredSymbols, id: \.self) { symbol in
                    if let quote = stockService.quotes[symbol] {
                        QuoteRow(quote: quote)
                            .contextMenu {
                                watchlistContextMenu(symbol: symbol)
                            }
                    } else {
                        HStack {
                            Text(symbol)
                                .font(.inter(13, relativeTo: .body).monospacedDigit())
                            Spacer()
                            ProgressView()
                                .scaleEffect(0.6)
                        }
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
                        .contextMenu {
                            Button("Rename…") {
                                renamingWatchlist = wl
                                renameWatchlistName = wl.name
                            }
                            if storageService.watchlists.count > 1 {
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
            Divider()
        }
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
                    Text("Avg price").font(.inter(10, relativeTo: .caption)).foregroundColor(.secondary)
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

    private var displayCurrency: String {
        let pref = storageService.stockPriceCurrency
        return pref.isEmpty ? quote.currency : pref
    }

    private var priceRate: Double {
        stockService.priceRate(from: quote.currency)
    }

    private var currSymbol: String {
        StorageService.currencySymbol(for: displayCurrency)
    }

    var body: some View {
        HStack(spacing: 0) {
            // Col 1: Symbol + name
            VStack(alignment: .leading, spacing: 1) {
                Text(quote.symbol)
                    .font(.inter(13, relativeTo: .body).monospacedDigit())
                    .fontWeight(.bold)
                if storageService.showCompanyName {
                    Text(quote.name)
                        .font(.inter(10, relativeTo: .caption))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(width: 80, alignment: .leading)

            // Col 2: Price + day range
            VStack(spacing: 1) {
                HStack(spacing: 3) {
                    Text("\(currSymbol)\(StorageService.formatNumber(quote.displayPrice(extendedHours: storageService.showExtendedHours) * priceRate, decimals: storageService.resolvedPriceDecimals(symbol: quote.symbol, price: quote.displayPrice(extendedHours: storageService.showExtendedHours) * priceRate)))")
                        .font(.inter(13, relativeTo: .body).monospacedDigit())
                        .fontWeight(.medium)
                    if storageService.showExtendedHours, quote.isExtendedHours, !quote.marketStateLabel.isEmpty {
                        Text(quote.marketStateLabel)
                            .font(.inter(9, weight: .semibold, relativeTo: .caption2))
                            .foregroundColor(.white)
                            .padding(.horizontal, 3)
                            .padding(.vertical, 1)
                            .background(
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(quote.marketState.hasPrefix("PRE") ? DS.gold : DS.palette[3])
                            )
                    }
                }
                if storageService.showDayRange, let high = quote.dayHigh, let low = quote.dayLow {
                    let rangeDecimals = storageService.resolvedPriceDecimals(symbol: quote.symbol, price: low * priceRate)
                    Text("\(StorageService.formatNumber(low * priceRate, decimals: rangeDecimals)) – \(StorageService.formatNumber(high * priceRate, decimals: rangeDecimals))")
                        .font(.inter(10, relativeTo: .caption).monospacedDigit())
                        .foregroundColor(.secondary)
                }
                if storageService.show52WeekBar,
                   let pos = quote.fiftyTwoWeekPosition,
                   let low = quote.fiftyTwoWeekLow, let high = quote.fiftyTwoWeekHigh {
                    HStack(spacing: 4) {
                        Text(StorageService.formatNumber(low * priceRate, decimals: 0))
                            .font(.inter(8, relativeTo: .caption2).monospacedDigit())
                            .foregroundColor(.secondary)
                        RangeBar(position: pos)
                            .frame(width: 56)
                        Text(StorageService.formatNumber(high * priceRate, decimals: 0))
                            .font(.inter(8, relativeTo: .caption2).monospacedDigit())
                            .foregroundColor(.secondary)
                    }
                    .help("52-week range")
                }
            }
            .frame(maxWidth: .infinity)

            // Col 3: Change
            VStack(alignment: .trailing, spacing: 1) {
                if storageService.showAbsoluteChange {
                    Text(StorageService.formatAmount(quote.change * priceRate, symbol: currSymbol, signed: true))
                        .font(.inter(13, relativeTo: .body).monospacedDigit())
                        .fontWeight(.medium)
                        .foregroundColor(quote.isPositive ? DS.up : DS.down)
                }
                Text(String(format: "%.\(storageService.percentDecimals)f%%", quote.changePercent))
                    .font(.inter(10, relativeTo: .caption).monospacedDigit())
                    .foregroundColor(quote.isPositive ? DS.up : DS.down)

                if storageService.showExtendedHours,
                   let extChg = quote.extendedChange,
                   let extPct = quote.extendedChangePercent {
                    Text(String(format: "%+.2f (%.\(storageService.percentDecimals)f%%)", extChg * priceRate, extPct))
                        .font(.inter(10, relativeTo: .caption).monospacedDigit())
                        .foregroundColor(extChg >= 0 ? DS.up.opacity(0.8) : DS.down.opacity(0.8))
                }
            }
            .frame(width: 120, alignment: .trailing)
        }
        .padding(.vertical, 2)
    }
}
