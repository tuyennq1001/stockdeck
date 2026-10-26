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
    @State private var chartRange = "3M"
    @State private var listWidth: CGFloat = 300
    @State private var isListCollapsed = false
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
            return storageService.portfolios.first(where: { $0.id == id })?.holdings
                .filter { $0.quantity != 0 }.map(\.symbol) ?? []
        case .allPortfolios:
            var seen = Set<String>()
            return storageService.portfolios.flatMap(\.holdings)
                .filter { $0.quantity != 0 }
                .map(\.symbol)
                .filter { seen.insert(StockService.canonicalSymbol(for: $0)).inserted }
        }
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
                    }.onEnded { _ in listDragOrigin = nil })
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
                        }, selectedRange: $chartRange, showsRangePicker: true)
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
            Task {
                await stockService.ensurePriceHistory(for: symbol)
                await stockService.ensurePriceHistoryMax(for: symbol)
                if insiderService.isEligibleSymbol(symbol) { await insiderService.ensureTransactions(for: symbol) }
            }
        }
        .task {
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
            Button { isListCollapsed.toggle() } label: {
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
            Menu {
                Section("Watchlists") {
                    ForEach(storageService.watchlists) { watchlist in
                        Button {
                            source = .watchlist(watchlist.id)
                        } label: {
                            sourceMenuLabel(watchlist.name, selected: source == .watchlist(watchlist.id))
                        }
                    }
                }
                Section("Portfolios") {
                    Button {
                        source = .allPortfolios
                    } label: {
                        sourceMenuLabel("Tất cả danh mục", selected: source == .allPortfolios)
                    }
                    ForEach(storageService.portfolios) { portfolio in
                        Button {
                            source = .portfolio(portfolio.id)
                        } label: {
                            sourceMenuLabel(portfolio.name, selected: source == .portfolio(portfolio.id))
                        }
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: sourceIcon)
                        .foregroundStyle(DS.brand)
                    Text(sourceTitle)
                        .font(.inter(13, weight: .semibold, relativeTo: .body))
                        .foregroundStyle(DS.ink)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(DS.inkTertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .padding(12)
            }
            .menuStyle(.borderlessButton)
            .help("Chọn Watchlist hoặc Portfolio")
            .accessibilityLabel("Nguồn: \(sourceTitle)")

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

    private var sourceIcon: String {
        switch source {
        case .watchlist: "star"
        case .portfolio, .allPortfolios: "briefcase"
        }
    }

    @ViewBuilder
    private func sourceMenuLabel(_ title: String, selected: Bool) -> some View {
        HStack {
            Text(title)
            Spacer()
            if selected { Image(systemName: "checkmark") }
        }
    }

    private func symbols(for source: SuperchartSource) -> [String] {
        switch source {
        case .watchlist(let id): return storageService.watchlists.first(where: { $0.id == id })?.symbols ?? []
        case .portfolio(let id): return storageService.portfolios.first(where: { $0.id == id })?.holdings.filter { $0.quantity != 0 }.map(\.symbol) ?? []
        case .allPortfolios:
            var seen = Set<String>()
            return storageService.portfolios.flatMap(\.holdings).filter { $0.quantity != 0 }.map(\.symbol)
                .filter { seen.insert(StockService.canonicalSymbol(for: $0)).inserted }
        }
    }
}
