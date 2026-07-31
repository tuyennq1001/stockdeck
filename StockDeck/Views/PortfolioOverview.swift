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

struct PortfolioOverview: View {
    @EnvironmentObject var stockService: StockService
    @EnvironmentObject var storageService: StorageService
    @Environment(\.editHoldingAction) private var editHoldingAction
    @Environment(\.addHoldingAction) private var addHoldingAction
    @Environment(\.portfolioActions) private var portfolioActions
    let scope: PortfolioWindowView.Scope

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
        case price
        case extended
        case cost
        case value
        case pnl
        case weight
    }
    @State private var sortColumn: PositionSortColumn = .weight
    @State private var sortAscending: Bool = false
    @State private var chartRange: ChartRange = .all
    @State private var hoveredSlice: String?
    @State private var hoverPoint: ValuePoint?
    @State private var positionsCardWidth: CGFloat = 0

    private var insertionOrderedSymbols: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for p in portfolios {
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

    private func sortHeader(_ title: String, column: PositionSortColumn) -> some View {
        Button(action: {
            if sortColumn == column {
                sortAscending.toggle()
            } else {
                sortColumn = column
                sortAscending = (column == .symbol)
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

    /// Tooltip date label — time for intraday ranges, date for the rest.
    private func tooltipDate(_ date: Date) -> String {
        switch chartRange {
        case .week: return date.formatted(.dateTime.weekday(.abbreviated).hour())
        default: return date.formatted(date: .abbreviated, time: .omitted)
        }
    }

    private var portfolios: [Portfolio] {
        switch scope {
        case .all: return storageService.portfolios
        case .portfolio(let id): return storageService.portfolios.filter { $0.id == id }
        }
    }

    private var title: String {
        switch scope {
        case .all: return "Portfolio"
        case .portfolio(let id): return storageService.portfolios.first { $0.id == id }?.name ?? "Portfolio"
        }
    }

    private var currencySymbol: String { StorageService.currencySymbol(for: storageService.preferredCurrency) }
    private var decimals: Int { storageService.percentDecimals }

    private struct ValuationBundle {
        let holdings: [ValuedHolding]
        let totalValue: Double
        let totalCost: Double
        let totalPnl: Double
        let totalPnlPercent: Double
        let dayChangeValue: Double
        let dayChangePercent: Double
    }

    private var valuationBundle: ValuationBundle {
        var valuedHoldings: [ValuedHolding] = []
        var totalVal: Double = 0
        var totalCst: Double = 0
        var todayInputs: [TodayPerformance.Input] = []

        for portfolio in portfolios {
            for holding in portfolio.holdings {
                let quote = stockService.quotes[holding.symbol] ?? stockService.quotes[holding.symbol.uppercased()] ?? StockQuote(
                    symbol: holding.symbol,
                    name: holding.symbol,
                    price: holding.avgPrice,
                    change: 0,
                    changePercent: 0,
                    currency: stockService.detectedCurrency(for: holding.symbol)
                )
                let price = quote.price
                let currency = stockService.detectedCurrency(for: holding.symbol)
                let rate = stockService.rate(from: currency)
                let costRate = stockService.rate(from: currency, for: holding.purchaseDate)
                let isJpFund = quote.isJapaneseFund || stockService.isJapaneseMutualFund(holding.symbol) || holding.isJapaneseFund
                let scale = isJpFund ? 10000.0 : 1.0
                let lev = holding.effectiveLeverage
                let qty = holding.quantity
                let value = (price / scale) * qty * lev * rate
                let cost = (holding.avgPrice / scale) * qty * lev * costRate

                totalVal += value
                totalCst += cost

                valuedHoldings.append(ValuedHolding(
                    id: holding.id, portfolioId: portfolio.id, holding: holding, quote: quote,
                    value: value, cost: cost, dayChangePercent: quote.changePercent,
                    type: storageService.type(for: holding.symbol)
                ))

                if let liveQuote = stockService.quotes[holding.symbol] ?? stockService.quotes[holding.symbol.uppercased()] {
                    todayInputs.append(TodayPerformance.Input(
                        holding: holding,
                        regularPrice: liveQuote.price,
                        previousClose: liveQuote.previousClose,
                        rate: rate
                    ))
                }
            }
        }

        valuedHoldings.sort { abs($0.value) > abs($1.value) }

        let pnl = totalVal - totalCst
        let pnlPct = abs(totalCst) >= 0.01 ? (pnl / abs(totalCst)) * 100 : 0
        let todayTotals = TodayPerformance.totals(todayInputs)

        return ValuationBundle(
            holdings: valuedHoldings,
            totalValue: totalVal,
            totalCost: totalCst,
            totalPnl: pnl,
            totalPnlPercent: pnlPct,
            dayChangeValue: todayTotals.gain,
            dayChangePercent: todayTotals.percent
        )
    }

    private var holdings: [ValuedHolding] { valuationBundle.holdings }
    private var totalValue: Double { valuationBundle.totalValue }
    private var totalCost: Double { valuationBundle.totalCost }
    private var totalPnl: Double { valuationBundle.totalPnl }
    private var totalPnlPercent: Double { valuationBundle.totalPnlPercent }
    private var dayChangeValue: Double { valuationBundle.dayChangeValue }
    private var dayChangePercent: Double { valuationBundle.dayChangePercent }

    private var earliestPurchaseDate: Date? {
        let dates = holdings.compactMap(\.holding.purchaseDate)
        return dates.min()
    }

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

    private var filteredSeries: [PortfolioSnapshot] {
        let baseSeries: [PortfolioSnapshot] = {
            if let days = chartRange.days,
               let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) {
                return series.filter { $0.date >= cutoff }
            } else if chartRange == .all {
                if let purchaseDate = earliestPurchaseDate {
                    let cutoff = Calendar.current.startOfDay(for: purchaseDate)
                    let filtered = series.filter { $0.date >= cutoff }
                    if !filtered.isEmpty { return filtered }
                }
                if let cutoff5Y = Calendar.current.date(byAdding: .year, value: -5, to: Date()) {
                    return series.filter { $0.date >= cutoff5Y }
                }
            }
            return series
        }()

        let currentVal = totalValue
        guard currentVal > 0 else { return baseSeries }
        return baseSeries.filter { snap in
            let ratio = snap.totalValue / currentVal
            return ratio >= 0.25 && ratio <= 4.0
        }
    }

    /// Builds an estimated value curve from a given per-symbol price history
    /// (daily / hourly / 5-min) × current positions, in the preferred currency.
    private func valueSeries(from histBySymbol: [String: [PricePoint]]) -> [ValuePoint] {
        let hs = portfolios.flatMap { $0.holdings }
        var rate: [String: Double] = [:]
        var hist: [String: [PricePoint]] = [:]
        for h in hs {
            let curr = stockService.detectedCurrency(for: h.symbol)
            rate[h.symbol] = stockService.rate(from: curr)
            if let ph = histBySymbol[h.symbol] { hist[h.symbol] = ph }
        }
        return PortfolioBackfill.series(holdings: hs, historyBySymbol: hist, rateBySymbol: rate)
    }

    /// Daily estimate (2y) for 1M/1Y; monthly full history for 3Y, 5Y, and "All".
    private var estimatedSeries: [ValuePoint] {
        let useMax = (chartRange == .all || chartRange == .threeYears || chartRange == .fiveYears)
        return valueSeries(from: useMax ? stockService.priceHistoryMax : stockService.priceHistory)
    }
    private var estimatedFiltered: [ValuePoint] {
        if let days = chartRange.days,
           let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) {
            return estimatedSeries.filter { $0.date >= cutoff }
        } else if chartRange == .all {
            if let purchaseDate = earliestPurchaseDate {
                let cutoff = Calendar.current.startOfDay(for: purchaseDate)
                let filtered = estimatedSeries.filter { $0.date >= cutoff }
                if !filtered.isEmpty { return filtered }
            }
            if let cutoff5Y = Calendar.current.date(byAdding: .year, value: -5, to: Date()) {
                let filtered = estimatedSeries.filter { $0.date >= cutoff5Y }
                if !filtered.isEmpty { return filtered }
            }
        }
        return estimatedSeries
    }

    /// The curve actually drawn and used for period change calculations.
    /// Uses intraday 5-min series for 7D, and daily price-history market curve for 1M+.
    /// This ensures period changes reflect true market performance consistently across
    /// the top pill and the Performance & Benchmark matrix without distortion from cash/holding additions.
    private var displaySeries: (points: [ValuePoint], isEstimated: Bool) {
        if chartRange == .week {
            return (valueSeries(from: stockService.intradayWeek), true)
        } else {
            return (estimatedFiltered, true)
        }
    }

    private var symbols: [String] { Array(Set(portfolios.flatMap { $0.holdings.map(\.symbol) })) }

    private var scopeKey: String {
        switch scope {
        case .all: return "all"
        case .portfolio(let id): return id.uuidString
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
                    VStack(alignment: .leading, spacing: DS.gap) {
                        heroCard
                        statRow
                        performanceMatrixCard
                        moneyWeightedReturnCard
                        allocationCard
                        HStack(alignment: .top, spacing: DS.gap) {
                            topGainersCard(proxy: proxy).frame(minWidth: 250, maxWidth: .infinity)
                            topLosersCard(proxy: proxy).frame(minWidth: 250, maxWidth: .infinity)
                        }
                        positionsCard.id("positions")
                    }
                    .pageColumn()
                    .padding(.top, 4)
                }
            }
        }
        .navigationTitle(title)
        .onAppear {
            if let savedRaw = storageService.chartRange(for: scopeKey),
               let range = ChartRange(rawValue: savedRaw) {
                chartRange = range
            }
        }
        .onChange(of: chartRange) { _, newRange in
            storageService.setChartRange(newRange.rawValue, for: scopeKey)
        }
        .onChange(of: scopeKey) { _, newKey in
            if let savedRaw = storageService.chartRange(for: newKey),
               let range = ChartRange(rawValue: savedRaw) {
                chartRange = range
            } else {
                chartRange = .all
            }
        }
        .task(id: symbols) {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await stockService.ensurePriceHistoryMax(for: "^GSPC") }
                for symbol in symbols {
                    let s = symbol
                    group.addTask { await stockService.ensurePriceHistory(for: s) }
                    group.addTask { await stockService.ensurePriceHistoryMax(for: s) }
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
            case .threeYears, .fiveYears, .all:
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
        // Compute the (expensive) value series ONCE per render — it was being
        // recomputed 5× (badge, picker, chart points, chart dash), which showed
        // up as lag when switching portfolios (each switch rebuilds this view).
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
            periodValue = PortfolioPeriodChange.value(ds.points) ?? dayChangeValue
            periodPercent = PortfolioPeriodChange.percent(ds.points) ?? dayChangePercent
            periodLabel = PortfolioPeriodChange.percent(ds.points) != nil ? chartRange.changeLabel : "today"
        }
        
        let cagrVal = PortfolioPeriodChange.cagr(ds.points)
        let pillText: String
        if let cagrVal {
            pillText = String(format: "%+.\(decimals)f%% %@ (%.1f%% CAGR)", periodPercent, periodLabel, cagrVal)
        } else {
            pillText = String(format: "%+.\(decimals)f%% %@", periodPercent, periodLabel)
        }
        
        // Header sits ABOVE the chart (not over it) so the curve can never rise
        // behind the value/pill text.
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top) {
                    SectionLabel("\(title) value")
                    Spacer()
                    // No picker over an empty chart — it appears with the data.
                    if !ds.points.isEmpty { rangePicker }
                }
                Text(StorageService.formatAmount(totalValue, symbol: currencySymbol, decimals: storageService.amountDecimals))
                    .font(DS.display).tracking(-0.5)
                    .foregroundStyle(DS.ink)
                    .contentTransition(.numericText())
                    .animation(.spring(response: 0.5, dampingFraction: 0.9), value: totalValue)
                HStack(spacing: 10) {
                    ChangePill(value: periodValue, text: pillText)
                    // The all-time figure alongside — hidden on the All range,
                    // where the pill already shows exactly this (no duplicate).
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

    /// The same actions as the sidebar right-click, as a header "⋯" menu — shown
    /// only when viewing a single portfolio.
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

    /// Y domain with a little headroom so the line never touches the card edges.
    private func valueDomain(_ points: [ValuePoint]) -> ClosedRange<Double> {
        let vals = points.map(\.value)
        guard let lo = vals.min(), let hi = vals.max(), hi > lo else { return 0...1 }
        let span = hi - lo
        return (lo - span * 0.10)...(hi + span * 0.14)
    }

    /// X-axis tick label formatted for the selected period.
    private func xAxisLabel(_ date: Date) -> String {
        switch chartRange {
        case .week: return date.formatted(.dateTime.weekday(.abbreviated))
        case .month, .threeMonths, .sixMonths, .ytd: return date.formatted(.dateTime.day().month(.abbreviated))
        case .year, .threeYears, .fiveYears, .all:
            return date.formatted(.dateTime.month(.abbreviated).year(.twoDigits))
        }
    }

    /// Smooth hover crosshair drawn as an overlay (not chart marks).
    @ViewBuilder private func valueCrosshair(_ proxy: ChartProxy, points: [ValuePoint], tint: Color) -> some View {
        GeometryReader { geo in
            if let plotAnchor = proxy.plotFrame {
                let plot = geo[plotAnchor]
                ZStack(alignment: .topLeading) {
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let loc):
                                // Clamp inside the plot so edges still resolve a value.
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

    @ViewBuilder private func heroChart(_ ds: (points: [ValuePoint], isEstimated: Bool)) -> some View {
        let points = ds.points
        if points.count >= 2 {
            // Consistent color across periods: emerald when the period is up,
            // terracotta when down. Estimated state is shown by the dash only.
            let periodUp = (points.last?.value ?? 0) >= (points.first?.value ?? 0)
            let tint = periodUp ? DS.up : DS.down
            Chart {
                ForEach(points) { p in
                    AreaMark(x: .value("Day", p.date), y: .value("Value", p.value))
                        .foregroundStyle(.linearGradient(colors: [tint.opacity(0.22), tint.opacity(0)],
                                                         startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("Day", p.date), y: .value("Value", p.value))
                        .foregroundStyle(tint).lineStyle(.init(lineWidth: 2, dash: ds.isEstimated ? [4, 3] : []))
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
            // Morph marks in place when async data lands (avoids a hard "pop" as
            // intraday/history loads after a range switch).
            .animation(.easeInOut(duration: 0.4), value: points)
            // Range switch replaces the chart; crossfade it rather than cut.
            .id(chartRange)
            .transition(.opacity.animation(.easeInOut(duration: 0.4)))
        } else {
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

    private var portfolioInceptionDate: Date? {
        if let purchaseDate = earliestPurchaseDate {
            return Calendar.current.startOfDay(for: purchaseDate)
        }
        if let snapDate = series.first?.date {
            return Calendar.current.startOfDay(for: snapDate)
        }
        return nil
    }

    private func portfolioPerformance(for period: PerformancePeriod, points: [ValuePoint]) -> Double? {
        guard points.count >= 2, let lastVal = points.last?.value, abs(lastVal) > 1e-9 else { return nil }
        let cutoff = period.cutoffDate()
        let graceCutoff = cutoff.addingTimeInterval(7 * 86400)

        // Only enforce strict inception cutoff for long-term periods (5Y, 10Y) if portfolio inception is known
        if (period == .y5 || period == .y10), let inception = portfolioInceptionDate {
            guard inception <= graceCutoff else { return nil }
        }

        guard let startPoint = points.last(where: { $0.date <= cutoff }) ?? points.first(where: { $0.date <= graceCutoff }), abs(startPoint.value) > 1e-9 else { return nil }
        return ((lastVal - startPoint.value) / abs(startPoint.value)) * 100
    }

    private func spxPerformance(for period: PerformancePeriod) -> Double? {
        let points = stockService.priceHistoryMax["^GSPC"] ?? stockService.priceHistory["^GSPC"] ?? []
        guard points.count >= 2, let lastPrice = points.last?.close, abs(lastPrice) > 1e-9 else { return nil }
        let cutoff = period.cutoffDate()
        let graceCutoff = cutoff.addingTimeInterval(7 * 86400)
        guard let startPoint = points.last(where: { $0.date <= cutoff }) ?? points.first(where: { $0.date <= graceCutoff }), abs(startPoint.close) > 1e-9 else { return nil }
        return ((lastPrice - startPoint.close) / abs(startPoint.close)) * 100
    }

    /// Evaluates benchmark matrix once per app session (not updating real-time).
    private var cachedPerformance: (portfolio: [PerformancePeriod: Double?], spx: [PerformancePeriod: Double?]) {
        let holdingsFingerprint = portfolios.flatMap { $0.holdings }.map { "\($0.symbol):\($0.quantity):\($0.avgPrice):\($0.effectiveLeverage)" }.joined(separator: ";")
        let fullKey = "\(scopeKey):\(holdingsFingerprint)"
        return PerformanceBenchmarkCache.performance(for: fullKey) {
            let hs = portfolios.flatMap { $0.holdings }
            var histBySymbol: [String: [PricePoint]] = [:]
            for h in hs {
                histBySymbol[h.symbol] = stockService.priceHistoryMax[h.symbol] ?? stockService.priceHistory[h.symbol] ?? []
            }
            let maxPoints = valueSeries(from: histBySymbol)
            var pDict: [PerformancePeriod: Double?] = [:]
            var sDict: [PerformancePeriod: Double?] = [:]
            for period in PerformancePeriod.allCases {
                pDict[period] = portfolioPerformance(for: period, points: maxPoints)
                sDict[period] = spxPerformance(for: period)
            }
            return (pDict, sDict)
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

    private var moneyWeightedComparison: InvestmentEffectiveness.Result {
        let hs = portfolios.flatMap { $0.holdings }
        let holdingsFingerprint = hs.map {
            "\($0.symbol):\($0.quantity):\($0.avgPrice):\($0.effectiveLeverage):\($0.purchaseDate?.timeIntervalSince1970 ?? 0)"
        }.joined(separator: ";")
        let fullKey = "\(scopeKey):\(holdingsFingerprint)"
        return MoneyWeightedReturnCache.result(for: fullKey) {
            InvestmentEffectiveness.evaluate(
                holdings: hs,
                stockService: stockService,
                storageService: storageService
            )
        }
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
                                    HStack(spacing: 9) {
                                        RoundedRectangle(cornerRadius: 2.5).fill(color(for: slice.symbol)).frame(width: 9, height: 9)
                                        SymbolLogo(symbol: slice.symbol, size: 20)
                                        let displayName = stockService.quotes[slice.symbol]?.displayName ?? StockService.codeToFundNameMap[slice.symbol] ?? slice.symbol
                                        Text(displayName).font(DS.figure).foregroundStyle(DS.ink).lineLimit(1)
                                        Spacer()
                                        Text(String(format: "%.1f%%", slice.fraction * 100))
                                            .font(DS.figure).foregroundStyle(DS.inkSecondary)
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
        HStack(spacing: 10) {
            SymbolLogo(symbol: h.symbol, size: 24)
            VStack(alignment: .leading, spacing: 1) {
                if isJpFund {
                    Text(h.name).font(DS.figure).foregroundStyle(DS.ink).lineLimit(1)
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

    private var positionsCard: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                SectionLabel("Positions")
                Spacer()
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
                let minTableWidth: CGFloat = storageService.showExtendedHours ? 780 : 680
                let availableWidth = max(positionsCardWidth - (DS.pad * 2), minTableWidth)

                ScrollView(.horizontal, showsIndicators: false) {
                    VStack(spacing: 0) {
                        HStack(spacing: 0) {
                            Text("#").frame(width: PositionColumnWidth.number, alignment: .leading)
                            sortHeader("Symbol", column: .symbol)
                                .frame(minWidth: PositionColumnWidth.symbolMin, idealWidth: 200, maxWidth: .infinity, alignment: .leading)
                            sortHeader("Price", column: .price)
                                .frame(minWidth: PositionColumnWidth.priceMin, idealWidth: 110, maxWidth: 140, alignment: .trailing)
                            if storageService.showExtendedHours {
                                sortHeader("Ext", column: .extended)
                                    .frame(minWidth: PositionColumnWidth.sessionMin, idealWidth: 110, maxWidth: 140, alignment: .trailing)
                                    .help("Sort by the current pre/post-market % move")
                            }
                            sortHeader("Cost", column: .cost)
                                .frame(minWidth: PositionColumnWidth.amountMin, idealWidth: 120, maxWidth: 160, alignment: .trailing)
                            sortHeader("Value", column: .value)
                                .frame(minWidth: PositionColumnWidth.amountMin, idealWidth: 120, maxWidth: 160, alignment: .trailing)
                            sortHeader("P&L", column: .pnl)
                                .frame(minWidth: PositionColumnWidth.amountMin, idealWidth: 120, maxWidth: 160, alignment: .trailing)
                            sortHeader("Weight", column: .weight)
                                .frame(minWidth: PositionColumnWidth.weightMin, idealWidth: 115, maxWidth: 150, alignment: .trailing)
                            Color.clear.frame(width: PositionColumnWidth.chevron)
                        }
                        .font(DS.label)
                        .foregroundStyle(DS.inkTertiary)
                        .tracking(0.8).textCase(.uppercase)
                        .padding(.bottom, 12)
                        Divider().overlay(DS.hairline)

                        let groupedValued = Dictionary(grouping: holdings) { $0.symbol.uppercased() }
                        let sortedSymbols: [String] = {
                            if sortColumn == .manual {
                                return insertionOrderedSymbols.filter { groupedValued[$0] != nil }
                            }
                            return groupedValued.keys.sorted { sym1, sym2 in
                                guard let g1 = groupedValued[sym1], let g2 = groupedValued[sym2] else { return false }
                                let isAsc = sortAscending

                                func compareOptional(_ lhs: Double?, _ rhs: Double?) -> Bool {
                                    switch (lhs, rhs) {
                                    case let (l?, r?): return isAsc ? l < r : l > r
                                    case (_?, nil): return true
                                    case (nil, _?): return false
                                    case (nil, nil): return isAsc ? sym1 < sym2 : sym1 > sym2
                                    }
                                }

                                switch sortColumn {
                                case .manual:
                                    return false
                                case .symbol:
                                    return isAsc ? sym1 < sym2 : sym1 > sym2
                                case .price:
                                    let p1 = g1.first?.quote.changePercent ?? 0
                                    let p2 = g2.first?.quote.changePercent ?? 0
                                    return isAsc ? p1 < p2 : p1 > p2
                                case .extended:
                                    return compareOptional(g1.first?.quote.extendedChangePercent,
                                                           g2.first?.quote.extendedChangePercent)
                                case .cost:
                                    let c1 = g1.reduce(0) { $0 + $1.cost }
                                    let c2 = g2.reduce(0) { $0 + $1.cost }
                                    return isAsc ? c1 < c2 : c1 > c2
                                case .value, .weight:
                                    let v1 = g1.reduce(0) { $0 + $1.value }
                                    let v2 = g2.reduce(0) { $0 + $1.value }
                                    return isAsc ? v1 < v2 : v1 > v2
                                case .pnl:
                                    let pnl1 = g1.reduce(0) { $0 + ($1.value - $1.cost) }
                                    let pnl2 = g2.reduce(0) { $0 + ($1.value - $1.cost) }
                                    return isAsc ? pnl1 < pnl2 : pnl1 > pnl2
                                }
                            }
                        }()

                        ForEach(Array(sortedSymbols.enumerated()), id: \.element) { index, sym in
                            if let group = groupedValued[sym], let first = group.first {
                                let groupVal = group.reduce(0) { $0 + $1.value }
                                let weight = abs(totalValue) >= 0.01 ? abs(groupVal) / abs(totalValue) * 100 : 0

                                NavigationLink(value: first.id) {
                                    PositionSummaryRow(position: index + 1,
                                                       symbol: sym,
                                                       holdings: group,
                                                       currencySymbol: currencySymbol,
                                                       weight: weight,
                                                       topWeight: topWeight,
                                                       decimals: decimals,
                                                       valueDecimals: storageService.valueDecimals,
                                                       showExtendedHours: storageService.showExtendedHours)
                                }
                                .buttonStyle(.plain)
                                .help("View \(sym) details")
                                .contextMenu {
                                    let isPortReadOnly = storageService.portfolios.first(where: { $0.id == first.portfolioId })?.isReadOnly ?? false
                                    if group.count == 1 && !isPortReadOnly {
                                        Button { editHoldingAction.perform(first.portfolioId, first.holding) } label: { Label("Edit", systemImage: "pencil") }
                                        Button(role: .destructive) {
                                            storageService.removeHolding(from: first.portfolioId, holdingId: first.holding.id)
                                        } label: { Label("Delete", systemImage: "trash") }
                                    }
                                }
                                if index < sortedSymbols.count - 1 {
                                    Divider().overlay(DS.hairline.opacity(0.6)).padding(.horizontal, 8)
                                }
                            }
                        }
                    }
                    .frame(width: max(availableWidth, minTableWidth))
                }
                .navigationDestination(for: UUID.self) { id in
                    if let h = holdings.first(where: { $0.id == id }) {
                        HoldingDetailView(portfolioId: h.portfolioId, scope: scope,
                                          holding: h.holding, quote: h.quote)
                    }
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

    /// Visible "+ Add holding" affordance. Adds directly to the focused portfolio;
    /// on "All Portfolios" it picks the one portfolio, or offers a menu to choose.
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

private struct CardWidthPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let next = nextValue()
        if next > 0 { value = next }
    }
}

private enum PositionColumnWidth {
    static let number: CGFloat = 24
    static let symbolMin: CGFloat = 120
    static let priceMin: CGFloat = 90
    static let sessionMin: CGFloat = 90
    static let amountMin: CGFloat = 95
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

    @State private var hovered = false

    private var first: ValuedHolding? { holdings.first }

    private var liveQuote: StockQuote? {
        stockService.quotes[symbol] ?? stockService.quotes[symbol.uppercased()] ?? first?.quote
    }

    private var nativeCurrencySymbol: String {
        let curr = stockService.detectedCurrency(for: symbol)
        return StorageService.currencySymbol(for: curr)
    }

    private var totalNativeCost: Double {
        holdings.reduce(0) { $0 + $1.holding.costBasisLocal }
    }

    private var totalNativeValue: Double {
        holdings.reduce(0) { sum, h in
            let q = stockService.quotes[h.holding.symbol] ?? stockService.quotes[h.holding.symbol.uppercased()] ?? h.quote
            let price = q.price > 0 ? q.price : h.holding.avgPrice
            return sum + h.holding.marketValue(currentPrice: price)
        }
    }

    private var totalNativePnl: Double {
        holdings.reduce(0) { sum, h in
            let q = stockService.quotes[h.holding.symbol] ?? stockService.quotes[h.holding.symbol.uppercased()] ?? h.quote
            let price = q.price > 0 ? q.price : h.holding.avgPrice
            return sum + h.holding.pnl(currentPrice: price)
        }
    }

    private var totalNativePnlPercent: Double {
        abs(totalNativeCost) >= 0.01 ? (totalNativePnl / abs(totalNativeCost)) * 100 : 0
    }

    private var amountDec: Int { valueDecimals >= 0 ? valueDecimals : 2 }

    private func priceDec(_ price: Double) -> Int {
        valueDecimals >= 0 ? valueDecimals : StorageService.priceDecimals(symbol: symbol, price: price)
    }

    @ViewBuilder
    private func priceCell(
        price: Double?,
        percent: Double?,
        sessionLabel: String? = nil,
        emphasised: Bool = true
    ) -> some View {
        if let price {
            let quoteCurr = liveQuote?.currency ?? ""
            let sym = quoteCurr.isEmpty ? nativeCurrencySymbol : StorageService.currencySymbol(for: quoteCurr)
            VStack(alignment: .trailing, spacing: 2) {
                Text(StorageService.formatAmount(price, symbol: sym, decimals: priceDec(price)))
                    .font(DS.figure)
                    .foregroundStyle(emphasised ? DS.ink : DS.inkTertiary)
                    .contentTransition(.numericText())
                if let percent {
                    HStack(spacing: 4) {
                        if let sessionLabel, !sessionLabel.isEmpty {
                            Text(sessionLabel)
                                .font(DS.micro)
                                .foregroundStyle(DS.inkTertiary)
                        }
                        if emphasised {
                            ChangePill(
                                value: percent,
                                text: String(format: "%+.\(decimals)f%%", percent)
                            )
                        } else {
                            Text(String(format: "%+.\(decimals)f%%", percent))
                                .font(DS.micro)
                                .foregroundStyle(DS.pnlColor(percent).opacity(0.55))
                        }
                    }
                }
            }
        } else {
            Text("—")
                .font(DS.figure)
                .foregroundStyle(DS.inkTertiary)
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            Text("\(position)")
                .font(DS.micro.monospacedDigit())
                .foregroundStyle(DS.inkTertiary)
                .frame(width: PositionColumnWidth.number, alignment: .leading)

            // Symbol column
            let isJpFund = (liveQuote?.isJapaneseFund ?? false) || stockService.isJapaneseMutualFund(symbol)
            let titleText = isJpFund ? (liveQuote?.displayName ?? symbol) : symbol
            let subTitleText = isJpFund ? "" : (liveQuote?.name ?? "")

            HStack(spacing: 9) {
                SymbolLogo(symbol: symbol, size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(titleText)
                            .font(DS.figure)
                            .foregroundStyle(DS.ink)
                            .lineLimit(1)
                        if holdings.count > 1 {
                            Text("\(holdings.count) lots")
                                .font(.inter(8, weight: .semibold, relativeTo: .caption2))
                                .foregroundStyle(DS.brand)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(RoundedRectangle(cornerRadius: 3).fill(DS.brand.opacity(0.12)))
                        } else if first?.holding.isShort == true {
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
            .frame(minWidth: PositionColumnWidth.symbolMin, idealWidth: 200, maxWidth: .infinity, alignment: .leading)

            // Regular price and today's regular-session change.
            let isExtendedSession = showExtendedHours && (liveQuote?.isExtendedHours ?? false)
            priceCell(
                price: liveQuote?.price,
                percent: liveQuote?.changePercent,
                emphasised: !isExtendedSession
            )
            .frame(minWidth: PositionColumnWidth.priceMin, idealWidth: 110, maxWidth: 140, alignment: .trailing)

            // Current extended session: pre-market or after-hours.
            if showExtendedHours {
                let extQuote = liveQuote
                let extPrice = extQuote.flatMap { $0.isExtendedHours ? $0.effectivePrice : nil }
                priceCell(price: extPrice,
                          percent: extPrice == nil ? nil : extQuote?.extendedChangePercent,
                          sessionLabel: extPrice == nil ? nil : extQuote?.marketStateLabel,
                          emphasised: extPrice != nil)
                    .frame(minWidth: PositionColumnWidth.sessionMin, idealWidth: 110, maxWidth: 140, alignment: .trailing)
            }

            // Cost basis column (Native Currency)
            Text(StorageService.formatAmount(totalNativeCost, symbol: nativeCurrencySymbol, decimals: amountDec))
                .frame(minWidth: PositionColumnWidth.amountMin, idealWidth: 120, maxWidth: 160, alignment: .trailing)
                .font(DS.figure).foregroundStyle(DS.ink)
                .contentTransition(.numericText())

            // Market Value column (Native Currency)
            Text(StorageService.formatAmount(totalNativeValue, symbol: nativeCurrencySymbol, decimals: amountDec))
                .frame(minWidth: PositionColumnWidth.amountMin, idealWidth: 120, maxWidth: 160, alignment: .trailing)
                .font(DS.figure).foregroundStyle(DS.ink)
                .contentTransition(.numericText())

            // P&L column (Native Currency)
            VStack(alignment: .trailing, spacing: 1) {
                Text(StorageService.formatAmount(totalNativePnl, symbol: nativeCurrencySymbol, decimals: amountDec, signed: true))
                    .font(DS.figure)
                    .contentTransition(.numericText())
                Text(String(format: "%+.\(decimals)f%%", totalNativePnlPercent))
                    .font(DS.micro)
            }
            .foregroundStyle(DS.pnlColor(totalNativePnl))
            .frame(minWidth: PositionColumnWidth.amountMin, idealWidth: 120, maxWidth: 160, alignment: .trailing)

            // Weight column
            HStack(spacing: 7) {
                ZStack(alignment: .leading) {
                    Capsule().fill(DS.cardAlt).frame(width: 56, height: 3)
                    Capsule().fill(DS.brand.opacity(0.5))
                        .frame(width: max(2, 56 * weight / max(topWeight, 0.01)), height: 3)
                }
                Text(String(format: "%.1f%%", weight))
                    .font(.inter(11, relativeTo: .caption).monospacedDigit())
                    .foregroundStyle(DS.inkSecondary)
            }
            .frame(minWidth: PositionColumnWidth.weightMin, idealWidth: 115, maxWidth: 150, alignment: .trailing)

            // Chevron
            Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                .foregroundStyle(hovered ? DS.brand : DS.inkTertiary)
                .frame(width: PositionColumnWidth.chevron)
        }
        .padding(.vertical, 11).padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovered ? DS.cardAlt : .clear))
        .animation(.easeOut(duration: 0.15), value: hovered)
        .contentShape(Rectangle())
        .onHover { inside in
            hovered = inside
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}
