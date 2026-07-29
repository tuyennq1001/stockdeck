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
    @State private var sortColumn: PositionSortColumn = .manual
    @State private var sortAscending: Bool = false
    @State private var chartRange: ChartRange = .all
    @State private var hoveredSlice: String?
    @State private var hoverPoint: ValuePoint?

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

    private var holdings: [ValuedHolding] {
        portfolios.flatMap { portfolio in
            portfolio.holdings.compactMap { holding -> ValuedHolding? in
                let quote = stockService.quotes[holding.symbol] ?? StockQuote(
                    symbol: holding.symbol,
                    name: holding.symbol,
                    price: holding.avgPrice,
                    change: 0,
                    changePercent: 0,
                    currency: stockService.detectedCurrency(for: holding.symbol)
                )
                let price = quote.displayPrice(extendedHours: storageService.showExtendedHours)
                let value = holding.marketValue(currentPrice: price) * stockService.rate(from: quote.currency)
                let cost = holding.costBasisLocal * stockService.rate(from: quote.currency, for: holding.purchaseDate)
                return ValuedHolding(id: holding.id, portfolioId: portfolio.id, holding: holding, quote: quote,
                                     value: value, cost: cost, dayChangePercent: quote.changePercent,
                                     type: storageService.type(for: holding.symbol))
            }
        }
        .sorted { abs($0.value) > abs($1.value) }
    }

    private var totalValue: Double { holdings.reduce(0) { $0 + $1.value } }
    private var totalCost: Double { holdings.reduce(0) { $0 + $1.cost } }
    private var totalPnl: Double { totalValue - totalCost }
    private var totalPnlPercent: Double { abs(totalCost) >= 0.01 ? (totalPnl / abs(totalCost)) * 100 : 0 }

    private var todayPerformance: (gain: Double, percent: Double) {
        let inputs = portfolios.flatMap(\.holdings).compactMap { holding -> TodayPerformance.Input? in
            guard let quote = stockService.quotes[holding.symbol] else { return nil }
            return TodayPerformance.Input(
                holding: holding,
                regularPrice: quote.price,
                previousClose: quote.previousClose,
                rate: stockService.rate(from: quote.currency)
            )
        }
        return TodayPerformance.totals(inputs)
    }
    private var dayChangeValue: Double { todayPerformance.gain }
    private var dayChangePercent: Double { todayPerformance.percent }

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
        for log in logs { for snap in log {
            byDay[snap.date, default: (0, 0)].value += snap.totalValue
            byDay[snap.date, default: (0, 0)].cost += snap.totalCost
        } }
        return byDay.map { PortfolioSnapshot(date: $0.key, totalValue: $0.value.value, totalCost: $0.value.cost) }
            .sorted { $0.date < $1.date }
    }

    private var filteredSeries: [PortfolioSnapshot] {
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
    }

    /// Builds an estimated value curve from a given per-symbol price history
    /// (daily / hourly / 5-min) × current positions, in the preferred currency.
    private func valueSeries(from histBySymbol: [String: [PricePoint]]) -> [ValuePoint] {
        let hs = portfolios.flatMap { $0.holdings }
        var rate: [String: Double] = [:]
        var hist: [String: [PricePoint]] = [:]
        for h in hs {
            if let q = stockService.quotes[h.symbol] { rate[h.symbol] = stockService.rate(from: q.currency) }
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

    /// The curve actually drawn. 1M+ prefer real snapshots once
    /// they're as dense as the daily estimate. `isEstimated` drives the badge.
    private var displaySeries: (points: [ValuePoint], isEstimated: Bool) {
        if chartRange == .week {
            return (valueSeries(from: stockService.intradayWeek), true)
        } else {
            let real = filteredSeries.map { ValuePoint(date: $0.date, value: $0.totalValue) }
            let est = estimatedFiltered
            if real.count >= 2 && real.count >= est.count { return (real, false) }
            if est.count >= 2 { return (est, true) }
            return (real, false)
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
            portfolioMenu
        }) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: DS.gap) {
                        heroCard
                        statRow
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
        let ds = displaySeries
        // Pill reflects the SELECTED range: change across the drawn curve. When
        // the curve is too sparse to span a period (e.g. day one), fall back to
        // the day-over-day figure so the pill is never empty.
        let useRealAllTime = chartRange == .all
        let periodValue = useRealAllTime ? totalPnl
            : (PortfolioPeriodChange.value(ds.points) ?? dayChangeValue)
        let periodPercent = useRealAllTime ? totalPnlPercent
            : (PortfolioPeriodChange.percent(ds.points) ?? dayChangePercent)
        let periodLabel = useRealAllTime ? "all-time"
            : (PortfolioPeriodChange.percent(ds.points) != nil ? chartRange.changeLabel : "today")
        
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
            DSMenu(sections: [
                [ DSMenuAction(title: "Add Holding…", icon: "plus") { portfolioActions.addHolding(id) },
                  DSMenuAction(title: "Rename…", icon: "pencil") { portfolioActions.rename(id, p.name) },
                  DSMenuAction(title: "Notifications…", icon: "bell") { portfolioActions.notifications(id, p.name) } ],
                [ DSMenuAction(title: "Delete Portfolio", icon: "trash", destructive: true) { portfolioActions.delete(id) } ],
            ]) {
                Image(systemName: "ellipsis")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(DS.inkSecondary)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(DS.cardAlt))
            }
            .help("Portfolio actions — add holding, rename, notifications, delete")
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

                        VStack(alignment: .leading, spacing: 9) {
                            ForEach(allocation.prefix(6)) { slice in
                                HStack(spacing: 9) {
                                    RoundedRectangle(cornerRadius: 2.5).fill(color(for: slice.symbol)).frame(width: 9, height: 9)
                                    SymbolLogo(symbol: slice.symbol, size: 20)
                                    Text(slice.symbol).font(DS.figure).foregroundStyle(DS.ink)
                                    Spacer()
                                    Text(String(format: "%.1f%%", slice.fraction * 100))
                                        .font(DS.figure).foregroundStyle(DS.inkSecondary)
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
        HStack(spacing: 10) {
            SymbolLogo(symbol: h.symbol, size: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(h.symbol).font(DS.figure).foregroundStyle(DS.ink)
                Text(h.name).font(DS.micro).foregroundStyle(DS.inkTertiary).lineLimit(1)
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
                ScrollView(.horizontal, showsIndicators: false) {
                    VStack(spacing: 0) {
                        HStack(spacing: 0) {
                            Text("#").frame(width: PositionColumnWidth.number, alignment: .leading)
                            sortHeader("Symbol", column: .symbol)
                                .frame(minWidth: 140, maxWidth: .infinity, alignment: .leading)
                            sortHeader("Price", column: .price)
                                .frame(width: PositionColumnWidth.price, alignment: .trailing)
                            if storageService.showExtendedHours {
                                sortHeader("Ext", column: .extended)
                                    .frame(width: PositionColumnWidth.session, alignment: .trailing)
                                    .help("Sort by the current pre/post-market % move")
                            }
                            sortHeader("Cost", column: .cost)
                                .frame(width: PositionColumnWidth.amount, alignment: .trailing)
                            sortHeader("Value", column: .value)
                                .frame(width: PositionColumnWidth.amount, alignment: .trailing)
                            sortHeader("P&L", column: .pnl)
                                .frame(width: PositionColumnWidth.amount, alignment: .trailing)
                            sortHeader("Weight", column: .weight)
                                .frame(width: PositionColumnWidth.weight, alignment: .trailing)
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
                                    if group.count == 1 {
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
                    .frame(maxWidth: .infinity)
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
        .premiumCard()
    }

    /// Visible "+ Add holding" affordance. Adds directly to the focused portfolio;
    /// on "All Portfolios" it picks the one portfolio, or offers a menu to choose.
    @ViewBuilder private var addHoldingButton: some View {
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
            if storageService.portfolios.count == 1, let id = storageService.portfolios.first?.id {
                Button { addHoldingAction.perform(id) } label: { label }.buttonStyle(.plain)
                    .pointingHandCursor()
                    .help("Add a holding")
            } else if !storageService.portfolios.isEmpty {
                Menu {
                    ForEach(storageService.portfolios) { p in
                        Button(p.name) { addHoldingAction.perform(p.id) }
                    }
                } label: { label }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .pointingHandCursor()
                .help("Add a holding — choose which portfolio")
            }
        }
    }

    private var emptyLine: some View {
        Text("No holdings yet").font(DS.caption).foregroundStyle(DS.inkSecondary)
            .frame(maxWidth: .infinity, alignment: .center).padding(.vertical, 12)
    }
}

// MARK: - Position summary row

private enum PositionColumnWidth {
    static let number: CGFloat = 24
    static let price: CGFloat = 105
    static let session: CGFloat = 105
    static let amount: CGFloat = 115
    static let weight: CGFloat = 105
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

    private var totalCost: Double {
        holdings.reduce(0) { $0 + $1.cost }
    }

    private var totalValue: Double {
        holdings.reduce(0) { $0 + $1.value }
    }

    private var totalPnl: Double {
        totalValue - totalCost
    }

    private var totalPnlPercent: Double {
        abs(totalCost) >= 0.01 ? (totalPnl / abs(totalCost)) * 100 : 0
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
            let quoteCurr = first?.quote.currency ?? ""
            let sym = quoteCurr.isEmpty ? currencySymbol : StorageService.currencySymbol(for: quoteCurr)
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
            let isJpFund = (first?.quote.isJapaneseFund ?? false) || stockService.isJapaneseMutualFund(symbol)
            let titleText = isJpFund ? (first?.quote.displayName ?? symbol) : symbol
            let subTitleText = isJpFund ? "" : (first?.name ?? "")

            HStack(spacing: 9) {
                SymbolLogo(symbol: symbol, size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(titleText).font(DS.figure).foregroundStyle(DS.ink).lineLimit(1)
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
                        Text(subTitleText).font(DS.micro).foregroundStyle(DS.inkTertiary).lineLimit(1)
                    }
                }
            }
            .frame(minWidth: 140, maxWidth: .infinity, alignment: .leading)

            // Regular price and today's regular-session change.
            let isExtendedSession = showExtendedHours && (first?.quote.isExtendedHours ?? false)
            priceCell(
                price: first?.quote.price,
                percent: first?.quote.changePercent,
                emphasised: !isExtendedSession
            )
                .frame(width: PositionColumnWidth.price, alignment: .trailing)

            // Current extended session: pre-market or after-hours.
            if showExtendedHours {
                let extQuote = first?.quote
                let extPrice = extQuote.flatMap { $0.isExtendedHours ? $0.effectivePrice : nil }
                priceCell(price: extPrice,
                          percent: extPrice == nil ? nil : extQuote?.extendedChangePercent,
                          sessionLabel: extPrice == nil ? nil : extQuote?.marketStateLabel,
                          emphasised: extPrice != nil)
                    .frame(width: PositionColumnWidth.session, alignment: .trailing)
            }

            // Cost basis column
            Text(StorageService.formatAmount(totalCost, symbol: currencySymbol, decimals: amountDec))
                .frame(width: PositionColumnWidth.amount, alignment: .trailing)
                .font(DS.figure).foregroundStyle(DS.ink)
                .contentTransition(.numericText())

            // Market Value column
            Text(StorageService.formatAmount(totalValue, symbol: currencySymbol, decimals: amountDec))
                .frame(width: PositionColumnWidth.amount, alignment: .trailing)
                .font(DS.figure).foregroundStyle(DS.ink)
                .contentTransition(.numericText())

            // P&L column
            VStack(alignment: .trailing, spacing: 1) {
                Text(StorageService.formatAmount(totalPnl, symbol: currencySymbol, decimals: amountDec, signed: true))
                    .font(DS.figure)
                    .contentTransition(.numericText())
                Text(String(format: "%+.\(decimals)f%%", totalPnlPercent))
                    .font(DS.micro)
            }
            .foregroundStyle(DS.pnlColor(totalPnl))
            .frame(width: PositionColumnWidth.amount, alignment: .trailing)

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
            .frame(width: PositionColumnWidth.weight, alignment: .trailing)

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
