import SwiftUI

enum SuperchartSource: Hashable, Identifiable {
    case watchlist(UUID)
    case portfolio(UUID)
    case allPortfolios

    var id: String {
        switch self {
        case .watchlist(let id): "watchlist:\(id.uuidString)"
        case .portfolio(let id): "portfolio:\(id.uuidString)"
        case .allPortfolios: "all-portfolios"
        }
    }
}

enum SuperchartPortfolioSymbolOrdering {
    struct Entry {
        let symbol: String
        let marketValue: Double?
    }

    static func orderedSymbols(from entries: [Entry]) -> [String] {
        struct Aggregate {
            let symbol: String
            let firstIndex: Int
            var marketValue: Double?
        }

        var aggregates: [String: Aggregate] = [:]
        for (index, entry) in entries.enumerated() {
            let key = StockService.canonicalSymbol(for: entry.symbol)
            guard !key.isEmpty else { continue }
            if var aggregate = aggregates[key] {
                if let current = aggregate.marketValue, let added = entry.marketValue,
                   current.isFinite, added.isFinite {
                    aggregate.marketValue = current + added
                } else {
                    aggregate.marketValue = nil
                }
                aggregates[key] = aggregate
            } else {
                let value = entry.marketValue.flatMap { $0.isFinite ? $0 : nil }
                aggregates[key] = Aggregate(symbol: entry.symbol, firstIndex: index, marketValue: value)
            }
        }

        return aggregates.values.sorted { lhs, rhs in
            switch (lhs.marketValue, rhs.marketValue) {
            case let (left?, right?) where left != right:
                return left > right
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                return lhs.firstIndex < rhs.firstIndex
            }
        }.map(\.symbol)
    }
}

@MainActor
struct SuperchartWorkspaceView: View {
    @EnvironmentObject private var storageService: StorageService
    @Binding var selectedSymbol: String?
    @ObservedObject var stockService: StockService
    let initialSource: SuperchartSource
    let onSelectSource: (SuperchartSource) -> Void
    @ObservedObject private var insiderService = InsiderTradingService.shared

    @State private var source: SuperchartSource
    @State private var query = ""
    @State private var sourceQuery = ""
    @State private var isSourcePickerPresented = false
    @State private var sourcePickerShowsPortfolios = false
    @State private var chartRange = "3M"
    @State private var listWidth = UserDefaults.standard.object(forKey: "stockdeck.superchart.listWidth") as? CGFloat ?? 300
    @State private var isListCollapsed = UserDefaults.standard.bool(forKey: "stockdeck.superchart.listCollapsed")
    @State private var listDragOrigin: CGFloat?

    init(stockService: StockService, selectedSymbol: Binding<String?>, initialSource: SuperchartSource,
         onSelectSource: @escaping (SuperchartSource) -> Void) {
        self.stockService = stockService
        self._selectedSymbol = selectedSymbol
        self.initialSource = initialSource
        self.onSelectSource = onSelectSource
        self._source = State(initialValue: initialSource)
    }

    private var sourceSymbols: [String] {
        switch source {
        case .watchlist(let id):
            return storageService.watchlists.first(where: { $0.id == id })?.symbols ?? []
        case .portfolio(let id):
            guard let portfolio = storageService.portfolios.first(where: { $0.id == id }) else { return [] }
            return orderedPortfolioSymbols(in: [portfolio])
        case .allPortfolios:
            return orderedPortfolioSymbols(in: storageService.portfolios)
        }
    }

    private func orderedPortfolioSymbols(in portfolios: [Portfolio]) -> [String] {
        let entries = portfolios.flatMap(\.holdings).filter { $0.quantity != 0 }.map { holding in
            let quote = stockService.quotes[holding.symbol]
                ?? stockService.quotes[holding.symbol.uppercased()]
                ?? quoteByCanonical[StockService.canonicalSymbol(for: holding.symbol)]
            guard let quote, quote.price.isFinite else {
                return SuperchartPortfolioSymbolOrdering.Entry(symbol: holding.symbol, marketValue: nil)
            }
            let currency = stockService.detectedCurrency(for: holding.symbol)
            let fxRate = stockService.rate(from: currency, to: storageService.preferredCurrency)
            return SuperchartPortfolioSymbolOrdering.Entry(
                symbol: holding.symbol,
                marketValue: holding.marketValue(currentPrice: quote.price) * fxRate
            )
        }
        return SuperchartPortfolioSymbolOrdering.orderedSymbols(from: entries)
    }

    private var filteredSymbols: [String] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return sourceSymbols }
        return sourceSymbols.filter { $0.localizedCaseInsensitiveContains(needle) }
    }

    private var selectedQuote: StockQuote? {
        guard let symbol = selectedSymbol else { return nil }
        let canonical = StockService.canonicalSymbol(for: symbol)
        return stockService.quotes[symbol] ?? stockService.quotes[canonical] ?? quoteByCanonical[canonical]
    }

    private var quoteByCanonical: [String: StockQuote] {
        stockService.quotes.values.reduce(into: [:]) { result, quote in
            let key = StockService.canonicalSymbol(for: quote.symbol)
            if result[key] == nil { result[key] = quote }
        }
    }

    private var selectedHistory: [PricePoint] {
        guard let symbol = selectedSymbol else { return [] }
        let canonical = StockService.canonicalSymbol(for: symbol)
        return stockService.priceHistory[symbol] ?? stockService.priceHistory[canonical] ?? []
    }

    private var selectedMaxHistory: [PricePoint] {
        guard let symbol = selectedSymbol else { return [] }
        let canonical = StockService.canonicalSymbol(for: symbol)
        return stockService.priceHistoryMax[symbol] ?? stockService.priceHistoryMax[canonical] ?? []
    }

    private var selectedTargetPrice: Double? {
        guard let symbol = selectedSymbol else { return nil }
        return storageService.buyTarget(for: symbol)?.targetPrice
    }

    private var selectedInsiderMarkers: [LightweightChartMarker] {
        guard storageService.showInsiderMarkers, let symbol = selectedSymbol,
              insiderService.hasExecutedChartTrades(for: symbol) else { return [] }
        let history = selectedMaxHistory.isEmpty ? selectedHistory : selectedMaxHistory
        let transactions = insiderService.getTransactions(for: symbol,
            startDate: history.first?.date, endDate: history.last?.date,
            openMarketOnly: storageService.insiderOpenMarketOnly)
            .filter { $0.isOpenMarket && !$0.isPendingPlan && $0.shares > 0 }
            .filter { !storageService.excludeInsider10b51 || !$0.isRule10b51 }
        let groups = Dictionary(grouping: transactions) { transaction in
            "\(LightweightChartMath.tradingDay(transaction.transactionDate, symbol: symbol))_\(transaction.isBuy)"
        }
        return groups.keys.sorted().compactMap { key in
            guard let group = groups[key], let trade = group.first else { return nil }
            return LightweightChartMarker(time: LightweightChartMath.tradingDay(trade.transactionDate, symbol: symbol),
                position: trade.isBuy ? "belowBar" : "aboveBar",
                color: trade.isBuy ? "#1a9b82" : "#d94b59",
                shape: trade.isBuy ? "arrowUp" : "arrowDown",
                text: "\(trade.isBuy ? "BUY" : "SELL")\(group.count > 1 ? " \(group.count)x" : "")")
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            symbolList
                .frame(width: isListCollapsed ? 0 : listWidth)
                .clipped()
                .opacity(isListCollapsed ? 0 : 1)
            if !isListCollapsed {
                Rectangle()
                    .fill(DS.hairline)
                    .frame(width: 4)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 1).onChanged { value in
                        if listDragOrigin == nil { listDragOrigin = listWidth }
                        listWidth = min(420, max(280, (listDragOrigin ?? listWidth) + value.translation.width))
                    }.onEnded { _ in listDragOrigin = nil; UserDefaults.standard.set(listWidth, forKey: "stockdeck.superchart.listWidth") })
                    .help("Kéo để đổi độ rộng danh sách")
            }

            VStack(spacing: 0) {
                chartHeader
                Divider()
                if let symbol = selectedSymbol {
                    LightweightPriceChartView(symbol: symbol, points: selectedHistory, maxPoints: selectedMaxHistory,
                        currency: selectedQuote?.currency ?? StockService.detectedCurrency(for: symbol),
                        visibleFrom: nil, markers: selectedInsiderMarkers, targetPrice: selectedTargetPrice,
                        isLoading: stockService.isLoading, retry: {
                            Task {
                                await stockService.ensurePriceHistory(for: symbol)
                                await stockService.ensurePriceHistoryMax(for: symbol)
                            }
                        }, selectedRange: $chartRange, showsRangePicker: true, surface: .superchart)
                        .padding(12)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView("Chọn một mã", systemImage: "chart.xyaxis.line",
                        description: Text("Chọn mã từ Watchlist hoặc Portfolio để xem biểu đồ."))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        }
        .background(DS.ground)
        .onChange(of: source) { _, newSource in
            UserDefaults.standard.set(newSource.id, forKey: "stockdeck.superchart.source")
            onSelectSource(newSource)
            let symbols = symbols(for: newSource)
            if let selectedSymbol, symbols.contains(where: {
                StockService.canonicalSymbol(for: $0) == StockService.canonicalSymbol(for: selectedSymbol)
            }) { return }
            self.selectedSymbol = symbols.first
        }
        .onChange(of: sourceSymbols) { _, symbols in
            if let selectedSymbol, symbols.contains(where: {
                StockService.canonicalSymbol(for: $0) == StockService.canonicalSymbol(for: selectedSymbol)
            }) { return }
            self.selectedSymbol = symbols.first
        }
        .onChange(of: initialSource) { _, newSource in source = newSource }
        .onChange(of: selectedSymbol) { _, symbol in
            guard let symbol else { return }
            UserDefaults.standard.set(symbol, forKey: "stockdeck.superchart.symbol")
            Task {
                await stockService.ensurePriceHistory(for: symbol)
                await stockService.ensurePriceHistoryMax(for: symbol)
                if insiderService.isEligibleSymbol(symbol) { await insiderService.ensureTransactions(for: symbol) }
            }
        }
        .task {
            if let sourceID = UserDefaults.standard.string(forKey: "stockdeck.superchart.source"),
               let savedSource = source(from: sourceID) { source = savedSource }
            if let saved = UserDefaults.standard.string(forKey: "stockdeck.superchart.symbol"),
               sourceSymbols.contains(where: { StockService.canonicalSymbol(for: $0) == StockService.canonicalSymbol(for: saved) }) {
                selectedSymbol = saved
            }
            if selectedSymbol == nil { selectedSymbol = sourceSymbols.first }
            if let selectedSymbol {
                await stockService.ensurePriceHistory(for: selectedSymbol)
                await stockService.ensurePriceHistoryMax(for: selectedSymbol)
                if insiderService.isEligibleSymbol(selectedSymbol) { await insiderService.ensureTransactions(for: selectedSymbol) }
            }
        }
    }

    private var chartHeader: some View {
        HStack(spacing: 12) {
            Button { isListCollapsed.toggle(); UserDefaults.standard.set(isListCollapsed, forKey: "stockdeck.superchart.listCollapsed") } label: {
                Image(systemName: isListCollapsed ? "sidebar.right" : "sidebar.left")
                    .foregroundStyle(DS.inkSecondary)
            }
            .buttonStyle(.plain)
            .help(isListCollapsed ? "Hiện danh sách mã" : "Thu gọn danh sách mã")
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: selectedSymbol ?? "—")
                    .font(.inter(20, weight: .bold, relativeTo: .title2))
                    .foregroundStyle(DS.ink)
                Text(selectedQuote?.name ?? "")
                    .font(DS.micro)
                    .foregroundStyle(DS.inkSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            if let quote = selectedQuote {
                VStack(alignment: .trailing, spacing: 3) {
                    Text(quote.price, format: .number.precision(.fractionLength(0...4)))
                        .font(.inter(17, weight: .bold, relativeTo: .headline).monospacedDigit())
                        .foregroundStyle(DS.ink)
                    Text(quote.changePercent / 100, format: .percent.precision(.fractionLength(2)))
                        .font(DS.micro.monospacedDigit())
                        .foregroundStyle(DS.pnlColor(quote.changePercent))
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var symbolList: some View {
        VStack(spacing: 0) {
            Button {
                if case .portfolio = source { sourcePickerShowsPortfolios = true }
                else if source == .allPortfolios { sourcePickerShowsPortfolios = true }
                else { sourcePickerShowsPortfolios = false }
                sourceQuery = ""
                isSourcePickerPresented = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: sourceIcon)
                        .foregroundStyle(DS.brand)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(sourceTitle)
                            .font(.inter(13, weight: .semibold, relativeTo: .body))
                            .foregroundStyle(DS.ink)
                            .lineLimit(1)
                        Text(sourceKindTitle)
                            .font(.inter(10, weight: .medium, relativeTo: .caption))
                            .foregroundStyle(DS.inkTertiary)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: isSourcePickerPresented ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(DS.inkTertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .padding(12)
            }
            .buttonStyle(.plain)
            .help("Chọn Watchlist hoặc Portfolio")
            .accessibilityLabel("Nguồn: \(sourceTitle), \(sourceKindTitle)")
            .popover(isPresented: $isSourcePickerPresented, arrowEdge: .top) {
                sourcePicker
            }

            TextField("Tìm trong nguồn…", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 12)
                .padding(.bottom, 10)

            HStack(spacing: 4) {
                Text("Symbol").frame(maxWidth: .infinity, alignment: .leading)
                Text("Last").frame(width: 76, alignment: .trailing)
                Text("Chg%").frame(width: 60, alignment: .trailing)
                Text("Ext%").frame(width: 56, alignment: .trailing)
            }
            .font(.inter(10, weight: .medium, relativeTo: .caption))
            .foregroundStyle(DS.inkTertiary)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(filteredSymbols, id: \.self) { symbol in row(symbol) }
                }
            }
            if filteredSymbols.isEmpty {
                ContentUnavailableView(query.isEmpty ? "Nguồn đang trống" : "Không tìm thấy mã",
                    systemImage: query.isEmpty ? "tray" : "magnifyingglass",
                    description: Text(query.isEmpty ? "Thêm mã vào nguồn trong Bảng." : "Thử mã khác trong nguồn này."))
            }
        }
        .background(DS.ground)
    }

    private func row(_ symbol: String) -> some View {
        let canonical = StockService.canonicalSymbol(for: symbol)
        let quote = stockService.quotes[symbol] ?? stockService.quotes[canonical] ?? quoteByCanonical[canonical]
        let selected = StockService.canonicalSymbol(for: selectedSymbol ?? "") == canonical
        return Button { selectedSymbol = symbol } label: {
            HStack(spacing: 4) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: symbol).font(.inter(12, weight: .semibold, relativeTo: .body)).foregroundStyle(DS.ink)
                    if let name = quote?.name, name != symbol {
                        Text(name).font(DS.micro).foregroundStyle(DS.inkTertiary).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(quote.map {
                    "\(StorageService.currencySymbol(for: $0.currency))\(StorageService.formatNumber($0.price, decimals: StorageService.defaultDecimals(for: $0.currency)))"
                } ?? "—")
                    .font(.inter(11, weight: .medium, relativeTo: .caption).monospacedDigit())
                    .foregroundStyle(DS.ink).frame(width: 76, alignment: .trailing)
                Text(quote.map { ($0.changePercent / 100).formatted(.percent.precision(.fractionLength(2))) } ?? "—")
                    .font(.inter(10, weight: .medium, relativeTo: .caption).monospacedDigit())
                    .foregroundStyle(quote.map { DS.pnlColor($0.changePercent) } ?? DS.inkTertiary)
                    .frame(width: 60, alignment: .trailing)
                Text(quote?.extendedChangePercent.map { ($0 / 100).formatted(.percent.precision(.fractionLength(2))) } ?? "—")
                    .font(.inter(10, weight: .medium, relativeTo: .caption).monospacedDigit())
                    .foregroundStyle(DS.inkSecondary).frame(width: 56, alignment: .trailing)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            .background(selected ? DS.brand.opacity(0.10) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) { Rectangle().fill(DS.hairline).frame(height: 1) }
    }

    private var sourceTitle: String {
        switch source {
        case .watchlist(let id): return storageService.watchlists.first(where: { $0.id == id })?.name ?? "Watchlist"
        case .portfolio(let id): return storageService.portfolios.first(where: { $0.id == id })?.name ?? "Portfolio"
        case .allPortfolios: return "Tất cả danh mục"
        }
    }

    private var sourceKindTitle: String {
        switch source {
        case .watchlist: "Theo dõi"
        case .portfolio, .allPortfolios: "Danh mục"
        }
    }

    private var sourcePicker: some View {
        VStack(spacing: 10) {
            Picker("Loại nguồn", selection: $sourcePickerShowsPortfolios) {
                Text("Theo dõi").tag(false)
                Text("Danh mục").tag(true)
            }
            .pickerStyle(.segmented)

            TextField("Tìm danh sách…", text: $sourceQuery)
                .textFieldStyle(.roundedBorder)

            ScrollView {
                LazyVStack(spacing: 2) {
                    if sourcePickerShowsPortfolios {
                        if matchesSourceQuery("Tất cả danh mục") {
                            sourcePickerRow("Tất cả danh mục", icon: "briefcase",
                                            selected: source == .allPortfolios) {
                                selectSource(.allPortfolios)
                            }
                        }
                        if storageService.portfolios.filter({ matchesSourceQuery($0.name) }).isEmpty,
                           !matchesSourceQuery("Tất cả danh mục") {
                            ContentUnavailableView("Không tìm thấy danh mục", systemImage: "magnifyingglass")
                        }
                        ForEach(storageService.portfolios.filter { matchesSourceQuery($0.name) }) { portfolio in
                            sourcePickerRow(portfolio.name, icon: "briefcase",
                                            selected: source == .portfolio(portfolio.id)) {
                                selectSource(.portfolio(portfolio.id))
                            }
                        }
                    } else {
                        if storageService.watchlists.filter({ matchesSourceQuery($0.name) }).isEmpty {
                            ContentUnavailableView("Không tìm thấy danh sách", systemImage: "magnifyingglass")
                        }
                        ForEach(storageService.watchlists.filter { matchesSourceQuery($0.name) }) { watchlist in
                            sourcePickerRow(watchlist.name, icon: "star",
                                            selected: source == .watchlist(watchlist.id)) {
                                selectSource(.watchlist(watchlist.id))
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: 300)
        }
        .padding(12)
        .frame(width: 300)
    }

    private func matchesSourceQuery(_ name: String) -> Bool {
        let needle = sourceQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return needle.isEmpty || name.localizedCaseInsensitiveContains(needle)
    }

    private func selectSource(_ newSource: SuperchartSource) {
        source = newSource
        isSourcePickerPresented = false
        sourceQuery = ""
    }

    private func sourcePickerRow(_ title: String, icon: String, selected: Bool,
                                 action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(selected ? DS.brand : DS.inkTertiary)
                    .frame(width: 18)
                Text(title)
                    .font(.inter(12, weight: selected ? .semibold : .regular, relativeTo: .body))
                    .foregroundStyle(selected ? DS.brand : DS.ink)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(DS.brand)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 32)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? DS.brand.opacity(0.10) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var sourceIcon: String {
        switch source {
        case .watchlist: "star"
        case .portfolio, .allPortfolios: "briefcase"
        }
    }

    private func symbols(for source: SuperchartSource) -> [String] {
        switch source {
        case .watchlist(let id): return storageService.watchlists.first(where: { $0.id == id })?.symbols ?? []
        case .portfolio(let id):
            guard let portfolio = storageService.portfolios.first(where: { $0.id == id }) else { return [] }
            return orderedPortfolioSymbols(in: [portfolio])
        case .allPortfolios: return orderedPortfolioSymbols(in: storageService.portfolios)
        }
    }

    private func source(from id: String) -> SuperchartSource? {
        if id == "all-portfolios" { return .allPortfolios }
        let parts = id.split(separator: ":", maxSplits: 1)
        guard parts.count == 2, let uuid = UUID(uuidString: String(parts[1])) else { return nil }
        switch parts[0] {
        case "watchlist" where storageService.watchlists.contains(where: { $0.id == uuid }): return .watchlist(uuid)
        case "portfolio" where storageService.portfolios.contains(where: { $0.id == uuid }): return .portfolio(uuid)
        default: return nil
        }
    }
}
