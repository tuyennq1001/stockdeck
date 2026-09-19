import SwiftUI
import Charts

/// A holding priced in the preferred currency, with the derived figures the
/// overview needs.
struct ValuedHolding: Identifiable {
    let id: UUID
    let portfolioId: UUID
    let holding: Holding
    let quote: StockQuote
    let value: Double
    let cost: Double
    let dayChangePercent: Double
    let type: String

    var symbol: String { holding.symbol }
    var name: String {
        if quote.isJapaneseFund {
            return quote.displayName
        }
        return quote.name.isEmpty ? holding.symbol : quote.name
    }
    var pnl: Double { value - cost }
    var pnlPercent: Double { abs(cost) >= 0.01 ? (pnl / abs(cost)) * 100 : 0 }
}

/// Session cache for Performance & Benchmark values so they evaluate ONCE
/// per session / scope and never re-compute on real-time quote updates.
enum PerformanceBenchmarkCache {
    private static var cache: [String: (portfolio: [PortfolioOverview.PerformancePeriod: Double?], spx: [PortfolioOverview.PerformancePeriod: Double?])] = [:]
    private static let lock = NSLock()

    static func performance(for scopeKey: String,
                            compute: () -> (portfolio: [PortfolioOverview.PerformancePeriod: Double?], spx: [PortfolioOverview.PerformancePeriod: Double?]))
    -> (portfolio: [PortfolioOverview.PerformancePeriod: Double?], spx: [PortfolioOverview.PerformancePeriod: Double?]) {
        lock.lock()
        if let existing = cache[scopeKey],
           existing.spx.values.contains(where: { $0 != nil }),
           existing.portfolio.values.contains(where: { $0 != nil }) {
            lock.unlock()
            return existing
        }
        lock.unlock()

        let result = compute()

        if result.spx.values.contains(where: { $0 != nil }) && result.portfolio.values.contains(where: { $0 != nil }) {
            lock.lock()
            cache[scopeKey] = result
            lock.unlock()
        }

        return result
    }
}

/// Session cache for Money-weighted return (XIRR) values so they evaluate ONCE
/// per session / scope and never re-compute on real-time quote updates.
enum MoneyWeightedReturnCache {
    private static var cache: [String: InvestmentEffectiveness.Result] = [:]
    private static let lock = NSLock()

    static func result(for scopeKey: String, compute: () -> InvestmentEffectiveness.Result) -> InvestmentEffectiveness.Result {
        lock.lock()
        if let existing = cache[scopeKey], (existing.portfolioXIRR != nil || existing.isYoungerThan30Days || existing.excludedHoldingsCount > 0) {
            lock.unlock()
            return existing
        }
        lock.unlock()

        let res = compute()
        if res.portfolioXIRR != nil || res.benchmarkXIRR != nil || res.isYoungerThan30Days {
            lock.lock()
            cache[scopeKey] = res
            lock.unlock()
        }
        return res
    }
}

/// Session cache for the monthly P&L table so the (cheap but repeated) recompute
/// only happens once per scope — holdings/rate changes bust the key naturally.
enum MonthlyPnlCache {
    private static var cache: [String: [MonthlyPnlRow]] = [:]
    private static let lock = NSLock()

    static func rows(for key: String, compute: () -> [MonthlyPnlRow]) -> [MonthlyPnlRow] {
        lock.lock()
        if let existing = cache[key] {
            lock.unlock()
            return existing
        }
        lock.unlock()

        let result = compute()
        lock.lock()
        cache[key] = result
        lock.unlock()
        return result
    }
}

/// Session cache for the daily P&L table (same contract as `MonthlyPnlCache`).
enum DailyPnlCache {
    private static var cache: [String: [DailyPnlRow]] = [:]
    private static let lock = NSLock()

    static func rows(for key: String, compute: () -> [DailyPnlRow]) -> [DailyPnlRow] {
        lock.lock()
        if let existing = cache[key] {
            lock.unlock()
            return existing
        }
        lock.unlock()

        let result = compute()
        lock.lock()
        cache[key] = result
        lock.unlock()
        return result
    }
}

/// Which P&L view the portfolio overview shows: per-day (Daily, default tab) or
/// per-month (Monthly). Raw values double as the tab labels.
enum PnlViewMode: String, CaseIterable {
    case daily = "Daily PnL"
    case monthly = "Monthly PnL"

    init?(savedValue: String) {
        if savedValue == "Daily P&L" || savedValue == "Daily PnL" {
            self = .daily
        } else if savedValue == "Monthly P&L" || savedValue == "Monthly PnL" {
            self = .monthly
        } else {
            self.init(rawValue: savedValue)
        }
    }
}

/// Time window for the daily P&L table: how many trailing calendar days of
/// per-day bars to compute and render.
enum DailyPnlRange: String, CaseIterable {
    case threeMonths = "3M"
    case sixMonths = "6M"
    case oneYear = "1Y"

    var dayCount: Int {
        switch self {
        case .threeMonths: return 90
        case .sixMonths: return 180
        case .oneYear: return 365
        }
    }
}

/// Time window for the monthly P&L table. `all` extends as far back as the
/// price history actually covers, using real data only.
enum MonthlyPnlRange: String, CaseIterable {
    case oneYear = "1Y"
    case threeYears = "3Y"
    case all = "All"

    /// Explicit month window, or nil for `all` (derived from real history).
    var fixedMonthCount: Int? {
        switch self {
        case .oneYear: return 12
        case .threeYears: return 36
        case .all: return nil
        }
    }
}

struct PortfolioOverview: View {
    let stockService: StockService
    @EnvironmentObject var storageService: StorageService
    @Environment(\.editHoldingAction) private var editHoldingAction
    @Environment(\.addHoldingAction) private var addHoldingAction
    @Environment(\.portfolioActions) private var portfolioActions

    let scope: PortfolioScope
    @State private var viewModel: PortfolioViewModel

    init(scope: PortfolioScope, stockService: StockService) {
        self.stockService = stockService
        self.scope = scope
        self._viewModel = State(initialValue: PortfolioViewModel(scope: scope))
    }


    enum PositionSortColumn: String, CaseIterable {
        case manual
        case symbol
        case avgPrice
        case price
        case extended
        case cost
        case value
        case todayPnl
        case pnl
        case shares
        case weight
    }

    enum PositionViewTab: String, CaseIterable {
        case active = "Active"
        case closed = "Closed"
        case transactions = "Transactions"
    }

    struct TargetCloseHolding: Identifiable {
        let id = UUID()
        let portfolioId: UUID
        let holding: Holding
        let quote: StockQuote?
    }

    @State private var positionViewTab: PositionViewTab = .active
    @State private var activeCurrentPage: Int = 1
    @State private var activePageSize: Int = 10
    @State private var targetCloseHolding: TargetCloseHolding? = nil
    @State private var sortColumn: PositionSortColumn = .weight
    @State private var sortAscending: Bool = false
    @State private var showColumnCustomizer = false
    @State private var chartRange: ChartRange = .all
    @State private var pnlViewMode: PnlViewMode = .daily
    @State private var dailyPnlRange: DailyPnlRange = .threeMonths
    @State private var monthlyPnlRange: MonthlyPnlRange = .threeYears
    @State private var confirmDeleteHolding: (holding: Holding, portfolioId: UUID)? = nil

    private var scopePortfolioId: UUID? {
        if case .portfolio(let id) = scope { return id }
        return nil
    }

    private var closedTradesCount: Int {
        viewModel.realizedStats.totalClosed
    }

    private var transactionsCount: Int {
        viewModel.transactionsCount
    }

    private var activeSymbolsCount: Int {
        viewModel.activeSymbolsCount
    }

    private var insertionOrderedSymbols: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for p in viewModel.portfolios {
            for h in p.holdings {
                let sym = h.symbol.uppercased()
                if !seen.contains(sym) {
                    seen.insert(sym)
                    result.append(sym)
                }
            }
        }
        return result
    }

    private func loadPositionSort(for key: String) {
        if let saved = storageService.positionSort(for: key),
           let col = PositionSortColumn(rawValue: saved.column) {
            sortColumn = col
            sortAscending = saved.ascending
        } else {
            sortColumn = .weight
            sortAscending = false
        }
    }

    private func loadPnlPreferences(for key: String) {
        if let savedDaily = storageService.dailyPnlRange(for: key),
           let range = DailyPnlRange(rawValue: savedDaily) {
            dailyPnlRange = range
        } else {
            dailyPnlRange = .threeMonths
        }
        if let savedMonthly = storageService.monthlyPnlRange(for: key),
           let range = MonthlyPnlRange(rawValue: savedMonthly) {
            monthlyPnlRange = range
        } else {
            monthlyPnlRange = .threeYears
        }
        if let savedMode = storageService.pnlViewMode(for: key),
           let mode = PnlViewMode(savedValue: savedMode) {
            pnlViewMode = mode
        } else {
            pnlViewMode = .daily
        }
    }

    private func setPositionSort(_ column: PositionSortColumn, ascending: Bool) {
        sortColumn = column
        sortAscending = ascending
        activeCurrentPage = 1
        storageService.setPositionSort(column: column.rawValue, ascending: ascending, for: scopeKey)
    }

    private func sortHeader(_ title: String, column: PositionSortColumn) -> some View {
        Button(action: {
            if sortColumn == column {
                setPositionSort(column, ascending: !sortAscending)
            } else {
                setPositionSort(column, ascending: (column == .symbol))
            }
        }) {
            HStack(spacing: 3) {
                Text(LocalizedStringKey(title))
                if sortColumn == column {
                    Image(systemName: sortAscending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(DS.brand)
                }
            }
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
    }

    /// Sort key for a dynamic portfolio column.
    private func sortColumn(for metric: PortfolioColumnMetric) -> PositionSortColumn {
        switch metric {
        case .avgPrice: return .avgPrice
        case .price, .change: return .price
        case .cost: return .cost
        case .value: return .value
        case .todayPnl: return .todayPnl
        case .totalPnl: return .pnl
        case .shares: return .shares
        case .lots: return .shares
        case .weight: return .weight
        }
    }

    /// Selected portfolio columns (rank # and Symbol stay fixed).
    private var selectedColumns: [PortfolioColumnMetric] {
        storageService.resolvedPortfolioColumns
    }

    /// Natural content width of the positions table (sum of ideal column widths),
    /// so columns keep a readable size and the table scrolls horizontally when
    /// the window is narrower instead of compressing the cells.
    private var positionsTableNaturalWidth: CGFloat {
        let rowPadding: CGFloat = 16
        let symbolIdealWidth: CGFloat = 200
        let metricIdealWidth: (PortfolioColumnMetric) -> CGFloat = { metric in
            switch metric {
            case .avgPrice, .price, .change: return 110
            case .cost, .value, .todayPnl, .totalPnl: return 120
            case .shares, .lots: return 100
            case .weight: return 115
            }
        }
        return rowPadding
            + PositionColumnWidth.number
            + symbolIdealWidth
            + selectedColumns.reduce(0) { $0 + metricIdealWidth($1) }
            + PositionColumnWidth.chevron
    }

    @ViewBuilder
    private func columnHeader(_ metric: PortfolioColumnMetric) -> some View {
        let column = sortColumn(for: metric)
        switch metric {
        case .avgPrice:
            sortHeader(metric.title, column: column)
                .frame(minWidth: PositionColumnWidth.priceMin, idealWidth: 110, maxWidth: 140, alignment: .trailing)
        case .price, .change:
            sortHeader(metric.title, column: column)
                .frame(minWidth: PositionColumnWidth.priceMin, idealWidth: 110, maxWidth: 140, alignment: .trailing)
        case .cost, .value, .todayPnl, .totalPnl:
            sortHeader(metric.title, column: column)
                .frame(minWidth: PositionColumnWidth.amountMin, idealWidth: 120, maxWidth: 160, alignment: .trailing)
        case .shares:
            sortHeader(metric.title, column: column)
                .frame(minWidth: PositionColumnWidth.sharesMin, idealWidth: 100, maxWidth: 130, alignment: .trailing)
        case .lots:
            sortHeader(metric.title, column: column)
                .frame(minWidth: PositionColumnWidth.sharesMin, idealWidth: 80, maxWidth: 110, alignment: .trailing)
        case .weight:
            sortHeader(metric.title, column: column)
                .frame(minWidth: PositionColumnWidth.weightMin, idealWidth: 80, maxWidth: 110, alignment: .trailing)
        }
    }

    // MARK: - Convenience accessors (all from viewModel, no recomputation)

    private var holdings: [ValuedHolding] { viewModel.sortedValuedHoldings }
    private func findHolding(by id: UUID) -> ValuedHolding? {
        for portfolio in storageService.portfolios {
            if let h = portfolio.holdings.first(where: { $0.id == id }) {
                let quote = stockService.quotes[h.symbol] ?? stockService.quotes[h.symbol.uppercased()] ?? StockQuote(
                    symbol: h.symbol, name: h.symbol, price: h.avgPrice, change: 0, changePercent: 0,
                    currency: stockService.detectedCurrency(for: h.symbol)
                )
                let price = quote.displayPrice(extendedHours: storageService.showExtendedHours)
                return ValuedHolding(
                    id: h.id,
                    portfolioId: portfolio.id,
                    holding: h,
                    quote: quote,
                    value: h.marketValue(currentPrice: price),
                    cost: h.costBasisLocal,
                    dayChangePercent: quote.changePercent,
                    type: storageService.type(for: h.symbol)
                )
            }
        }
        return nil
    }
    private var totalValue: Double { viewModel.totalValue }
    private var totalCost: Double { viewModel.totalCost }
    private var totalPnl: Double { viewModel.totalPnl }
    private var totalPnlPercent: Double { viewModel.totalPnlPercent }
    private var dayChangeValue: Double { viewModel.dayChangeValue }
    private var dayChangePercent: Double { viewModel.dayChangePercent }
    private var currencySymbol: String { viewModel.currencySymbol }
    private var decimals: Int { viewModel.decimals }
    private var portfolios: [Portfolio] { viewModel.portfolios }
    private var title: String { viewModel.title }
    private var scopeKey: String { viewModel.scopeKey }
    private var symbols: [String] { viewModel.symbols }
    private var earliestPurchaseDate: Date? { viewModel.earliestPurchaseDate }

    /// Snapshot series for the scope, merged by day when aggregating portfolios.
    private var series: [PortfolioSnapshot] {
        let logs = portfolios.map { storageService.snapshots(for: $0.id) }
        guard logs.contains(where: { !$0.isEmpty }) else { return [] }
        if logs.count == 1 { return logs[0] }
        var byDay: [Date: (value: Double, cost: Double)] = [:]
        for log in logs {
            for snap in log {
                let day = Calendar.current.startOfDay(for: snap.date)
                let existing = byDay[day] ?? (0, 0)
                byDay[day] = (existing.value + snap.totalValue, existing.cost + snap.totalCost)
            }
        }
        return byDay.map { PortfolioSnapshot(date: $0.key, totalValue: $0.value.value, totalCost: $0.value.cost) }
            .sorted { $0.date < $1.date }
    }

    /// Builds a market value curve from a given per-symbol price history
    /// (daily / hourly / 5-min) × current positions, in the preferred currency.
    private func valueSeries(from histBySymbol: [String: [PricePoint]]) -> [ValuePoint] {
        viewModel.valueSeries(from: histBySymbol)
    }

    /// Daily value curve (2y) for 1M/1Y; monthly full history for 3Y, 5Y, and "All".
    /// The market value curve drawn and used for period change calculations.
    /// Uses the unified valueSeries (real closing prices × current positions)
    /// representing the true market value trajectory of the portfolio.
    private var displaySeries: [ValuePoint] {
        viewModel.displaySeries(for: chartRange)
    }

    /// Evaluates benchmark matrix once per app session (not updating real-time).
    /// Uses ViewModel's session-cached result.
    private var cachedPerformance: (portfolio: [PerformancePeriod: Double?], spx: [PerformancePeriod: Double?]) {
        viewModel.cachedPerformance ?? ([:], [:])
    }

    private var moneyWeightedComparison: InvestmentEffectiveness.Result {
        viewModel.moneyWeightedResult ?? InvestmentEffectiveness.Result(
            portfolioXIRR: nil, benchmarkXIRR: nil, excludedHoldingsCount: 0, isYoungerThan30Days: false
        )
    }

    private var monthlyPnlRows: [MonthlyPnlRow] {
        viewModel.monthlyPnlRows(for: monthlyPnlRange)
    }

    private var dailyPnlRows: [DailyPnlRow] {
        viewModel.dailyPnlRows(for: dailyPnlRange)
    }

    var body: some View {
        PageScaffold(title, caption: "\(activeSymbolsCount) positions · \(storageService.preferredCurrency)", trailing: {
            HStack(spacing: 12) {
                portfolioMenu
                RefreshButton(isLoading: stockService.isLoading) {
                    Task {
                        await stockService.refreshAll(storageService: storageService)
                        viewModel.recomputeAll()
                    }
                }
            }
        }) {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.gap) {
                    heroCard
                    statRow
                    performanceMatrixCard
                    pnlCard
                    moneyWeightedReturnCard
                    allocationCard
                    HStack(alignment: .top, spacing: DS.gap) {
                        topGainersCard.frame(minWidth: 250, maxWidth: .infinity)
                        topLosersCard.frame(minWidth: 250, maxWidth: .infinity)
                    }
                    positionsCard.id("positions")
                    PortfolioAIReviewCard(scope: scope, viewModel: viewModel)
                        .id("aiReview")
                }
                .pageColumn()
                .padding(.top, 4)
            }
        }
        .navigationDestination(for: UUID.self) { id in
            if let h = holdings.first(where: { $0.id == id }) {
                HoldingDetailView(portfolioId: h.portfolioId, scope: scope,
                                  holding: h.holding, quote: h.quote)
            } else if let found = findHolding(by: id) {
                HoldingDetailView(portfolioId: found.portfolioId, scope: scope,
                                  holding: found.holding, quote: found.quote)
            }
        }
        .navigationTitle(title)
        .sheet(item: $targetCloseHolding) { target in
            CloseHoldingSheet(
                portfolioId: target.portfolioId,
                holding: target.holding,
                quote: target.quote,
                onDismiss: {
                    targetCloseHolding = nil
                    viewModel.recomputeAll()
                }
            )
            .environmentObject(storageService)
            .environmentObject(stockService)
        }
        .sheet(isPresented: $showColumnCustomizer) {
            PortfolioColumnCustomizer(initialColumns: storageService.resolvedPortfolioColumns) { columns in
                storageService.setPortfolioColumns(columns)
            }
        }
        .alert("Delete Holding", isPresented: Binding(get: { confirmDeleteHolding != nil }, set: { if !$0 { confirmDeleteHolding = nil } })) {
            Button("Cancel", role: .cancel) { confirmDeleteHolding = nil }
            Button("Delete", role: .destructive) {
                if let target = confirmDeleteHolding {
                    storageService.removeHolding(from: target.portfolioId, holdingId: target.holding.id)
                    viewModel.recomputeAll()
                }
                confirmDeleteHolding = nil
            }
        } message: {
            Text("Are you sure you want to delete \(confirmDeleteHolding?.holding.symbol ?? "")? This action cannot be undone.")
        }
        .onAppear {
            if let savedRaw = storageService.chartRange(for: scopeKey),
               let range = ChartRange(rawValue: savedRaw) {
                chartRange = range
            }
            loadPositionSort(for: scopeKey)
            loadPnlPreferences(for: scopeKey)
        }
        .task {
            viewModel.setup(stockService: stockService, storageService: storageService)
        }
        .onChange(of: chartRange) { _, newRange in
            storageService.setChartRange(newRange.rawValue, for: scopeKey)
        }
        .onChange(of: dailyPnlRange) { _, newRange in
            storageService.setDailyPnlRange(newRange.rawValue, for: scopeKey)
        }
        .onChange(of: monthlyPnlRange) { _, newRange in
            storageService.setMonthlyPnlRange(newRange.rawValue, for: scopeKey)
        }
        .onChange(of: pnlViewMode) { _, newMode in
            storageService.setPnlViewMode(newMode.rawValue, for: scopeKey)
        }
        .onChange(of: scopeKey) { _, newKey in
            if let savedRaw = storageService.chartRange(for: newKey),
               let range = ChartRange(rawValue: savedRaw) {
                chartRange = range
            } else {
                chartRange = .all
            }
            loadPositionSort(for: newKey)
            loadPnlPreferences(for: newKey)
        }
        .task(id: symbols) {
            // On window open: only the daily 10y series per symbol (the base the
            // estimated curve and benchmark are built from). The monthly "max"
            // series is derived locally from it; long-range data is fetched
            // lazily when the matching chart range is actually selected.
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await stockService.ensurePriceHistory(for: "^GSPC") }
                for symbol in symbols {
                    let s = symbol
                    group.addTask { await stockService.ensurePriceHistory(for: s) }
                }
            }
        }
        .task(id: "\(symbols.joined())-\(chartRange.rawValue)") {
            switch chartRange {
            case .week:
                await withTaskGroup(of: Void.self) { group in
                    for s in symbols {
                        let sym = s
                        group.addTask { await stockService.ensureIntradayWeek(for: sym) }
                    }
                }
            case .all:
                await withTaskGroup(of: Void.self) { group in
                    for s in symbols {
                        let sym = s
                        group.addTask { await stockService.ensureFullHistoryMax(for: sym) }
                    }
                }
            case .threeYears, .fiveYears:
                await withTaskGroup(of: Void.self) { group in
                    for s in symbols {
                        let sym = s
                        group.addTask { await stockService.ensurePriceHistoryMax(for: sym) }
                    }
                }
            default:
                await withTaskGroup(of: Void.self) { group in
                    for s in symbols {
                        let sym = s
                        group.addTask { await stockService.ensurePriceHistory(for: sym) }
                    }
                }
            }
        }
    }

    // MARK: - Hero (chart as the ground of the card)

    private var heroCard: some View {
        let perf = cachedPerformance
        let ds = displaySeries
        let useRealAllTime = chartRange == .all
        let periodValue: Double
        let periodPercent: Double
        let periodLabel: String

        if useRealAllTime {
            periodValue = totalPnl
            periodPercent = totalPnlPercent
            periodLabel = "all-time"
        } else if let p = chartRange.performancePeriod, let perfPct = perf.portfolio[p] ?? nil {
            periodPercent = perfPct
            periodValue = totalValue * (perfPct / 100.0)
            periodLabel = chartRange.changeLabel
        } else {
            periodValue = PortfolioPeriodChange.value(ds) ?? dayChangeValue
            periodPercent = PortfolioPeriodChange.percent(ds) ?? dayChangePercent
            periodLabel = PortfolioPeriodChange.percent(ds) != nil ? chartRange.changeLabel : "today"
        }
        
        let cagrVal = PortfolioPeriodChange.cagr(ds)
        let pillText: String
        if let cagrVal {
            pillText = String(format: "%+.\(decimals)f%% %@ (%.1f%% CAGR)", periodPercent, periodLabel, cagrVal)
        } else {
            pillText = String(format: "%+.\(decimals)f%% %@", periodPercent, periodLabel)
        }
        
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top) {
                    SectionLabel("Total value")
                    Spacer()
                    if !ds.isEmpty { rangePicker }
                }
                Text(StorageService.formatAmount(totalValue, symbol: currencySymbol, decimals: storageService.amountDecimals))
                    .font(DS.display).tracking(-0.5)
                    .foregroundStyle(DS.ink)
                    .contentTransition(.numericText())
                HStack(spacing: 10) {
                    ChangePill(value: periodValue, text: pillText)
                    if !useRealAllTime {
                        Text(String(format: "%@ (%+.\(decimals)f%%) all-time",
                                    StorageService.formatAmount(totalPnl, symbol: currencySymbol, decimals: storageService.amountDecimals, signed: true),
                                    totalPnlPercent))
                            .font(DS.caption.monospacedDigit())
                            .foregroundStyle(DS.pnlColor(totalPnl))
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 22)
            .padding(.bottom, 14)

            PortfolioHeroChartView(
                points: ds,
                chartRange: chartRange,
                currencySymbol: currencySymbol,
                amountDecimals: storageService.amountDecimals
            )
            .equatable()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(height: 300)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .premiumCard()
    }

    private var rangePicker: some View {
        SegmentedRangePicker(options: ChartRange.allCases, label: \.rawValue, selection: $chartRange)
    }

    @ViewBuilder private var portfolioMenu: some View {
        if case .portfolio(let id) = scope, let p = portfolios.first {
            let actions: [[DSMenuAction]] = p.isReadOnly ? [
                [ DSMenuAction(title: "Rename…", icon: "pencil") { portfolioActions.rename(id, p.name) },
                  DSMenuAction(title: "Notifications…", icon: "bell") { portfolioActions.notifications(id, p.name) } ],
                [ DSMenuAction(title: "Delete Portfolio", icon: "trash", destructive: true) { portfolioActions.delete(id) } ],
            ] : [
                [ DSMenuAction(title: "Add Holding…", icon: "plus") { portfolioActions.addHolding(id) },
                  DSMenuAction(title: "Rename…", icon: "pencil") { portfolioActions.rename(id, p.name) },
                  DSMenuAction(title: "Notifications…", icon: "bell") { portfolioActions.notifications(id, p.name) } ],
                [ DSMenuAction(title: "Delete Portfolio", icon: "trash", destructive: true) { portfolioActions.delete(id) } ],
            ]
            DSMenu(sections: actions) {
                Image(systemName: "ellipsis")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(DS.inkSecondary)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(DS.cardAlt))
            }
            .help("Portfolio actions — rename, notifications, delete")
        }
    }

    // MARK: - Stats

    private var realizedPnlStats: PortfolioViewModel.RealizedStats {
        viewModel.realizedStats
    }


    private var totalProfit: Double {
        totalPnl + realizedPnlStats.realizedPnl
    }

    private var totalProfitPercent: Double {
        let base = totalCost > 0 ? totalCost : realizedPnlStats.closedCost
        return base > 0 ? (totalProfit / base) * 100.0 : 0.0
    }

    private var statRow: some View {
        HStack(spacing: 12) {
            StatTile(
                label: "Total Profit",
                value: StorageService.formatAmount(totalProfit, symbol: currencySymbol, decimals: storageService.amountDecimals, signed: true),
                caption: realizedPnlStats.totalClosed > 0
                    ? "Unrealized + Realized"
                    : String(format: "%+.\(decimals)f%% on cost", totalPnlPercent),
                captionTint: realizedPnlStats.totalClosed > 0 ? DS.inkSecondary : DS.pnlColor(totalPnl),
                valueTint: DS.pnlColor(totalProfit),
                help: "Lifetime total profit (Realized P&L + Unrealized P&L)"
            )

            StatTile(
                label: "Unrealized P&L",
                value: StorageService.formatAmount(totalPnl, symbol: currencySymbol, decimals: storageService.amountDecimals, signed: true),
                caption: String(format: "%+.\(decimals)f%% · %d active", totalPnlPercent, activeSymbolsCount),
                captionTint: DS.pnlColor(totalPnl),
                valueTint: DS.pnlColor(totalPnl),
                help: "Floating profit/loss of currently active positions"
            )

            StatTile(
                label: "Realized P&L",
                value: StorageService.formatAmount(realizedPnlStats.realizedPnl, symbol: currencySymbol, decimals: storageService.amountDecimals, signed: true),
                caption: realizedPnlStats.totalClosed > 0
                    ? String(format: "%d closed · %.1f%% win", realizedPnlStats.totalClosed, realizedPnlStats.winRate)
                    : "No closed trades",
                captionTint: realizedPnlStats.winRate >= 50 ? DS.up : DS.inkSecondary,
                valueTint: DS.pnlColor(realizedPnlStats.realizedPnl),
                help: "Locked-in profit/loss from sold positions and win rate"
            )

            StatTile(
                label: "Today",
                value: StorageService.formatAmount(dayChangeValue, symbol: currencySymbol, decimals: storageService.amountDecimals, signed: true),
                caption: String(format: "%+.\(decimals)f%%", dayChangePercent),
                captionTint: DS.pnlColor(dayChangeValue),
                valueTint: DS.pnlColor(dayChangeValue),
                help: "Change since the previous close"
            )
        }
    }

    // MARK: - Performance & Benchmark Matrix

    enum PerformancePeriod: String, CaseIterable, Identifiable {
        case m1 = "1M"
        case m3 = "3M"
        case m6 = "6M"
        case ytd = "YTD"
        case y1 = "1Y"
        case y3 = "3Y"
        case y5 = "5Y"
        case y10 = "10Y"

        var id: String { rawValue }

        func cutoffDate() -> Date {
            let cal = Calendar.current
            let now = Date()
            switch self {
            case .m1: return cal.date(byAdding: .month, value: -1, to: now) ?? now
            case .m3: return cal.date(byAdding: .month, value: -3, to: now) ?? now
            case .m6: return cal.date(byAdding: .month, value: -6, to: now) ?? now
            case .ytd: return cal.date(from: cal.dateComponents([.year], from: now)) ?? now
            case .y1: return cal.date(byAdding: .year, value: -1, to: now) ?? now
            case .y3: return cal.date(byAdding: .year, value: -3, to: now) ?? now
            case .y5: return cal.date(byAdding: .year, value: -5, to: now) ?? now
            case .y10: return cal.date(byAdding: .year, value: -10, to: now) ?? now
            }
        }
    }

    private var performanceMatrixCard: some View {
        let perf = cachedPerformance
        return PerformanceMatrixCardView(
            title: title,
            decimals: decimals,
            portfolioPerf: perf.portfolio,
            spxPerf: perf.spx
        )
        .equatable()
    }

    /// The combined P&L card: a "Daily P&L" / "Monthly P&L" tab (Daily first)
    /// sharing one axis style and hover behavior. The time-range picker sits
    /// directly beside the tab so the whole control stays compact.
    private var pnlCard: some View {
        Card {
            HStack(spacing: 10) {
                SectionLabel("PnL")
                Spacer()
                SegmentedRangePicker(options: PnlViewMode.allCases,
                                     label: { $0.rawValue },
                                     selection: $pnlViewMode)
                switch pnlViewMode {
                case .daily:
                    SegmentedRangePicker(options: DailyPnlRange.allCases,
                                         label: { $0.rawValue },
                                         selection: $dailyPnlRange)
                case .monthly:
                    SegmentedRangePicker(options: MonthlyPnlRange.allCases,
                                         label: { $0.rawValue },
                                         selection: $monthlyPnlRange)
                }
            }
            switch pnlViewMode {
            case .daily:
                PortfolioDailyPnlChartView(
                    dailyPnlRows: dailyPnlRows,
                    currencySymbol: currencySymbol,
                    amountDecimals: storageService.amountDecimals
                )
                .equatable()
            case .monthly:
                PortfolioMonthlyPnlChartView(
                    monthlyPnlRows: monthlyPnlRows,
                    currencySymbol: currencySymbol,
                    amountDecimals: storageService.amountDecimals
                )
                .equatable()
            }
        }
    }

    private var moneyWeightedReturnCard: some View {
        MoneyWeightedReturnCardView(
            decimals: decimals,
            res: moneyWeightedComparison,
            totalHoldingsCount: portfolios.flatMap({ $0.holdings }).count
        )
        .equatable()
    }

    private var topSymbol: String? { allocation.first?.symbol }
    private var topWeight: Double { (allocation.first?.fraction ?? 0) * 100 }

    // MARK: - Allocation (donut + legend + type strip)

    private var allocation: [PortfolioViewModel.AllocationSlice] {
        viewModel.allocation
    }

    private var allocationCard: some View {
        PortfolioAllocationCardView(
            allocation: allocation,
            holdings: holdings,
            typeBreakdown: typeBreakdown,
            stockService: stockService
        )
        .equatable()
    }

    // MARK: - Movers (Top & Bottom)

    private var topGainersCard: some View {
        Card(title: "Top Gainers") {
            let gainers = viewModel.topGainers
            let maxAbs = gainers.map { abs($0.dayChangePercent) }.max() ?? 1
            if gainers.isEmpty {
                emptyLine
            } else {
                VStack(spacing: 0) {
                    ForEach(gainers) { h in
                        moverRow(h, maxAbs: maxAbs, lastId: gainers.last?.id)
                    }
                }
            }
        }
    }

    private var topLosersCard: some View {
        Card(title: "Top Losers") {
            let losers = viewModel.topLosers
            let maxAbs = losers.map { abs($0.dayChangePercent) }.max() ?? 1
            if losers.isEmpty {
                emptyLine
            } else {
                VStack(spacing: 0) {
                    ForEach(losers) { h in
                        moverRow(h, maxAbs: maxAbs, lastId: losers.last?.id)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func moverRow(_ h: ValuedHolding, maxAbs: Double, lastId: UUID?) -> some View {
        let isJpFund = h.quote.isJapaneseFund || StockService.isJapaneseMutualFund(h.symbol)
        let isDisplayAsset = StockService.isDisplayNameAsset(h.symbol)
        NavigationLink(value: h.id) {
            HStack(spacing: 10) {
                SymbolLogo(symbol: h.symbol, size: 24)
                VStack(alignment: .leading, spacing: 1) {
                    if isJpFund || isDisplayAsset {
                        Text(h.quote.displayName).font(DS.figure).foregroundStyle(DS.ink).lineLimit(1)
                    } else {
                        Text(h.symbol).font(DS.figure).foregroundStyle(DS.ink)
                        Text(h.name).font(DS.micro).foregroundStyle(DS.inkTertiary).lineLimit(1)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text(String(format: "%+.\(decimals)f%%", h.dayChangePercent))
                        .font(.inter(12, weight: .semibold, relativeTo: .body).monospacedDigit())
                        .foregroundStyle(DS.pnlColor(h.dayChangePercent))
                    ZStack(alignment: h.dayChangePercent >= 0 ? .leading : .trailing) {
                        Capsule().fill(DS.cardAlt).frame(width: 48, height: 4)
                        Capsule().fill(DS.pnlColor(h.dayChangePercent))
                            .frame(width: max(4, 48 * abs(h.dayChangePercent) / max(maxAbs, 0.01)), height: 4)
                    }
                }
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .help("View \(h.symbol) details")
        if h.id != lastId {
            Divider().overlay(DS.hairline.opacity(0.6)).padding(.horizontal, 8)
        }
    }

    // MARK: - Diversification data

    private var typeBreakdown: [(label: String, fraction: Double)] {
        viewModel.typeBreakdown
    }

    // MARK: - Positions

    private var positionsHeaderView: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text("#").frame(width: PositionColumnWidth.number, alignment: .leading)
                sortHeader("Symbol", column: .symbol)
                    .frame(minWidth: PositionColumnWidth.symbolMin, idealWidth: 230, maxWidth: .infinity, alignment: .leading)
                ForEach(selectedColumns) { metric in
                    columnHeader(metric)
                }
                Color.clear.frame(width: PositionColumnWidth.chevron)
            }
            .font(DS.label)
            .foregroundStyle(DS.inkTertiary)
            .tracking(0.8).textCase(.uppercase)
            .padding(.vertical, 8)
            Divider().overlay(DS.hairline)
        }
        .background(DS.card)
    }

    private func sortedSymbols() -> [String] {
        return viewModel.sortedSymbols(column: sortColumn, ascending: sortAscending, manualOrder: insertionOrderedSymbols)
    }

    private var positionsCard: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .center, spacing: 14) {
                SectionLabel("Positions")

                Picker("", selection: $positionViewTab) {
                    Text("Active (\(activeSymbolsCount))").tag(PositionViewTab.active)
                    Text("Closed (\(closedTradesCount))").tag(PositionViewTab.closed)
                    Text("Transactions (\(transactionsCount))").tag(PositionViewTab.transactions)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()

                Spacer()
                if positionViewTab == .active {
                    columnCustomizerButton
                    addHoldingButton
                }
            }

            if positionViewTab == .transactions {
                TransactionHistoryView(portfolioId: scopePortfolioId)
            } else if positionViewTab == .closed {
                ClosedPositionsView(portfolioId: scopePortfolioId)
            } else if holdings.isEmpty {
                VStack(spacing: 10) {
                    Text("No holdings yet").font(DS.bodyStrong).foregroundStyle(DS.ink)
                    Text("Add your first position to start tracking value and PnL.")
                        .font(DS.caption).foregroundStyle(DS.inkSecondary)
                    addHoldingButton
                }
                .frame(maxWidth: .infinity).padding(.vertical, 18)
            } else {
                let minTableWidth: CGFloat = positionsTableNaturalWidth
                let groupedValued = viewModel.groupedHoldings
                let symbolsList = sortedSymbols()
                let pagedSymbols: [(index: Int, sym: String)] = {
                    let start = (activeCurrentPage - 1) * activePageSize
                    guard start < symbolsList.count else { return [] }
                    let end = min(start + activePageSize, symbolsList.count)
                    return Array(symbolsList.enumerated())[start..<end].map { ($0.offset, $0.element) }
                }()

                VStack(spacing: 8) {
                    ScrollView(.horizontal, showsIndicators: true) {
                        VStack(spacing: 0) {
                            positionsHeaderView

                            ForEach(pagedSymbols, id: \.sym) { index, sym in
                                if let group = groupedValued[sym], let first = group.first {
                                    let groupVal = viewModel.symbolAggregates[sym]?.value ?? group.reduce(0) { $0 + $1.value }
                                    let weight = abs(totalValue) >= 0.01 ? abs(groupVal) / abs(totalValue) * 100 : 0
                                    let isCrypto = storageService.type(for: first.quote.symbol) == "CRYPTOCURRENCY" || HomeAIInsightService.cryptoBaseAsset(for: first.quote.symbol) != nil

                                    let isPortReadOnly = storageService.portfolios.first(where: { $0.id == first.portfolioId })?.isReadOnly ?? false
                                    let canModify = group.count == 1 && !isPortReadOnly
                                    let rowView = NavigationLink(value: first.id) {
                                        PositionSummaryRow(
                                            position: index + 1,
                                            symbol: sym,
                                            holdings: group,
                                            currencySymbol: currencySymbol,
                                            weight: weight,
                                            topWeight: topWeight,
                                            decimals: decimals,
                                            valueDecimals: storageService.valueDecimals,
                                            percentDecimals: storageService.percentDecimals,
                                            showExtendedHours: storageService.showExtendedHours,
                                            isCrypto: isCrypto,
                                            aggregate: viewModel.symbolAggregates[sym],
                                            columns: selectedColumns
                                        )
                                    }
                                    .buttonStyle(.plain)
                                    .help("View \(sym) details")

                                    if canModify {
                                        rowView.contextMenu {
                                            Button {
                                                targetCloseHolding = TargetCloseHolding(
                                                    portfolioId: first.portfolioId,
                                                    holding: first.holding,
                                                    quote: first.quote
                                                )
                                            } label: {
                                                Label("Sell / Close Position…", systemImage: "arrow.down.right.circle")
                                            }
                                            Button { editHoldingAction.perform(first.portfolioId, first.holding) } label: { Label("Edit", systemImage: "pencil") }
                                            Button(role: .destructive) {
                                                confirmDeleteHolding = (first.holding, first.portfolioId)
                                            } label: { Label("Delete", systemImage: "trash") }
                                        }
                                    } else {
                                        rowView
                                    }
                                }
                            }
                        }
                        .frame(minWidth: minTableWidth, alignment: .leading)
                    }
                    .scrollBounceBehavior(.basedOnSize, axes: .horizontal)

                    if symbolsList.count > 10 {
                        TablePaginationBar(
                            currentPage: $activeCurrentPage,
                            pageSize: $activePageSize,
                            totalItems: symbolsList.count,
                            pageSizeOptions: [10, 20, 50]
                        )
                        .padding(.top, 4)
                    }
                }
            }
        }
        .padding(DS.pad)
        .frame(maxWidth: .infinity, alignment: .leading)
        .premiumCard()
    }

    /// "Columns" button that opens the column customizer sheet.
    private var columnCustomizerButton: some View {
        Button { showColumnCustomizer = true } label: {
            HStack(spacing: 5) {
                Image(systemName: "slider.horizontal.3").font(.system(size: 10, weight: .bold))
                Text("Columns").font(.inter(11, weight: .semibold, relativeTo: .caption))
            }
            .foregroundStyle(DS.brand)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(DS.brand.opacity(0.12)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(DS.brand.opacity(0.25), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .help("Customize portfolio columns")
    }

    @ViewBuilder private var addHoldingButton: some View {
        let isReadOnly: Bool = {
            switch scope {
            case .portfolio(let id):
                return storageService.portfolios.first(where: { $0.id == id })?.isReadOnly ?? false
            case .all:
                return storageService.portfolios.allSatisfy { $0.isReadOnly }
            }
        }()

        if !isReadOnly {
            let label = HStack(spacing: 4) {
                Image(systemName: "plus").font(.system(size: 10, weight: .bold))
                Text("Add holding").font(.inter(11, weight: .semibold, relativeTo: .caption))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 11).padding(.vertical, 5)
            .background(Capsule().fill(DS.brand))

            switch scope {
            case .portfolio(let id):
                Button { addHoldingAction.perform(id) } label: { label }.buttonStyle(.plain)
                    .pointingHandCursor()
                    .help("Add a holding to this portfolio")
            case .all:
                let editablePortfolios = storageService.portfolios.filter { !$0.isReadOnly }
                if editablePortfolios.count == 1, let id = editablePortfolios.first?.id {
                    Button { addHoldingAction.perform(id) } label: { label }.buttonStyle(.plain)
                        .pointingHandCursor()
                        .help("Add a holding")
                } else if !editablePortfolios.isEmpty {
                    Menu {
                        ForEach(editablePortfolios) { p in
                            Button(p.name) { addHoldingAction.perform(p.id) }
                        }
                    } label: { label }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .pointingHandCursor()
                    .help("Add a holding — choose which portfolio")
                }
            }
        }
    }

    private var emptyLine: some View {
        Text("No holdings yet").font(DS.caption).foregroundStyle(DS.inkSecondary)
            .frame(maxWidth: .infinity, alignment: .center).padding(.vertical, 12)
    }
}

// MARK: - Position summary row

/// Shared right-side Y axis for the Daily/Monthly P&L charts.
private struct PnlYAxis: ViewModifier {
    let currencySymbol: String

    func body(content: Content) -> some View {
        content.chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) { v in
                AxisGridLine().foregroundStyle(DS.hairline.opacity(0.5))
                AxisValueLabel {
                    if let d = v.as(Double.self) {
                        Text(StorageService.formatAmount(d, symbol: currencySymbol, decimals: 0))
                            .font(DS.micro).foregroundStyle(DS.inkTertiary)
                    }
                }
            }
        }
    }
}

/// Shared sparse X axis for the Daily/Monthly P&L charts (explicit tick values).
private struct PnlXAxis: ViewModifier {
    let values: [String]

    func body(content: Content) -> some View {
        content.chartXAxis {
            AxisMarks(values: values) { value in
                if let s = value.as(String.self) {
                    AxisValueLabel { Text(s).font(DS.micro).foregroundStyle(DS.inkTertiary) }
                }
            }
        }
    }
}

// MARK: - Isolated Card Subviews (Prevents Hover Thrashing & Full-Tree Re-renders)

private struct PerformanceMatrixCardView: View, Equatable {
    let title: String
    let decimals: Int
    let portfolioPerf: [PortfolioOverview.PerformancePeriod: Double?]
    let spxPerf: [PortfolioOverview.PerformancePeriod: Double?]

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.title == rhs.title &&
        lhs.decimals == rhs.decimals &&
        lhs.portfolioPerf == rhs.portfolioPerf &&
        lhs.spxPerf == rhs.spxPerf
    }

    var body: some View {
        Card(
            title: "Performance & Benchmark",
            tooltip: "Asset backtest: Simulates price performance of your current asset basket over each timeframe vs S&P 500, regardless of personal purchase dates. For your money-weighted return based on actual buy dates, see Your Actual Return (XIRR) below."
        ) {
            VStack(spacing: 12) {
                HStack(spacing: 0) {
                    Text("Timeline")
                        .font(DS.micro)
                        .foregroundStyle(DS.inkTertiary)
                        .frame(width: 140, alignment: .leading)

                    ForEach(PortfolioOverview.PerformancePeriod.allCases) { p in
                        Text(p.rawValue)
                            .font(DS.micro)
                            .foregroundStyle(DS.inkTertiary)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
                .padding(.bottom, 2)

                Divider().overlay(DS.hairline)

                // Row 1: Portfolio Performance
                HStack(spacing: 0) {
                    HStack(spacing: 6) {
                        Image(systemName: "briefcase.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(DS.brand)
                        Text(LocalizedStringKey(title))
                            .font(DS.figure)
                            .foregroundStyle(DS.ink)
                            .lineLimit(1)
                    }
                    .frame(width: 140, alignment: .leading)

                    ForEach(PortfolioOverview.PerformancePeriod.allCases) { period in
                        let pct = portfolioPerf[period] ?? nil
                        if let pct {
                            Text(String(format: "%+.\(decimals)f%%", pct))
                                .font(DS.figure.monospacedDigit())
                                .foregroundStyle(DS.pnlColor(pct))
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        } else {
                            Text("—")
                                .font(DS.figure)
                                .foregroundStyle(DS.inkTertiary)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                    }
                }

                Divider().overlay(DS.hairline.opacity(0.5))

                // Row 2: SPX Benchmark Performance
                HStack(spacing: 0) {
                    HStack(spacing: 6) {
                        Image(systemName: "chart.line.uptrend.xyaxis")
                            .font(.system(size: 11))
                            .foregroundStyle(DS.inkSecondary)
                        Text("S&P 500 (SPX)")
                            .font(DS.figure)
                            .foregroundStyle(DS.ink)
                    }
                    .frame(width: 140, alignment: .leading)

                    ForEach(PortfolioOverview.PerformancePeriod.allCases) { period in
                        let pct = spxPerf[period] ?? nil
                        if let pct {
                            Text(String(format: "%+.\(decimals)f%%", pct))
                                .font(DS.figure.monospacedDigit())
                                .foregroundStyle(DS.pnlColor(pct))
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        } else {
                            Text("—")
                                .font(DS.figure)
                                .foregroundStyle(DS.inkTertiary)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                    }
                }

                Divider().overlay(DS.hairline.opacity(0.5))

                Text("Asset backtest — simulates past performance of your current asset basket vs S&P 500.")
                    .font(DS.micro)
                    .foregroundStyle(DS.inkTertiary)
            }
        }
    }
}

private struct MoneyWeightedReturnCardView: View, Equatable {
    let decimals: Int
    let res: InvestmentEffectiveness.Result
    let totalHoldingsCount: Int

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.decimals == rhs.decimals &&
        lhs.totalHoldingsCount == rhs.totalHoldingsCount &&
        lhs.res.portfolioXIRR == rhs.res.portfolioXIRR &&
        lhs.res.benchmarkXIRR == rhs.res.benchmarkXIRR &&
        lhs.res.excludedHoldingsCount == rhs.res.excludedHoldingsCount &&
        lhs.res.isYoungerThan30Days == rhs.res.isYoungerThan30Days
    }

    var body: some View {
        let pXIRR = res.portfolioXIRR
        let bXIRR = res.benchmarkXIRR

        let pFormatted = pXIRR.map { String(format: "%+.\(decimals)f%%", $0) } ?? "—"
        let bFormatted = bXIRR.map { String(format: "%+.\(decimals)f%%", $0) } ?? "—"

        return Card(
            title: "Your Actual Return (XIRR)",
            tooltip: "Money-weighted return (XIRR): Annualized actual return based on your cash flows, buy dates, and real cost, compared with investing the same capital at the same time in S&P 500."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                if res.isYoungerThan30Days {
                    HStack(spacing: 8) {
                        Image(systemName: "clock")
                            .font(.system(size: 13))
                            .foregroundStyle(DS.inkTertiary)
                        Text("Holdings are less than 30 days old. XIRR requires at least 30 days of history to avoid annualization distortion.")
                            .font(DS.body)
                            .foregroundStyle(DS.inkSecondary)
                    }
                    .padding(.vertical, 4)
                } else if res.excludedHoldingsCount == totalHoldingsCount {
                    HStack(spacing: 8) {
                        Image(systemName: "calendar.badge.plus")
                            .font(.system(size: 13))
                            .foregroundStyle(DS.inkTertiary)
                        Text("Add a purchase date to your positions to see your money-weighted return vs S&P 500.")
                            .font(DS.body)
                            .foregroundStyle(DS.inkSecondary)
                    }
                    .padding(.vertical, 4)
                } else {
                    HStack(spacing: DS.gap) {
                        StatTile(
                            label: "Your Return (Annualized)",
                            value: pFormatted,
                            caption: "Money-weighted IRR",
                            valueTint: pXIRR.map { DS.pnlColor($0) } ?? DS.ink
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)

                        StatTile(
                            label: "S&P 500 Equivalent",
                            value: bFormatted,
                            caption: "Same capital & timing",
                            valueTint: bXIRR.map { DS.pnlColor($0) } ?? DS.ink
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if let p = pXIRR, let b = bXIRR {
                        let diff = p - b
                        HStack(spacing: 6) {
                            Image(systemName: diff >= 0 ? "checkmark.circle.fill" : "arrow.down.circle.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(DS.pnlColor(diff))
                            if abs(diff) < 0.05 {
                                Text("Matching S&P 500 performance")
                                    .font(DS.figure.weight(.semibold))
                                    .foregroundStyle(DS.pnlColor(diff))
                            } else if diff > 0 {
                                Text("Beating S&P 500 by +\(String(format: "%.1f", diff)) pp/yr")
                                    .font(DS.figure.weight(.semibold))
                                    .foregroundStyle(DS.pnlColor(diff))
                            } else {
                                Text("Trailing S&P 500 by -\(String(format: "%.1f", abs(diff))) pp/yr")
                                    .font(DS.figure.weight(.semibold))
                                    .foregroundStyle(DS.pnlColor(diff))
                            }
                        }
                    }

                    if res.excludedHoldingsCount > 0 {
                        Text("\(res.excludedHoldingsCount) positions without a purchase date excluded.")
                            .font(DS.micro)
                            .foregroundStyle(DS.inkTertiary)
                    }
                }

                Divider().overlay(DS.hairline.opacity(0.5))

                Text("Annualized, money-weighted, based on your actual buy dates and cost — excludes closed/sold positions.")
                    .font(DS.micro)
                    .foregroundStyle(DS.inkTertiary)
            }
        }
    }
}

private struct PortfolioHeroChartView: View, Equatable {
    let points: [ValuePoint]
    let chartRange: ChartRange
    let currencySymbol: String
    let amountDecimals: Int

    static func == (lhs: Self, rhs: Self) -> Bool {
        guard lhs.chartRange == rhs.chartRange,
              lhs.currencySymbol == rhs.currencySymbol,
              lhs.amountDecimals == rhs.amountDecimals,
              lhs.points.count == rhs.points.count else {
            return false
        }
        guard let lFirst = lhs.points.first, let rFirst = rhs.points.first,
              let lLast = lhs.points.last, let rLast = rhs.points.last else {
            return lhs.points.isEmpty && rhs.points.isEmpty
        }
        return lFirst.date == rFirst.date && lLast.date == rLast.date &&
               abs(lFirst.value - rFirst.value) < 1.0 && abs(lLast.value - rLast.value) < 1.0
    }

    private func xAxisLabel(_ date: Date) -> String {
        switch chartRange {
        case .week: return date.formatted(.dateTime.weekday(.abbreviated))
        case .month, .threeMonths, .sixMonths, .ytd: return date.formatted(.dateTime.day().month(.abbreviated))
        case .year, .threeYears, .fiveYears, .all:
            return date.formatted(.dateTime.month(.abbreviated).year(.twoDigits))
        }
    }

    private func valueDomain(_ series: [ValuePoint]) -> ClosedRange<Double> {
        let vals = series.map(\.value).filter(\.isFinite)
        guard let lo = vals.min(), let hi = vals.max(), hi > lo else { return 0...1 }
        let span = hi - lo
        return (lo - span * 0.10)...(hi + span * 0.14)
    }

    var body: some View {
        if points.isEmpty {
            ZStack {
                DS.cardAlt.opacity(0.6)
                DecorativeCurve()
                    .stroke(DS.hairline, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    .padding(.horizontal, 24)
                VStack(spacing: 4) {
                    Text("Value history builds up day by day")
                        .font(.inter(11, weight: .medium, relativeTo: .caption)).foregroundStyle(DS.inkSecondary)
                    Text("Your first trend appears tomorrow.")
                        .font(DS.micro).foregroundStyle(DS.inkTertiary)
                }
            }
        } else {
            let periodUp = (points.last?.value ?? 0) >= (points.first?.value ?? 0)
            let tint = periodUp ? DS.up : DS.down
            Chart {
                ForEach(points) { p in
                    AreaMark(x: .value("Day", p.date), y: .value("Value", p.value))
                        .foregroundStyle(.linearGradient(colors: [tint.opacity(0.22), tint.opacity(0)],
                                                         startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("Day", p.date), y: .value("Value", p.value))
                        .foregroundStyle(tint).lineStyle(.init(lineWidth: 2))
                        .interpolationMethod(.monotone)
                }
                if let last = points.last {
                    PointMark(x: .value("Day", last.date), y: .value("Value", last.value))
                        .symbolSize(50)
                        .foregroundStyle(tint)
                }
            }
            .chartYScale(domain: valueDomain(points))
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { v in
                    AxisGridLine().foregroundStyle(DS.hairline.opacity(0.5))
                    AxisValueLabel {
                        if let d = v.as(Double.self) {
                            Text(StorageService.formatAmount(d, symbol: currencySymbol, decimals: 0))
                                .font(DS.micro).foregroundStyle(DS.inkTertiary)
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { value in
                    if let d = value.as(Date.self) {
                        AxisValueLabel { Text(xAxisLabel(d)).font(DS.micro).foregroundStyle(DS.inkTertiary) }
                    }
                }
            }
            .chartLegend(.hidden)
            .chartOverlay { proxy in
                PortfolioHeroChartCrosshairOverlay(
                    proxy: proxy,
                    points: points,
                    tint: tint,
                    currencySymbol: currencySymbol,
                    amountDecimals: amountDecimals,
                    chartRange: chartRange
                )
            }
            .id(chartRange)
        }
    }
}

private struct PortfolioHeroChartCrosshairOverlay: View {
    let proxy: ChartProxy
    let points: [ValuePoint]
    let tint: Color
    let currencySymbol: String
    let amountDecimals: Int
    let chartRange: ChartRange

    @State private var hoverPoint: ValuePoint?

    private func tooltipDate(_ date: Date) -> String {
        switch chartRange {
        case .week: return date.formatted(.dateTime.weekday(.abbreviated).hour())
        default: return date.formatted(date: .abbreviated, time: .omitted)
        }
    }

    var body: some View {
        GeometryReader { geo in
            if let plotAnchor = proxy.plotFrame {
                let plot = geo[plotAnchor]
                ZStack(alignment: .topLeading) {
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let loc):
                                let localX = min(max(loc.x - plot.minX, 0), plot.width)
                                if let d: Date = proxy.value(atX: localX) {
                                    hoverPoint = nearestByDate(points, to: d, date: \.date)
                                }
                            case .ended:
                                hoverPoint = nil
                            }
                        }
                    if let h = hoverPoint,
                       let px = proxy.position(forX: h.date),
                       let py = proxy.position(forY: h.value) {
                        let cx = plot.minX + px
                        Group {
                            Path { p in p.move(to: CGPoint(x: cx, y: plot.minY)); p.addLine(to: CGPoint(x: cx, y: plot.maxY)) }
                                .stroke(DS.inkTertiary.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                            Circle().fill(tint).frame(width: 9, height: 9)
                                .overlay(Circle().strokeBorder(.white, lineWidth: 1.5))
                                .position(x: cx, y: plot.minY + py)
                            ChartTooltip(title: tooltipDate(h.date),
                                         value: StorageService.formatAmount(h.value, symbol: currencySymbol, decimals: amountDecimals),
                                         tint: tint)
                                .position(x: min(max(cx, plot.minX + 46), plot.maxX - 46), y: plot.minY + 8)
                        }
                        .allowsHitTesting(false)
                    }
                }
            }
        }
    }
}

private struct PnlChartTooltip: View {
    let title: String
    let totalPnl: Double
    let realizedPnl: Double?
    let unrealizedPnl: Double?
    let currencySymbol: String
    let amountDecimals: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(DS.micro).foregroundStyle(DS.inkTertiary)
            HStack(spacing: 4) {
                Text("Total:")
                    .font(DS.micro)
                    .foregroundStyle(DS.inkSecondary)
                Text(StorageService.formatAmount(totalPnl, symbol: currencySymbol, decimals: amountDecimals, signed: true))
                    .font(.inter(12, weight: .semibold, relativeTo: .body).monospacedDigit())
                    .foregroundStyle(DS.pnlColor(totalPnl))
            }
            if let r = realizedPnl, abs(r) > 0.001 {
                HStack(spacing: 4) {
                    Text("• Realized:")
                        .font(DS.micro)
                        .foregroundStyle(DS.inkTertiary)
                    Text(StorageService.formatAmount(r, symbol: currencySymbol, decimals: amountDecimals, signed: true))
                        .font(.inter(11, weight: .medium, relativeTo: .body).monospacedDigit())
                        .foregroundStyle(DS.pnlColor(r))
                }
            }
            if let u = unrealizedPnl, (realizedPnl != nil && abs(realizedPnl!) > 0.001) {
                HStack(spacing: 4) {
                    Text("• Paper:")
                        .font(DS.micro)
                        .foregroundStyle(DS.inkTertiary)
                    Text(StorageService.formatAmount(u, symbol: currencySymbol, decimals: amountDecimals, signed: true))
                        .font(.inter(11, weight: .medium, relativeTo: .body).monospacedDigit())
                        .foregroundStyle(DS.pnlColor(u))
                }
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(DS.card)
            .shadow(color: .black.opacity(0.12), radius: 6, y: 2))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(DS.hairline))
        .fixedSize()
    }
}

private struct PortfolioDailyPnlChartView: View, Equatable {
    let dailyPnlRows: [DailyPnlRow]
    let currencySymbol: String
    let amountDecimals: Int

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.currencySymbol == rhs.currencySymbol &&
        lhs.amountDecimals == rhs.amountDecimals &&
        lhs.dailyPnlRows == rhs.dailyPnlRows
    }

    @State private var hoveredDay: DailyPnlRow?

    private var dayAxisValues: [String] {
        guard dailyPnlRows.count > 12 else {
            return dailyPnlRows.map(\.label)
        }
        let target = 6
        let step = max(1, (dailyPnlRows.count + target - 1) / target)
        var values: [String] = []
        for i in stride(from: 0, to: dailyPnlRows.count, by: step) {
            values.append(dailyPnlRows[i].label)
        }
        return values
    }

    private func dayOverlay(proxy: ChartProxy, geo: GeometryProxy, plot: CGRect) -> some View {
        ZStack(alignment: .topLeading) {
            Rectangle().fill(.clear).contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let loc):
                        let localX = min(max(loc.x - plot.minX, 0), plot.width)
                        if let label: String = proxy.value(atX: localX) {
                            hoveredDay = dailyPnlRows.first { $0.label == label }
                        }
                    case .ended:
                        hoveredDay = nil
                    }
                }
            if let h = hoveredDay,
               let px = proxy.position(forX: h.label) {
                let cx = plot.minX + px
                let pnl = h.pnl ?? 0
                PnlChartTooltip(
                    title: h.label,
                    totalPnl: pnl,
                    realizedPnl: h.realizedPnl,
                    unrealizedPnl: h.unrealizedPnl,
                    currencySymbol: currencySymbol,
                    amountDecimals: amountDecimals
                )
                .position(x: min(max(cx, plot.minX + 55), plot.maxX - 55), y: plot.minY + 12)
                .allowsHitTesting(false)
            }
        }
    }

    var body: some View {
        if dailyPnlRows.isEmpty {
            Text("No holdings yet").font(DS.caption).foregroundStyle(DS.inkSecondary)
                .frame(maxWidth: .infinity, alignment: .center).padding(.vertical, 12)
        } else {
            Chart {
                ForEach(dailyPnlRows.reversed()) { row in
                    let isHovered = hoveredDay?.date == row.date
                    let pnl = row.pnl ?? 0
                    BarMark(
                        x: .value("Day", row.label),
                        yStart: .value("Zero", 0),
                        yEnd: .value("PnL", pnl),
                        width: .ratio(isHovered ? 0.82 : 0.55)
                    )
                    .foregroundStyle(DS.pnlColor(pnl))
                    .opacity(isHovered ? 1.0 : 0.75)
                    .cornerRadius(2)

                    if let r = row.realizedPnl, abs(r) > 0.001 {
                        PointMark(
                            x: .value("Day", row.label),
                            y: .value("PnL", pnl)
                        )
                        .symbol(Circle())
                        .symbolSize(isHovered ? 24 : 14)
                        .foregroundStyle(DS.gold)
                    }
                }
                RuleMark(y: .value("Zero", 0))
                    .foregroundStyle(DS.hairline.opacity(0.6))
            }
            .frame(height: 170)
            .modifier(PnlYAxis(currencySymbol: currencySymbol))
            .modifier(PnlXAxis(values: dayAxisValues))
            .chartLegend(.hidden)
            .chartOverlay { proxy in
                GeometryReader { geo in
                    if let plotAnchor = proxy.plotFrame {
                        dayOverlay(proxy: proxy, geo: geo, plot: geo[plotAnchor])
                    }
                }
            }

            Divider().overlay(DS.hairline.opacity(0.5))

            Text("Daily PnL from real cost basis × price history + closed trades — adding cash or positions doesn't inflate PnL.")
                .font(DS.micro)
                .foregroundStyle(DS.inkTertiary)
                .padding(.top, 6)
        }
    }
}

private struct PortfolioMonthlyPnlChartView: View, Equatable {
    let monthlyPnlRows: [MonthlyPnlRow]
    let currencySymbol: String
    let amountDecimals: Int

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.currencySymbol == rhs.currencySymbol &&
        lhs.amountDecimals == rhs.amountDecimals &&
        lhs.monthlyPnlRows == rhs.monthlyPnlRows
    }

    @State private var hoveredMonth: MonthlyPnlRow?

    private func monthAxisLabel(_ date: Date) -> String {
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month], from: date)
        return "\(comps.year ?? 0)/\(comps.month ?? 0)"
    }

    private var monthAxisValues: [String] {
        guard monthlyPnlRows.count > 8 else {
            return monthlyPnlRows.map { monthAxisLabel($0.monthStart) }
        }
        let target = 6
        let step = max(1, (monthlyPnlRows.count + target - 1) / target)
        var values: [String] = []
        for i in stride(from: 0, to: monthlyPnlRows.count, by: step) {
            values.append(monthAxisLabel(monthlyPnlRows[i].monthStart))
        }
        return values
    }

    private func monthOverlay(proxy: ChartProxy, geo: GeometryProxy, plot: CGRect) -> some View {
        ZStack(alignment: .topLeading) {
            Rectangle().fill(.clear).contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let loc):
                        let localX = min(max(loc.x - plot.minX, 0), plot.width)
                        if let label: String = proxy.value(atX: localX) {
                            hoveredMonth = monthlyPnlRows.first { monthAxisLabel($0.monthStart) == label }
                        }
                    case .ended:
                        hoveredMonth = nil
                    }
                }
            if let h = hoveredMonth,
               let px = proxy.position(forX: monthAxisLabel(h.monthStart)) {
                let cx = plot.minX + px
                let pnl = h.pnl ?? 0
                PnlChartTooltip(
                    title: monthAxisLabel(h.monthStart),
                    totalPnl: pnl,
                    realizedPnl: h.realizedPnl,
                    unrealizedPnl: h.unrealizedPnl,
                    currencySymbol: currencySymbol,
                    amountDecimals: amountDecimals
                )
                .position(x: min(max(cx, plot.minX + 55), plot.maxX - 55), y: plot.minY + 12)
                .allowsHitTesting(false)
            }
        }
    }

    var body: some View {
        if monthlyPnlRows.isEmpty {
            Text("No holdings yet").font(DS.caption).foregroundStyle(DS.inkSecondary)
                .frame(maxWidth: .infinity, alignment: .center).padding(.vertical, 12)
        } else {
            Chart {
                ForEach(monthlyPnlRows.reversed()) { row in
                    let isHovered = hoveredMonth?.monthStart == row.monthStart
                    let label = monthAxisLabel(row.monthStart)
                    let total = row.pnl ?? 0
                    let realized = row.realizedPnl ?? 0
                    let unrealized = row.unrealizedPnl ?? 0
                    let hasRealized = abs(realized) > 0.001
                    let hasUnrealized = abs(unrealized) > 0.001

                    if !hasRealized {
                        // Only unrealized / standard bar
                        BarMark(
                            x: .value("Month", label),
                            yStart: .value("Zero", 0),
                            yEnd: .value("PnL", total),
                            width: .ratio(isHovered ? 0.82 : 0.6)
                        )
                        .foregroundStyle(DS.pnlColor(total).opacity(0.65))
                        .opacity(isHovered ? 1.0 : 0.85)
                        .cornerRadius(3)
                    } else if !hasUnrealized {
                        // Only realized trades in this month
                        BarMark(
                            x: .value("Month", label),
                            yStart: .value("Zero", 0),
                            yEnd: .value("PnL", realized),
                            width: .ratio(isHovered ? 0.82 : 0.6)
                        )
                        .foregroundStyle(DS.pnlColor(realized))
                        .opacity(isHovered ? 1.0 : 0.95)
                        .cornerRadius(3)
                    } else if (realized >= 0 && unrealized >= 0) || (realized <= 0 && unrealized <= 0) {
                        // Same sign: stacked bar!
                        // Bottom segment: Realized PnL (solid / saturated)
                        BarMark(
                            x: .value("Month", label),
                            yStart: .value("Zero", 0),
                            yEnd: .value("Realized", realized),
                            width: .ratio(isHovered ? 0.82 : 0.6)
                        )
                        .foregroundStyle(DS.pnlColor(realized))
                        .opacity(isHovered ? 1.0 : 0.95)
                        .cornerRadius(2)

                        // Top segment: Paper PnL (softer opacity)
                        BarMark(
                            x: .value("Month", label),
                            yStart: .value("Realized", realized),
                            yEnd: .value("Total", total),
                            width: .ratio(isHovered ? 0.82 : 0.6)
                        )
                        .foregroundStyle(DS.pnlColor(unrealized).opacity(0.55))
                        .opacity(isHovered ? 0.95 : 0.80)
                        .cornerRadius(2)
                    } else {
                        // Opposite signs: bidirectional bars + Net marker!
                        BarMark(
                            x: .value("Month", label),
                            yStart: .value("Zero", 0),
                            yEnd: .value("Realized", realized),
                            width: .ratio(isHovered ? 0.82 : 0.6)
                        )
                        .foregroundStyle(DS.pnlColor(realized))
                        .opacity(isHovered ? 1.0 : 0.95)
                        .cornerRadius(2)

                        BarMark(
                            x: .value("Month", label),
                            yStart: .value("Zero", 0),
                            yEnd: .value("Unrealized", unrealized),
                            width: .ratio(isHovered ? 0.82 : 0.6)
                        )
                        .foregroundStyle(DS.pnlColor(unrealized).opacity(0.55))
                        .opacity(isHovered ? 0.95 : 0.80)
                        .cornerRadius(2)

                        // Net Total marker
                        PointMark(
                            x: .value("Month", label),
                            y: .value("Net Total", total)
                        )
                        .symbol(Circle())
                        .symbolSize(isHovered ? 36 : 22)
                        .foregroundStyle(DS.pnlColor(total))
                    }
                }
                RuleMark(y: .value("Zero", 0))
                    .foregroundStyle(DS.hairline.opacity(0.6))
            }
            .frame(height: 170)
            .modifier(PnlYAxis(currencySymbol: currencySymbol))
            .modifier(PnlXAxis(values: monthAxisValues))
            .chartLegend(.hidden)
            .chartOverlay { proxy in
                GeometryReader { geo in
                    if let plotAnchor = proxy.plotFrame {
                        monthOverlay(proxy: proxy, geo: geo, plot: geo[plotAnchor])
                    }
                }
            }

            HStack(spacing: 16) {
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(DS.up)
                        .frame(width: 10, height: 10)
                    Text("Realized")
                        .font(DS.micro)
                        .foregroundStyle(DS.inkSecondary)
                }
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(DS.up.opacity(0.55))
                        .frame(width: 10, height: 10)
                    Text("Paper")
                        .font(DS.micro)
                        .foregroundStyle(DS.inkSecondary)
                }
                if monthlyPnlRows.contains(where: { ($0.realizedPnl ?? 0) * ($0.unrealizedPnl ?? 0) < -0.001 }) {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(DS.ink)
                            .frame(width: 6, height: 6)
                        Text("Net")
                            .font(DS.micro)
                            .foregroundStyle(DS.inkSecondary)
                    }
                }
                Spacer()
            }
            .padding(.top, 4)

            Divider().overlay(DS.hairline.opacity(0.5))

            Text("Real cost basis × price history + closed trades — adding cash or positions doesn't inflate PnL.")
                .font(DS.micro)
                .foregroundStyle(DS.inkTertiary)
                .padding(.top, 6)
        }
    }
}

private struct PortfolioAllocationCardView: View, Equatable {
    let allocation: [PortfolioViewModel.AllocationSlice]
    let holdings: [ValuedHolding]
    let typeBreakdown: [(label: String, fraction: Double)]
    let stockService: StockService

    static func == (lhs: Self, rhs: Self) -> Bool {
        guard lhs.allocation.count == rhs.allocation.count,
              lhs.holdings.count == rhs.holdings.count,
              lhs.typeBreakdown.count == rhs.typeBreakdown.count else {
            return false
        }
        for (l, r) in zip(lhs.allocation, rhs.allocation) {
            if l.id != r.id || l.symbol != r.symbol || abs(l.fraction - r.fraction) > 0.005 {
                return false
            }
        }
        for (l, r) in zip(lhs.typeBreakdown, rhs.typeBreakdown) {
            if l.label != r.label || abs(l.fraction - r.fraction) > 0.005 {
                return false
            }
        }
        return true
    }

    @State private var hoveredSlice: String?

    private var displaySlices: [PortfolioViewModel.AllocationSlice] {
        if allocation.count <= 6 {
            return allocation
        } else {
            let top = Array(allocation.prefix(5))
            let otherFraction = allocation.dropFirst(5).reduce(0.0) { $0 + $1.fraction }
            let otherValue = allocation.dropFirst(5).reduce(0.0) { $0 + $1.value }
            let otherSlice = PortfolioViewModel.AllocationSlice(
                id: "__other__",
                symbol: "Other (\(allocation.count - 5))",
                value: otherValue,
                fraction: otherFraction
            )
            return top + [otherSlice]
        }
    }

    private var holdingByCanonical: [String: ValuedHolding] {
        var map: [String: ValuedHolding] = [:]
        for h in holdings {
            let sym = StockService.canonicalSymbol(for: h.symbol)
            if map[sym] == nil {
                map[sym] = h
            }
        }
        return map
    }

    private func color(for symbol: String) -> Color {
        if symbol.hasPrefix("Other") { return DS.inkTertiary }
        let slices = displaySlices
        let idx = slices.firstIndex { $0.symbol == symbol } ?? (allocation.firstIndex { $0.symbol == symbol } ?? 0)
        return DS.palette[idx % DS.palette.count]
    }

    private func allocationRow(_ slice: PortfolioViewModel.AllocationSlice) -> some View {
        HStack(spacing: 9) {
            RoundedRectangle(cornerRadius: 2.5).fill(color(for: slice.symbol)).frame(width: 9, height: 9)
            if slice.id == "__other__" {
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(DS.inkTertiary)
                    .frame(width: 20, height: 20)
            } else {
                SymbolLogo(symbol: slice.symbol, size: 20)
            }
            let displayName = (slice.id == "__other__") ? slice.symbol : (stockService.quotes[slice.symbol]?.displayName ?? StockService.codeToFundNameMap[slice.symbol] ?? slice.symbol)
            Text(displayName).font(DS.figure).foregroundStyle(DS.ink).lineLimit(1)
            Spacer()
            Text(String(format: "%.1f%%", slice.fraction * 100))
                .font(DS.figure).foregroundStyle(DS.inkSecondary)
        }
    }

    private var typeStrip: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(Array(typeBreakdown.enumerated()), id: \.element.label) { idx, row in
                        RoundedRectangle(cornerRadius: 2.5)
                            .fill(DS.palette[idx % DS.palette.count])
                            .frame(width: max(2, geo.size.width * row.fraction - 2))
                    }
                }
            }
            .frame(height: 8)
            HStack(spacing: 14) {
                ForEach(Array(typeBreakdown.enumerated()), id: \.element.label) { idx, row in
                    HStack(spacing: 5) {
                        Circle().fill(DS.palette[idx % DS.palette.count]).frame(width: 6, height: 6)
                        Text(row.label).font(DS.caption).foregroundStyle(DS.inkSecondary)
                        Text(String(format: "%.0f%%", row.fraction * 100))
                            .font(DS.caption.monospacedDigit()).foregroundStyle(DS.inkTertiary)
                    }
                }
                Spacer()
            }
        }
    }

    var body: some View {
        Card(title: "Allocation") {
            if allocation.isEmpty {
                Text("No holdings yet").font(DS.caption).foregroundStyle(DS.inkSecondary)
                    .frame(maxWidth: .infinity, alignment: .center).padding(.vertical, 12)
            } else {
                let slices = displaySlices
                let lookup = holdingByCanonical

                VStack(spacing: 16) {
                    HStack(spacing: 20) {
                        ZStack {
                            Chart(slices) { slice in
                                SectorMark(angle: .value("Value", slice.value),
                                           innerRadius: .ratio(0.64), angularInset: 2)
                                    .cornerRadius(3)
                                    .foregroundStyle(color(for: slice.symbol))
                                    .opacity(hoveredSlice == nil || hoveredSlice == slice.symbol ? 1 : 0.35)
                            }
                            .chartLegend(.hidden)
                            VStack(spacing: 1) {
                                Text("\(allocation.count)").font(DS.figureLG).foregroundStyle(DS.ink)
                                SectionLabel("Assets")
                            }
                        }
                        .frame(width: 136, height: 136)

                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(slices) { slice in
                                let matchedHolding = lookup[StockService.canonicalSymbol(for: slice.symbol)]
                                Group {
                                    if let matched = matchedHolding {
                                        NavigationLink(value: matched.id) {
                                            allocationRow(slice)
                                        }
                                        .buttonStyle(.plain)
                                        .pointingHandCursor()
                                        .help("View \(slice.symbol) details")
                                    } else {
                                        allocationRow(slice)
                                    }
                                }
                                .contentShape(Rectangle())
                                .onHover { hoveredSlice = $0 ? slice.symbol : nil }
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }

                    if !typeBreakdown.isEmpty {
                        Divider().overlay(DS.hairline)
                        typeStrip
                    }
                }
            }
        }
    }
}

private enum PositionColumnWidth {
    static let number: CGFloat = 30
    static let symbolMin: CGFloat = 120
    static let priceMin: CGFloat = 90
    static let sessionMin: CGFloat = 90
    static let amountMin: CGFloat = 95
    static let sharesMin: CGFloat = 85
    static let weightMin: CGFloat = 95
    static let chevron: CGFloat = 16
}

private struct PositionSummaryRow: View {
    let position: Int
    let symbol: String
    let holdings: [ValuedHolding]
    let currencySymbol: String
    let weight: Double
    let topWeight: Double
    let decimals: Int
    let valueDecimals: Int
    let percentDecimals: Int
    let showExtendedHours: Bool
    let isCrypto: Bool
    /// Pre-computed per-symbol aggregate from ViewModel (nil fallback for legacy).
    let aggregate: PortfolioViewModel.SymbolAggregate?
    /// Visible custom columns (rank # and Symbol are always present).
    let columns: [PortfolioColumnMetric]

    @State private var hovered = false

    private var first: ValuedHolding? { holdings.first }

    private var liveQuote: StockQuote? {
        return first?.quote
    }

    private var nativeCurrencySymbol: String {
        return aggregate?.nativeCurrencySymbol ?? "$"
    }

    /// Use pre-computed aggregate when available, fall back to per-row computation.
    private var totalNativeCost: Double {
        if let agg = aggregate {
            return agg.nativeCost
        }
        return holdings.reduce(0) { $0 + $1.holding.costBasisLocal }
    }

    private var totalNativeValue: Double {
        if let agg = aggregate {
            return agg.nativeValue
        }
        return holdings.reduce(0) { sum, h in
            let q = h.quote
            let price = q.price > 0 ? q.price : h.holding.avgPrice
            return sum + h.holding.marketValue(currentPrice: price)
        }
    }

    private var totalNativePnl: Double {
        if let agg = aggregate {
            return agg.nativePnl
        }
        return holdings.reduce(0) { sum, h in
            let q = h.quote
            let price = q.price > 0 ? q.price : h.holding.avgPrice
            return sum + h.holding.pnl(currentPrice: price)
        }
    }

    /// Today's regular-session P&L per symbol (native currency, change × quantity × leverage).
    private var totalNativeTodayPnl: Double {
        if let agg = aggregate {
            return agg.todayPnl
        }
        return holdings.reduce(0) { sum, h in
            let q = h.quote
            let scale = (q.isJapaneseFund || h.holding.isJapaneseFund) ? 10000.0 : 1.0
            return sum + (q.change / scale) * h.holding.quantity * h.holding.effectiveLeverage
        }
    }

    private var totalNativePnlPercent: Double {
        if let agg = aggregate {
            return agg.nativePnlPercent
        }
        return abs(totalNativeCost) >= 0.01 ? (totalNativePnl / abs(totalNativeCost)) * 100 : 0
    }

    private var hasKnownCostBasis: Bool {
        aggregate?.hasCostBasis ?? holdings.allSatisfy { $0.holding.hasKnownCostBasis }
    }

    private var amountDec: Int { valueDecimals >= 0 ? valueDecimals : 2 }

    private func priceDec(_ price: Double) -> Int {
        valueDecimals >= 0 ? valueDecimals : StorageService.priceDecimals(symbol: symbol, price: price)
    }

    /// Renders one dynamic metric column cell for this position row.
    @ViewBuilder
    private func metricCell(_ metric: PortfolioColumnMetric) -> some View {
        switch metric {
        case .avgPrice:
            let avg = aggregate?.avgPrice
            let avgValid = avg?.isFinite == true && (avg ?? 0) != 0
            Text(avgValid ? StorageService.formatNumber(avg!, decimals: priceDec(avg!)) : "—")
                .font(DS.figure)
                .foregroundStyle(avgValid ? DS.ink : DS.inkTertiary)
                .lineLimit(1)
                .frame(minWidth: PositionColumnWidth.priceMin, idealWidth: 110, maxWidth: 140, alignment: .trailing)

        case .price:
            VStack(alignment: .trailing, spacing: 2) {
                if let liveQuote {
                    let price = liveQuote.price
                    let dec = priceDec(price)
                    let formattedChange = StorageService.formatNumber(liveQuote.change, decimals: dec, stripTrailingZeros: true)

                    Text(StorageService.formatNumber(price, decimals: dec))
                        .font(DS.figure)
                        .foregroundStyle(DS.ink)
                        .lineLimit(1)

                    Text((liveQuote.change >= 0 ? "+" : "") + formattedChange)
                        .font(DS.micro)
                        .fontWeight(.semibold)
                        .foregroundStyle(DS.pnlColor(liveQuote.change))
                        .lineLimit(1)
                } else {
                    Text("—")
                        .font(DS.figure)
                        .foregroundStyle(DS.inkTertiary)
                }
            }
            .frame(minWidth: PositionColumnWidth.priceMin, idealWidth: 110, maxWidth: 140, alignment: .trailing)

        case .change:
            VStack(alignment: .trailing, spacing: 2) {
                if let liveQuote {
                    let isMarketActive = aggregate?.isMarketActive ?? MarketCategory.isTradingDay(symbol: liveQuote.symbol, quote: liveQuote, isCrypto: isCrypto)

                    let pct = liveQuote.changePercent
                    let pctColor = isMarketActive ? DS.pnlColor(pct) : DS.inkTertiary
                    Text(String(format: "%+.\(percentDecimals)f%%", pct))
                        .font(DS.figure)
                        .fontWeight(.medium)
                        .foregroundStyle(pctColor)
                        .lineLimit(1)

                    if showExtendedHours, let extPct = liveQuote.extendedChangePercent, liveQuote.isExtendedHours {
                        let isPre = liveQuote.marketState.hasPrefix("PRE")
                        HStack(spacing: 2) {
                            Image(systemName: isPre ? "sun.max.fill" : "moon.fill")
                                .font(.system(size: 9))
                            Text(String(format: "%+.\(percentDecimals)f%%", extPct))
                                .font(DS.micro)
                                .fontWeight(.semibold)
                        }
                        .foregroundStyle(DS.pnlColor(extPct))
                        .lineLimit(1)
                    } else if !isMarketActive {
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
                } else {
                    Text("—")
                        .font(DS.figure)
                        .foregroundStyle(DS.inkTertiary)
                }
            }
            .frame(minWidth: PositionColumnWidth.priceMin, idealWidth: 110, maxWidth: 140, alignment: .trailing)

        case .cost:
            if hasKnownCostBasis {
                Text(StorageService.formatAmount(totalNativeCost, symbol: nativeCurrencySymbol, decimals: amountDec))
                    .font(DS.figure).foregroundStyle(DS.ink)
                    .frame(minWidth: PositionColumnWidth.amountMin, idealWidth: 120, maxWidth: 160, alignment: .trailing)
            } else {
                Text("—")
                    .font(DS.figure).foregroundStyle(DS.inkTertiary)
                    .frame(minWidth: PositionColumnWidth.amountMin, idealWidth: 120, maxWidth: 160, alignment: .trailing)
            }

        case .value:
            Text(StorageService.formatAmount(totalNativeValue, symbol: nativeCurrencySymbol, decimals: amountDec))
                .font(DS.figure).foregroundStyle(DS.ink)
                .frame(minWidth: PositionColumnWidth.amountMin, idealWidth: 120, maxWidth: 160, alignment: .trailing)

        case .todayPnl:
            let pnlColor = totalNativeTodayPnl > 0 ? DS.up : (totalNativeTodayPnl < 0 ? DS.down : DS.inkTertiary)
            Text(StorageService.formatAmount(totalNativeTodayPnl, symbol: nativeCurrencySymbol, decimals: amountDec, signed: true))
                .font(DS.figure).foregroundStyle(pnlColor)
                .frame(minWidth: PositionColumnWidth.amountMin, idealWidth: 120, maxWidth: 160, alignment: .trailing)

        case .totalPnl:
            if hasKnownCostBasis {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(StorageService.formatAmount(totalNativePnl, symbol: nativeCurrencySymbol, decimals: amountDec, signed: true))
                        .font(DS.figure)
                        .foregroundStyle(DS.pnlColor(totalNativePnl))
                    ChangePill(
                        value: totalNativePnlPercent,
                        text: String(format: "%+.\(decimals)f%%", totalNativePnlPercent)
                    )
                }
                .frame(minWidth: PositionColumnWidth.amountMin, idealWidth: 120, maxWidth: 160, alignment: .trailing)
            } else {
                Text("—")
                    .font(DS.figure).foregroundStyle(DS.inkTertiary)
                    .frame(minWidth: PositionColumnWidth.amountMin, idealWidth: 120, maxWidth: 160, alignment: .trailing)
            }

        case .shares:
            let totalQty = aggregate?.totalQuantity ?? holdings.reduce(0) { $0 + $1.holding.quantity }
            let qtyDecimals = totalQty.truncatingRemainder(dividingBy: 1) == 0 ? 0 : (totalQty < 1 ? 4 : 2)
            Text(StorageService.formatNumber(totalQty, decimals: qtyDecimals))
                .font(DS.figure)
                .foregroundStyle(DS.ink)
                .frame(minWidth: PositionColumnWidth.sharesMin, idealWidth: 100, maxWidth: 130, alignment: .trailing)

        case .lots:
            Text("\(holdings.count)")
                .font(DS.figure)
                .foregroundStyle(DS.ink)
                .frame(minWidth: PositionColumnWidth.sharesMin, idealWidth: 80, maxWidth: 110, alignment: .trailing)
        case .weight:
            Text(String(format: "%.1f%%", weight))
                .font(DS.figure)
                .foregroundStyle(DS.ink)
                .frame(minWidth: PositionColumnWidth.weightMin, idealWidth: 80, maxWidth: 110, alignment: .trailing)
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            Text("\(position)")
                .font(DS.figure)
                .foregroundStyle(DS.inkSecondary)
                .frame(width: PositionColumnWidth.number, alignment: .leading)

            // Symbol column
            let isJpFund = (liveQuote?.isJapaneseFund ?? false) || StockService.isJapaneseMutualFund(symbol)
            let isDisplayAsset = StockService.isDisplayNameAsset(symbol)
            let titleText = (isJpFund || isDisplayAsset) ? (liveQuote?.displayName ?? StockService.beautifiedSymbol(symbol)) : symbol
            let subTitleText = isDisplayAsset ? symbol : (isJpFund ? "" : (liveQuote?.name ?? ""))

            HStack(spacing: 9) {
                SymbolLogo(symbol: symbol, size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(titleText)
                            .font(DS.figure)
                            .foregroundStyle(DS.ink)
                            .lineLimit(1)
                        if first?.holding.isShort == true {
                            Tag(text: "S", color: DS.down)
                        }
                    }
                    if !subTitleText.isEmpty {
                        Text(subTitleText)
                            .font(DS.micro)
                            .foregroundStyle(DS.inkTertiary)
                            .lineLimit(1)
                    }
                }
            }
            .frame(minWidth: PositionColumnWidth.symbolMin, idealWidth: 230, maxWidth: .infinity, alignment: .leading)

            // Dynamic metric columns
            ForEach(columns) { metric in
                metricCell(metric)
            }

            // Chevron
            Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                .foregroundStyle(hovered ? DS.brand : DS.inkTertiary)
                .frame(width: PositionColumnWidth.chevron)
        }
        .padding(.vertical, 11).padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovered ? DS.cardAlt : .clear))
        .contentShape(Rectangle())
        .onHover { inside in
            hovered = inside
        }
    }
}