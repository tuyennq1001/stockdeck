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
    case daily = "Daily P&L"
    case monthly = "Monthly P&L"
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
    @EnvironmentObject var stockService: StockService
    @EnvironmentObject var storageService: StorageService
    @Environment(\.editHoldingAction) private var editHoldingAction
    @Environment(\.addHoldingAction) private var addHoldingAction
    @Environment(\.portfolioActions) private var portfolioActions

    let viewModel: PortfolioViewModel

    /// Hero chart range — a pure UI filter over the value series.
    enum ChartRange: String, CaseIterable {
        case week = "7D", month = "1M", threeMonths = "3M", sixMonths = "6M", ytd = "YTD", year = "1Y", threeYears = "3Y", fiveYears = "5Y", all = "All"
        var days: Int? {
            switch self {
            case .week: return 7
            case .month: return 30
            case .threeMonths: return 90
            case .sixMonths: return 180
            case .ytd:
                let cal = Calendar.current
                let now = Date()
                let jan1 = cal.date(from: cal.dateComponents([.year], from: now)) ?? now
                return max(1, cal.dateComponents([.day], from: jan1, to: now).day ?? 30)
            case .year: return 365
            case .threeYears: return 365 * 3
            case .fiveYears: return 365 * 5
            case .all: return nil
            }
        }
        /// Suffix for the hero pill, describing the span it measures.
        var changeLabel: String {
            switch self {
            case .week: return "past 7d"
            case .month: return "past 1M"
            case .threeMonths: return "past 3M"
            case .sixMonths: return "past 6M"
            case .ytd: return "YTD"
            case .year: return "past 1Y"
            case .threeYears: return "past 3Y"
            case .fiveYears: return "past 5Y"
            case .all: return "all-time"
            }
        }
        var performancePeriod: PerformancePeriod? {
            switch self {
            case .month: return .m1
            case .threeMonths: return .m3
            case .sixMonths: return .m6
            case .ytd: return .ytd
            case .year: return .y1
            case .threeYears: return .y3
            case .fiveYears: return .y5
            case .week, .all: return nil
            }
        }
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
    @State private var sortColumn: PositionSortColumn = .weight
    @State private var sortAscending: Bool = false
    @State private var showColumnCustomizer = false
    @State private var chartRange: ChartRange = .all
    @State private var hoveredSlice: String?
    @State private var hoverPoint: ValuePoint?
    @State private var hoveredMonth: MonthlyPnlRow?
    @State private var hoveredDay: DailyPnlRow?
    @State private var pnlViewMode: PnlViewMode = .daily
    @State private var dailyPnlRange: DailyPnlRange = .oneYear
    @State private var monthlyPnlRange: MonthlyPnlRange = .threeYears
    @State private var positionsCardWidth: CGFloat = 0
    @State private var confirmDeleteHolding: (holding: Holding, portfolioId: UUID)? = nil

    init(viewModel: PortfolioViewModel) {
        self.viewModel = viewModel
    }

    var scope: PortfolioScope { viewModel.scope }

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
            dailyPnlRange = .oneYear
        }
        if let savedMonthly = storageService.monthlyPnlRange(for: key),
           let range = MonthlyPnlRange(rawValue: savedMonthly) {
            monthlyPnlRange = range
        } else {
            monthlyPnlRange = .threeYears
        }
        if let savedMode = storageService.pnlViewMode(for: key),
           let mode = PnlViewMode(rawValue: savedMode) {
            pnlViewMode = mode
        } else {
            pnlViewMode = .daily
        }
    }

    private func setPositionSort(_ column: PositionSortColumn, ascending: Bool) {
        sortColumn = column
        sortAscending = ascending
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
                Text(title)
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

    /// Tooltip date label — time for intraday ranges, date for the rest.
    private func tooltipDate(_ date: Date) -> String {
        switch chartRange {
        case .week: return date.formatted(.dateTime.weekday(.abbreviated).hour())
        default: return date.formatted(date: .abbreviated, time: .omitted)
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
        if chartRange == .week {
            return valueSeries(from: stockService.intradayWeek)
        }
        
        var cutoff: Date? = nil
        if let days = chartRange.days {
            cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date())
        } else if chartRange == .all {
            if let purchaseDate = earliestPurchaseDate {
                cutoff = Calendar.current.startOfDay(for: purchaseDate)
            } else {
                cutoff = Calendar.current.date(byAdding: .year, value: -5, to: Date())
            }
        }
        
        // Horizontal Deployment: Tôn trọng ngày giao dịch đầu tiên cho TOÀN BỘ các mốc thời gian
        // Không "xuyên không" về quá khứ giả định nếu danh mục chưa tồn tại (chỉ khi toàn bộ vị thế đều có ngày mua)
        let allHoldingsDated = !viewModel.portfolios.flatMap(\.holdings).contains(where: { $0.purchaseDate == nil })
        if allHoldingsDated, let purchaseDate = earliestPurchaseDate {
            let absoluteCutoff = Calendar.current.startOfDay(for: purchaseDate)
            if let current = cutoff {
                cutoff = max(current, absoluteCutoff)
            } else {
                cutoff = absoluteCutoff
            }
        }
        
        // Tư duy triển khai ngang: Tự động chuyển đổi sang dữ liệu Daily (high-res) nếu thời gian thực tế <= 2 năm
        let daysSpan: Int
        if let c = cutoff {
            daysSpan = Calendar.current.dateComponents([.day], from: c, to: Date()).day ?? 9999
        } else {
            daysSpan = 9999
        }
        
        let useMax = daysSpan > 730
        let originalSource = useMax ? stockService.priceHistoryMax : stockService.priceHistory
        
        var source = originalSource
        if let cutoffDate = cutoff {
            var hasData = false
            for (sym, points) in source {
                var filtered = points.filter { $0.date >= cutoffDate }
                if let before = points.last(where: { $0.date < cutoffDate }) {
                    filtered.insert(before, at: 0)
                }
                source[sym] = filtered
                if filtered.count > 1 { hasData = true }
            }
            
            if !hasData && chartRange == .all {
                if let fallbackCutoff = Calendar.current.date(byAdding: .year, value: -5, to: Date()) {
                    source = originalSource
                    for (sym, points) in source {
                        var filtered = points.filter { $0.date >= fallbackCutoff }
                        if let before = points.last(where: { $0.date < fallbackCutoff }) {
                            filtered.insert(before, at: 0)
                        }
                        source[sym] = filtered
                    }
                }
            }
        }
        
        return valueSeries(from: source)
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

    /// Per-month P&L bars (window per `monthlyPnlRange`; `all` extends as far
    /// as real history covers), computed once per scope from real cost basis ×
    /// price history. Keyed by scope + range + holdings + rate fingerprint so a
    /// fresh scope, changed range, or changed positions recompute.
    private var monthlyPnlRows: [MonthlyPnlRow] {
        let hs = viewModel.portfolios.flatMap { $0.holdings }
        let hFingerprint = hs.map {
            "\($0.symbol):\($0.quantity):\($0.avgPrice):\($0.effectiveLeverage):\($0.purchaseDate?.timeIntervalSince1970 ?? 0)"
        }.joined(separator: ";")
        let rateFingerprint = hs.map {
            "\($0.symbol):\(stockService.rate(from: stockService.detectedCurrency(for: $0.symbol)))"
        }.joined(separator: ";")
        let key = "\(scopeKey):m:\(monthlyPnlRange.rawValue):\(hFingerprint):\(rateFingerprint)"
        return MonthlyPnlCache.rows(for: key) {
            var histBySymbol: [String: [PricePoint]] = [:]
            for h in hs {
                histBySymbol[h.symbol] = stockService.priceHistoryMax[h.symbol]
                    ?? stockService.priceHistory[h.symbol]
                    ?? []
            }
            // For `all`, anchor the window on the earliest real purchase date —
            // not on the longest price history. A stock bought last year has 20
            // years of quotes; showing those earlier months would fabricate
            // P&L for a position that didn't exist yet. Without any purchase
            // date (e.g. synced balances), fall back to the price-history span.
            let monthCount: Int
            if let fixed = monthlyPnlRange.fixedMonthCount {
                monthCount = fixed
            } else {
                // `All` extends to the furthest real history: the earliest
                // purchase date OR the earliest price history, whichever is
                // older (capped at 240). `MonthlyPnl.rows` trims any month
                // that carries no data, so nothing fabricated is ever shown.
                let today = Date()
                let calendar = Calendar.current
                var span = 1
                if let earliestPurchase = hs.compactMap(\.purchaseDate).min(),
                   let months = calendar.dateComponents([.month], from: earliestPurchase, to: today).month {
                    span = max(span, months + 1)
                }
                let historySpan = MonthlyPnl.monthCount(for: histBySymbol, today: today, calendar: calendar, maxMonths: 240)
                monthCount = min(max(span, historySpan), 240)
            }
            var rateBySymbol: [String: Double] = [:]
            for h in hs {
                rateBySymbol[h.symbol] = stockService.rate(from: stockService.detectedCurrency(for: h.symbol))
            }
            return MonthlyPnl.rows(holdings: hs, historyBySymbol: histBySymbol, rateBySymbol: rateBySymbol, monthCount: monthCount)
        }
    }

    /// Per-day P&L bars (window per `dailyPnlRange`), the daily counterpart of
    /// `monthlyPnlRows` — computed once per scope using the same fingerprint so
    /// quote ticks never recompute it.
    private var dailyPnlRows: [DailyPnlRow] {
        let hs = viewModel.portfolios.flatMap { $0.holdings }
        let hFingerprint = hs.map {
            "\($0.symbol):\($0.quantity):\($0.avgPrice):\($0.effectiveLeverage):\($0.purchaseDate?.timeIntervalSince1970 ?? 0)"
        }.joined(separator: ";")
        let rateFingerprint = hs.map {
            "\($0.symbol):\(stockService.rate(from: stockService.detectedCurrency(for: $0.symbol)))"
        }.joined(separator: ";")
        let key = "\(scopeKey):d:\(dailyPnlRange.rawValue):\(hFingerprint):\(rateFingerprint)"
        return DailyPnlCache.rows(for: key) {
            var histBySymbol: [String: [PricePoint]] = [:]
            for h in hs {
                histBySymbol[h.symbol] = stockService.priceHistory[h.symbol] ?? []
            }
            var rateBySymbol: [String: Double] = [:]
            for h in hs {
                rateBySymbol[h.symbol] = stockService.rate(from: stockService.detectedCurrency(for: h.symbol))
            }
            return DailyPnl.rows(holdings: hs, historyBySymbol: histBySymbol, rateBySymbol: rateBySymbol, dayCount: dailyPnlRange.dayCount)
        }
    }

    var body: some View {
        PageScaffold(title, caption: "\(holdings.count) positions · \(storageService.preferredCurrency)", trailing: {
            HStack(spacing: 12) {
                portfolioMenu
                RefreshButton(isLoading: stockService.isLoading) {
                    Task { await stockService.refreshAll(storageService: storageService) }
                }
            }
        }) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: DS.gap, pinnedViews: [.sectionHeaders]) {
                        heroCard
                        statRow
                        performanceMatrixCard
                        pnlCard
                        moneyWeightedReturnCard
                        allocationCard
                        HStack(alignment: .top, spacing: DS.gap) {
                            topGainersCard(proxy: proxy).frame(minWidth: 250, maxWidth: .infinity)
                            topLosersCard(proxy: proxy).frame(minWidth: 250, maxWidth: .infinity)
                        }
                        positionsCard.id("positions")
                        PortfolioAIReviewCard(scope: scope, viewModel: viewModel)
                            .id("aiReview")
                    }
                    .pageColumn()
                    .padding(.top, 4)
                }
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
        .onChange(of: chartRange) { _, newRange in
            storageService.setChartRange(newRange.rawValue, for: scopeKey)
        }
        .onChange(of: dailyPnlRange) { _, newRange in
            hoveredDay = nil
            storageService.setDailyPnlRange(newRange.rawValue, for: scopeKey)
        }
        .onChange(of: monthlyPnlRange) { _, newRange in
            hoveredMonth = nil
            storageService.setMonthlyPnlRange(newRange.rawValue, for: scopeKey)
        }
        .onChange(of: pnlViewMode) { _, newMode in
            storageService.setPnlViewMode(newMode.rawValue, for: scopeKey)
        }
        .onChange(of: scopeKey) { _, newKey in
            viewModel.scopeChanged()
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
                    .animation(.spring(response: 0.5, dampingFraction: 0.9), value: totalValue)
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

            heroChart(ds)
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

    private func valueDomain(_ series: [ValuePoint]) -> ClosedRange<Double> {
        let vals = series.map(\.value).filter(\.isFinite)
        guard let lo = vals.min(), let hi = vals.max(), hi > lo else { return 0...1 }
        let span = hi - lo
        return (lo - span * 0.10)...(hi + span * 0.14)
    }

    private func xAxisLabel(_ date: Date) -> String {
        switch chartRange {
        case .week: return date.formatted(.dateTime.weekday(.abbreviated))
        case .month, .threeMonths, .sixMonths, .ytd: return date.formatted(.dateTime.day().month(.abbreviated))
        case .year, .threeYears, .fiveYears, .all:
            return date.formatted(.dateTime.month(.abbreviated).year(.twoDigits))
        }
    }

    @ViewBuilder private func valueCrosshair(_ proxy: ChartProxy, points: [ValuePoint], tint: Color) -> some View {
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
                                         value: StorageService.formatAmount(h.value, symbol: currencySymbol, decimals: storageService.amountDecimals),
                                         tint: tint)
                                .position(x: min(max(cx, plot.minX + 46), plot.maxX - 46), y: plot.minY + 8)
                        }
                        .allowsHitTesting(false)
                    }
                }
            }
        }
    }

    @ViewBuilder private func heroChart(_ points: [ValuePoint]) -> some View {
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
                        .foregroundStyle(tint).lineStyle(.init(lineWidth: 2, dash: [4, 3]))
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
            .chartOverlay { proxy in valueCrosshair(proxy, points: points, tint: tint) }
            .animation(.easeInOut(duration: 0.4), value: points)
            .id(chartRange)
            .transition(.opacity.animation(.easeInOut(duration: 0.4)))
        }
    }

    // MARK: - Stats

    private var statRow: some View {
        HStack(spacing: 12) {
            StatTile(label: "Total P&L",
                     value: StorageService.formatAmount(totalPnl, symbol: currencySymbol, decimals: storageService.amountDecimals, signed: true),
                     caption: String(format: "%+.\(decimals)f%% on cost", totalPnlPercent),
                     captionTint: DS.pnlColor(totalPnl), valueTint: DS.pnlColor(totalPnl),
                     help: "Total profit/loss vs your cost basis")
            StatTile(label: "Today",
                     value: StorageService.formatAmount(dayChangeValue, symbol: currencySymbol, decimals: storageService.amountDecimals, signed: true),
                     caption: String(format: "%+.\(decimals)f%%", dayChangePercent),
                     captionTint: DS.pnlColor(dayChangeValue), valueTint: DS.pnlColor(dayChangeValue),
                     help: "Change since the previous close")
            StatTile(label: "Invested",
                     value: StorageService.formatAmount(totalCost, symbol: currencySymbol, decimals: storageService.amountDecimals),
                     caption: "\(holdings.count) holdings",
                     help: "Total amount invested (cost basis)")
            StatTile(label: "Concentration",
                     value: String(format: "%.1f%%", topWeight),
                     caption: topSymbol.map { topWeight > 40 ? "high · top \($0)" : "top · \($0)" } ?? "—",
                     captionTint: topWeight > 40 ? DS.gold : DS.inkTertiary,
                     help: "Weight of your largest position — a diversification risk gauge")
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
        return Card(title: "Performance & Benchmark") {
            VStack(spacing: 12) {
                HStack(spacing: 0) {
                    Text("Timeline")
                        .font(DS.micro)
                        .foregroundStyle(DS.inkTertiary)
                        .frame(width: 140, alignment: .leading)

                    ForEach(PerformancePeriod.allCases) { p in
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
                        Text(title)
                            .font(DS.figure)
                            .foregroundStyle(DS.ink)
                            .lineLimit(1)
                    }
                    .frame(width: 140, alignment: .leading)

                    ForEach(PerformancePeriod.allCases) { period in
                        let pct = perf.portfolio[period] ?? nil
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

                    ForEach(PerformancePeriod.allCases) { period in
                        let pct = perf.spx[period] ?? nil
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
            }
        }
    }

    /// The combined P&L card: a "Daily P&L" / "Monthly P&L" tab (Daily first)
    /// sharing one axis style and hover behavior. The time-range picker sits
    /// directly beside the tab so the whole control stays compact.
    private var pnlCard: some View {
        Card {
            HStack(spacing: 10) {
                SectionLabel("P&L")
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
            case .daily: dailyPnlChartBody
            case .monthly: monthlyPnlChartBody
            }
        }
    }

    @ViewBuilder private var monthlyPnlChartBody: some View {
        if monthlyPnlRows.isEmpty {
            emptyLine
        } else {
            Chart {
                ForEach(monthlyPnlRows.reversed()) { row in
                    let isHovered = hoveredMonth?.monthStart == row.monthStart
                    BarMark(
                        x: .value("Month", monthAxisLabel(row.monthStart)),
                        yStart: .value("Zero", 0),
                        yEnd: .value("P&L", row.pnl ?? 0),
                        width: .ratio(isHovered ? 0.82 : 0.6)
                    )
                    .foregroundStyle(DS.pnlColor(row.pnl ?? 0))
                    .opacity(isHovered ? 1.0 : 0.75)
                    .cornerRadius(3)
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

            Divider().overlay(DS.hairline.opacity(0.5))

            Text("Real cost basis × price history — adding cash or positions doesn't inflate P&L.")
                .font(DS.micro)
                .foregroundStyle(DS.inkTertiary)
                .padding(.top, 6)
        }
    }

    @ViewBuilder private var dailyPnlChartBody: some View {
        if dailyPnlRows.isEmpty {
            emptyLine
        } else {
            Chart {
                ForEach(dailyPnlRows.reversed()) { row in
                    let isHovered = hoveredDay?.date == row.date
                    BarMark(
                        x: .value("Day", row.label),
                        yStart: .value("Zero", 0),
                        yEnd: .value("P&L", row.pnl ?? 0),
                        width: .ratio(isHovered ? 0.82 : 0.55)
                    )
                    .foregroundStyle(DS.pnlColor(row.pnl ?? 0))
                    .opacity(isHovered ? 1.0 : 0.75)
                    .cornerRadius(2)
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

            Text("Daily P&L from real cost basis × price history — adding cash or positions doesn't inflate P&L.")
                .font(DS.micro)
                .foregroundStyle(DS.inkTertiary)
                .padding(.top, 6)
        }
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
                ChartTooltip(title: monthAxisLabel(h.monthStart),
                             value: StorageService.formatAmount(pnl, symbol: currencySymbol, decimals: storageService.amountDecimals, signed: true),
                             tint: DS.pnlColor(pnl))
                    .position(x: min(max(cx, plot.minX + 46), plot.maxX - 46), y: plot.minY + 8)
                    .allowsHitTesting(false)
            }
        }
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
                ChartTooltip(title: h.label,
                             value: StorageService.formatAmount(pnl, symbol: currencySymbol, decimals: storageService.amountDecimals, signed: true),
                             tint: DS.pnlColor(pnl))
                    .position(x: min(max(cx, plot.minX + 46), plot.maxX - 46), y: plot.minY + 8)
                    .allowsHitTesting(false)
            }
        }
    }

    /// X-axis tick labels for the daily chart. Picks evenly spaced days so the
    /// axis stays readable even at 365 columns (targets ~6 labels).
    private var dayAxisValues: [String] {
        let rows = dailyPnlRows
        guard rows.count > 12 else {
            return rows.map(\.label)
        }
        let target = 6
        let step = max(1, (rows.count + target - 1) / target)
        var values: [String] = []
        for i in stride(from: 0, to: rows.count, by: step) {
            values.append(rows[i].label)
        }
        return values
    }

    private func monthAxisLabel(_ date: Date) -> String {
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month], from: date)
        return "\(comps.year ?? 0)/\(comps.month ?? 0)"
    }

    /// X-axis tick labels for the monthly chart. Picks evenly spaced months so
    /// the axis stays readable even at 24–36 columns (targets ~6 labels).
    private var monthAxisValues: [String] {
        let rows = monthlyPnlRows
        guard rows.count > 8 else {
            return rows.map { monthAxisLabel($0.monthStart) }
        }
        let target = 6
        let step = max(1, (rows.count + target - 1) / target)
        var values: [String] = []
        for i in stride(from: 0, to: rows.count, by: step) {
            values.append(monthAxisLabel(rows[i].monthStart))
        }
        return values
    }

    private var moneyWeightedReturnCard: some View {
        let res = moneyWeightedComparison
        let pXIRR = res.portfolioXIRR
        let bXIRR = res.benchmarkXIRR

        let pFormatted = pXIRR.map { String(format: "%+.\(decimals)f%%", $0) } ?? "—"
        let bFormatted = bXIRR.map { String(format: "%+.\(decimals)f%%", $0) } ?? "—"

        let verdict: String? = {
            guard let p = pXIRR, let b = bXIRR else { return nil }
            let diff = p - b
            if abs(diff) < 0.05 {
                return "Matching S&P 500 performance"
            } else if diff > 0 {
                return String(format: "Beating S&P 500 by +%.1f pp/yr", diff)
            } else {
                return String(format: "Trailing S&P 500 by -%.1f pp/yr", abs(diff))
            }
        }()

        return Card(title: "Your Actual Return (XIRR)") {
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
                } else if res.excludedHoldingsCount == portfolios.flatMap({ $0.holdings }).count {
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

                    if let verdict {
                        HStack(spacing: 6) {
                            Image(systemName: (pXIRR ?? 0) >= (bXIRR ?? 0) ? "checkmark.circle.fill" : "arrow.down.circle.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(DS.pnlColor((pXIRR ?? 0) - (bXIRR ?? 0)))
                            Text(verdict)
                                .font(DS.figure.weight(.semibold))
                                .foregroundStyle(DS.pnlColor((pXIRR ?? 0) - (bXIRR ?? 0)))
                        }
                    }

                    if res.excludedHoldingsCount > 0 {
                        Text("\(res.excludedHoldingsCount) position\(res.excludedHoldingsCount == 1 ? "" : "s") without a purchase date excluded.")
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

    private var topSymbol: String? { allocation.first?.symbol }
    private var topWeight: Double { (allocation.first?.fraction ?? 0) * 100 }

    // MARK: - Allocation (donut + legend + type strip)

    private struct AllocationSlice: Identifiable {
        let id: String
        let symbol: String
        let value: Double
        let fraction: Double
    }
    private var allocation: [AllocationSlice] {
        let total = holdings.reduce(0) { $0 + abs($1.value) }
        guard total >= 0.01 else { return [] }
        var bySymbol: [String: Double] = [:]
        for h in holdings { bySymbol[h.symbol, default: 0] += abs(h.value) }
        return bySymbol.map { AllocationSlice(id: $0.key, symbol: $0.key, value: $0.value, fraction: $0.value / total) }
            .sorted { $0.value > $1.value }
    }

    private func allocationRow(_ slice: AllocationSlice) -> some View {
        HStack(spacing: 9) {
            RoundedRectangle(cornerRadius: 2.5).fill(color(for: slice.symbol)).frame(width: 9, height: 9)
            SymbolLogo(symbol: slice.symbol, size: 20)
            let displayName = stockService.quotes[slice.symbol]?.displayName ?? StockService.codeToFundNameMap[slice.symbol] ?? slice.symbol
            Text(displayName).font(DS.figure).foregroundStyle(DS.ink).lineLimit(1)
            Spacer()
            Text(String(format: "%.1f%%", slice.fraction * 100))
                .font(DS.figure).foregroundStyle(DS.inkSecondary)
        }
    }

    private var allocationCard: some View {
        Card(title: "Allocation") {
            if allocation.isEmpty {
                emptyLine
            } else {
                VStack(spacing: 16) {
                    HStack(spacing: 20) {
                        ZStack {
                            Chart(allocation) { slice in
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

                        ScrollView(.vertical, showsIndicators: true) {
                            VStack(alignment: .leading, spacing: 9) {
                                ForEach(allocation) { slice in
                                    let matchedHolding = holdings.first(where: { StockService.canonicalSymbol(for: $0.symbol) == StockService.canonicalSymbol(for: slice.symbol) })
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
                        }
                        .frame(maxHeight: 140)
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

    private func color(for symbol: String) -> Color {
        let idx = allocation.firstIndex { $0.symbol == symbol } ?? 0
        return DS.palette[idx % DS.palette.count]
    }

    // MARK: - Movers (Top & Bottom)

    private func topGainersCard(proxy: ScrollViewProxy) -> some View {
        Card(title: "Top Gainers") {
            var seen = Set<String>()
            let gainers = holdings.filter { $0.dayChangePercent > 0 && seen.insert($0.symbol).inserted }
                .sorted { $0.dayChangePercent > $1.dayChangePercent }
            let maxAbs = gainers.map { abs($0.dayChangePercent) }.max() ?? 1
            if gainers.isEmpty {
                emptyLine
            } else {
                VStack(spacing: 0) {
                    ForEach(gainers.prefix(5)) { h in
                        moverRow(h, maxAbs: maxAbs, lastId: gainers.prefix(5).last?.id)
                    }
                }
            }
        }
    }

    private func topLosersCard(proxy: ScrollViewProxy) -> some View {
        Card(title: "Top Losers") {
            var seen = Set<String>()
            let losers = holdings.filter { $0.dayChangePercent < 0 && seen.insert($0.symbol).inserted }
                .sorted { $0.dayChangePercent < $1.dayChangePercent }
            let maxAbs = losers.map { abs($0.dayChangePercent) }.max() ?? 1
            if losers.isEmpty {
                emptyLine
            } else {
                VStack(spacing: 0) {
                    ForEach(losers.prefix(5)) { h in
                        moverRow(h, maxAbs: maxAbs, lastId: losers.prefix(5).last?.id)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func moverRow(_ h: ValuedHolding, maxAbs: Double, lastId: UUID?) -> some View {
        let isJpFund = h.quote.isJapaneseFund || stockService.isJapaneseMutualFund(h.symbol)
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
        let total = holdings.reduce(0) { $0 + abs($1.value) }
        guard total >= 0.01 else { return [] }
        var byType: [String: Double] = [:]
        for h in holdings { byType[Self.typeLabel(h.type), default: 0] += abs(h.value) }
        return byType.map { ($0.key, $0.value / total) }.sorted { $0.1 > $1.1 }
    }
    private static func typeLabel(_ type: String) -> String {
        switch type.uppercased() {
        case "EQUITY": return "Stocks"
        case "ETF": return "ETFs"
        case "CRYPTOCURRENCY": return "Crypto"
        case "INDEX": return "Indices"
        case "FUTURE": return "Futures"
        case "MUTUALFUND": return "Funds"
        case "CURRENCY": return "Currency"
        case "": return "Other"
        default: return type.capitalized
        }
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

    private func sortedSymbols(groupedValued: [String: [ValuedHolding]]) -> [String] {
        if sortColumn == .manual {
            return insertionOrderedSymbols.filter { groupedValued[$0] != nil }
        }
        return groupedValued.keys.sorted { sym1, sym2 in
            let isAsc = sortAscending

            switch sortColumn {
            case .manual:
                return false
            case .symbol:
                return isAsc ? sym1 < sym2 : sym1 > sym2
            case .avgPrice:
                let a1 = viewModel.symbolAggregates[sym1]?.avgPrice ?? .nan
                let a2 = viewModel.symbolAggregates[sym2]?.avgPrice ?? .nan
                return isAsc ? a1 < a2 : a1 > a2
            case .price:
                let p1 = groupedValued[sym1]?.first?.quote.changePercent ?? 0
                let p2 = groupedValued[sym2]?.first?.quote.changePercent ?? 0
                return isAsc ? p1 < p2 : p1 > p2
            case .extended:
                let e1 = groupedValued[sym1]?.first?.quote.extendedChangePercent
                let e2 = groupedValued[sym2]?.first?.quote.extendedChangePercent
                switch (e1, e2) {
                case let (l?, r?): return isAsc ? l < r : l > r
                case (_?, nil): return true
                case (nil, _?): return false
                case (nil, nil): return isAsc ? sym1 < sym2 : sym1 > sym2
                }
            case .cost:
                let c1 = viewModel.symbolAggregates[sym1]?.nativeCost ?? groupedValued[sym1]?.reduce(0) { $0 + $1.cost } ?? 0
                let c2 = viewModel.symbolAggregates[sym2]?.nativeCost ?? groupedValued[sym2]?.reduce(0) { $0 + $1.cost } ?? 0
                return isAsc ? c1 < c2 : c1 > c2
            case .value:
                let v1 = viewModel.symbolAggregates[sym1]?.value ?? groupedValued[sym1]?.reduce(0) { $0 + $1.value } ?? 0
                let v2 = viewModel.symbolAggregates[sym2]?.value ?? groupedValued[sym2]?.reduce(0) { $0 + $1.value } ?? 0
                return isAsc ? v1 < v2 : v1 > v2
            case .todayPnl:
                let t1 = todayPnl(for: sym1, grouped: groupedValued)
                let t2 = todayPnl(for: sym2, grouped: groupedValued)
                return isAsc ? t1 < t2 : t1 > t2
            case .pnl:
                let pnl1 = viewModel.symbolAggregates[sym1]?.pnl ?? groupedValued[sym1]?.reduce(0) { $0 + ($1.value - $1.cost) } ?? 0
                let pnl2 = viewModel.symbolAggregates[sym2]?.pnl ?? groupedValued[sym2]?.reduce(0) { $0 + ($1.value - $1.cost) } ?? 0
                return isAsc ? pnl1 < pnl2 : pnl1 > pnl2
            case .shares:
                let s1 = viewModel.symbolAggregates[sym1]?.totalQuantity ?? groupedValued[sym1]?.reduce(0) { $0 + $1.holding.quantity } ?? 0
                let s2 = viewModel.symbolAggregates[sym2]?.totalQuantity ?? groupedValued[sym2]?.reduce(0) { $0 + $1.holding.quantity } ?? 0
                return isAsc ? s1 < s2 : s1 > s2
            case .weight:
                let w1 = abs(totalValue) >= 0.01 ? (abs(groupedValued[sym1]?.reduce(0) { $0 + $1.value } ?? 0) / abs(totalValue) * 100) : 0
                let w2 = abs(totalValue) >= 0.01 ? (abs(groupedValued[sym2]?.reduce(0) { $0 + $1.value } ?? 0) / abs(totalValue) * 100) : 0
                return isAsc ? w1 < w2 : w1 > w2
            }
        }
    }

    private var positionsCard: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                SectionLabel("Positions")
                Spacer()
                columnCustomizerButton
                addHoldingButton
            }
            if holdings.isEmpty {
                VStack(spacing: 10) {
                    Text("No holdings yet").font(DS.bodyStrong).foregroundStyle(DS.ink)
                    Text("Add your first position to start tracking value and P&L.")
                        .font(DS.caption).foregroundStyle(DS.inkSecondary)
                    addHoldingButton
                }
                .frame(maxWidth: .infinity).padding(.vertical, 18)
            } else {
                let minTableWidth: CGFloat = positionsTableNaturalWidth
                let availableWidth = max(positionsCardWidth - (DS.pad * 2), minTableWidth)
                let groupedValued = Dictionary(grouping: holdings) { StockService.canonicalSymbol(for: $0.symbol) }
                let symbolsList = sortedSymbols(groupedValued: groupedValued)

                ScrollView(.horizontal, showsIndicators: true) {
                    LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                        Section(header: positionsHeaderView) {
                            ForEach(Array(symbolsList.enumerated()), id: \.element) { index, sym in
                                if let group = groupedValued[sym], let first = group.first {
                                    let groupVal = viewModel.symbolAggregates[sym]?.value ?? group.reduce(0) { $0 + $1.value }
                                    let weight = abs(totalValue) >= 0.01 ? abs(groupVal) / abs(totalValue) * 100 : 0

                                    NavigationLink(value: first.id) {
                                        PositionSummaryRow(
                                            position: index + 1,
                                            symbol: sym,
                                            holdings: group,
                                            currencySymbol: currencySymbol,
                                            weight: weight,
                                            topWeight: topWeight,
                                            decimals: decimals,
                                            valueDecimals: storageService.valueDecimals,
                                            showExtendedHours: storageService.showExtendedHours,
                                            aggregate: viewModel.symbolAggregates[sym],
                                            columns: selectedColumns
                                        )
                                    }
                                    .buttonStyle(.plain)
                                    .help("View \(sym) details")
                                    .contextMenu {
                                        let isPortReadOnly = storageService.portfolios.first(where: { $0.id == first.portfolioId })?.isReadOnly ?? false
                                        if group.count == 1 && !isPortReadOnly {
                                            Button { editHoldingAction.perform(first.portfolioId, first.holding) } label: { Label("Edit", systemImage: "pencil") }
                                            Button(role: .destructive) {
                                                confirmDeleteHolding = (first.holding, first.portfolioId)
                                            } label: { Label("Delete", systemImage: "trash") }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .frame(minWidth: max(availableWidth, minTableWidth))
                }
            }
        }
        .padding(DS.pad)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            GeometryReader { geo in
                Color.clear.preference(key: CardWidthPreferenceKey.self, value: geo.size.width)
            }
        )
        .onPreferenceChange(CardWidthPreferenceKey.self) { width in
            if width > 0 && abs(positionsCardWidth - width) > 1 {
                positionsCardWidth = width
            }
        }
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

    /// Today's regular-session P&L (native currency) for a symbol group.
    private func todayPnl(for symbol: String, grouped: [String: [ValuedHolding]]) -> Double {
        guard let group = grouped[symbol] else { return 0 }
        return group.reduce(0) { sum, h in
            let q = stockService.quotes[h.holding.symbol] ?? stockService.quotes[h.holding.symbol.uppercased()] ?? h.quote
            let isJpFund = q.isJapaneseFund || stockService.isJapaneseMutualFund(h.holding.symbol) || h.holding.isJapaneseFund
            let scale = isJpFund ? 10000.0 : 1.0
            return sum + (q.change / scale) * h.holding.quantity * h.holding.effectiveLeverage
        }
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

private struct CardWidthPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let next = nextValue()
        if next > 0 { value = next }
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
    @EnvironmentObject var storageService: StorageService
    @EnvironmentObject var stockService: StockService
    let position: Int
    let symbol: String
    let holdings: [ValuedHolding]
    let currencySymbol: String
    let weight: Double
    let topWeight: Double
    let decimals: Int
    let valueDecimals: Int
    let showExtendedHours: Bool
    /// Pre-computed per-symbol aggregate from ViewModel (nil fallback for legacy).
    let aggregate: PortfolioViewModel.SymbolAggregate?
    /// Visible custom columns (rank # and Symbol are always present).
    let columns: [PortfolioColumnMetric]

    @State private var hovered = false

    private var first: ValuedHolding? { holdings.first }

    private var liveQuote: StockQuote? {
        if let holdingSymbol = holdings.first?.holding.symbol,
           let quote = stockService.quotes[holdingSymbol] ?? stockService.quotes[holdingSymbol.uppercased()] {
            return quote
        }
        return stockService.quotes[symbol] ?? stockService.quotes[symbol.uppercased()] ?? first?.quote
    }

    private var nativeCurrencySymbol: String {
        let curr = stockService.detectedCurrency(for: symbol)
        return StorageService.currencySymbol(for: curr)
    }

    /// Use pre-computed aggregate when available, fall back to per-row computation.
    private var totalNativeCost: Double {
        if let agg = aggregate, agg.nativeCost != 0 {
            return agg.nativeCost
        }
        return holdings.reduce(0) { $0 + $1.holding.costBasisLocal }
    }

    private var totalNativeValue: Double {
        if let agg = aggregate, agg.nativeValue != 0 {
            return agg.nativeValue
        }
        return holdings.reduce(0) { sum, h in
            let q = stockService.quotes[h.holding.symbol] ?? stockService.quotes[h.holding.symbol.uppercased()] ?? h.quote
            let price = q.price > 0 ? q.price : h.holding.avgPrice
            return sum + h.holding.marketValue(currentPrice: price)
        }
    }

    private var totalNativePnl: Double {
        if let agg = aggregate {
            return agg.nativePnl
        }
        return holdings.reduce(0) { sum, h in
            let q = stockService.quotes[h.holding.symbol] ?? stockService.quotes[h.holding.symbol.uppercased()] ?? h.quote
            let price = q.price > 0 ? q.price : h.holding.avgPrice
            return sum + h.holding.pnl(currentPrice: price)
        }
    }

    /// Today's regular-session P&L per symbol (native currency, change × quantity × leverage).
    private var totalNativeTodayPnl: Double {
        holdings.reduce(0) { sum, h in
            let q = stockService.quotes[h.holding.symbol] ?? stockService.quotes[h.holding.symbol.uppercased()] ?? h.quote
            let scale = (q.isJapaneseFund || stockService.isJapaneseMutualFund(h.holding.symbol) || h.holding.isJapaneseFund) ? 10000.0 : 1.0
            return sum + (q.change / scale) * h.holding.quantity * h.holding.effectiveLeverage
        }
    }

    private var totalNativePnlPercent: Double {
        abs(totalNativeCost) >= 0.01 ? (totalNativePnl / abs(totalNativeCost)) * 100 : 0
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
                        .contentTransition(.numericText())
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
                    let pct = liveQuote.changePercent
                    Text(String(format: "%+.\(storageService.percentDecimals)f%%", pct))
                        .font(DS.figure)
                        .fontWeight(.medium)
                        .foregroundStyle(DS.pnlColor(pct))
                        .lineLimit(1)

                    if showExtendedHours, let extPct = liveQuote.extendedChangePercent, liveQuote.isExtendedHours {
                        let isPre = liveQuote.marketState.hasPrefix("PRE")
                        HStack(spacing: 2) {
                            Image(systemName: isPre ? "sun.max.fill" : "moon.fill")
                                .font(.system(size: 9))
                            Text(String(format: "%+.\(storageService.percentDecimals)f%%", extPct))
                                .font(DS.micro)
                                .fontWeight(.semibold)
                        }
                        .foregroundStyle(DS.pnlColor(extPct))
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
            if holdings.allSatisfy({ $0.holding.hasKnownCostBasis }) {
                Text(StorageService.formatAmount(totalNativeCost, symbol: nativeCurrencySymbol, decimals: amountDec))
                    .font(DS.figure).foregroundStyle(DS.ink)
                    .contentTransition(.numericText())
                    .frame(minWidth: PositionColumnWidth.amountMin, idealWidth: 120, maxWidth: 160, alignment: .trailing)
            } else {
                Text("—")
                    .font(DS.figure).foregroundStyle(DS.inkTertiary)
                    .frame(minWidth: PositionColumnWidth.amountMin, idealWidth: 120, maxWidth: 160, alignment: .trailing)
            }

        case .value:
            Text(StorageService.formatAmount(totalNativeValue, symbol: nativeCurrencySymbol, decimals: amountDec))
                .font(DS.figure).foregroundStyle(DS.ink)
                .contentTransition(.numericText())
                .frame(minWidth: PositionColumnWidth.amountMin, idealWidth: 120, maxWidth: 160, alignment: .trailing)

        case .todayPnl:
            Text(StorageService.formatAmount(totalNativeTodayPnl, symbol: nativeCurrencySymbol, decimals: amountDec, signed: true))
                .font(DS.figure).foregroundStyle(DS.pnlColor(totalNativeTodayPnl))
                .contentTransition(.numericText())
                .frame(minWidth: PositionColumnWidth.amountMin, idealWidth: 120, maxWidth: 160, alignment: .trailing)

        case .totalPnl:
            if holdings.allSatisfy({ $0.holding.hasKnownCostBasis }) {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(StorageService.formatAmount(totalNativePnl, symbol: nativeCurrencySymbol, decimals: amountDec, signed: true))
                        .font(DS.figure)
                        .foregroundStyle(DS.pnlColor(totalNativePnl))
                        .contentTransition(.numericText())
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
                .contentTransition(.numericText())
                .frame(minWidth: PositionColumnWidth.sharesMin, idealWidth: 100, maxWidth: 130, alignment: .trailing)

        case .lots:
            Text("\(holdings.count)")
                .font(DS.figure)
                .foregroundStyle(DS.ink)
                .contentTransition(.numericText())
                .frame(minWidth: PositionColumnWidth.sharesMin, idealWidth: 80, maxWidth: 110, alignment: .trailing)
        case .weight:
            Text(String(format: "%.1f%%", weight))
                .font(DS.figure)
                .foregroundStyle(DS.ink)
                .contentTransition(.numericText())
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
            let isJpFund = (liveQuote?.isJapaneseFund ?? false) || stockService.isJapaneseMutualFund(symbol)
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
        .animation(.easeOut(duration: 0.15), value: hovered)
        .contentShape(Rectangle())
        .pointingHandCursor()
        .onHover { inside in
            hovered = inside
        }
    }
}