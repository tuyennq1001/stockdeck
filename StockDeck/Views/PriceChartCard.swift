import SwiftUI
import Charts

/// The real price-history card: live price + range picker + one year of Yahoo
/// daily closes. Shared by the holding detail page and the watchlist symbol
/// sheet, so every chart in the app looks and behaves the same.
struct PriceChartCard: View {
    @EnvironmentObject var stockService: StockService
    @EnvironmentObject var storageService: StorageService
    let symbol: String
    let quote: StockQuote
    var chartHeight: CGFloat = 280
    var tradingViewHeight: CGFloat = 500
    var showStylePicker: Bool = true

    enum ChartRange: String, CaseIterable {
        case week = "7D", month = "1M", threeMonths = "3M", sixMonths = "6M", ytd = "YTD", year = "1Y", threeYears = "3Y", fiveYears = "5Y", all = "All"
        /// Lookback window in days; nil = the whole fetched history.
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
                let days = cal.dateComponents([.day], from: jan1, to: now).day ?? 30
                return max(days, 1)
            case .year: return 365
            case .threeYears: return 365 * 3
            case .fiveYears: return 365 * 5
            case .all: return nil
            }
        }

        /// Calendar-accurate period start date matching Watchlist and Portfolio benchmark metrics.
        func startDate(from now: Date = Date(), calendar: Calendar = .current) -> Date? {
            switch self {
            case .week:
                return calendar.date(byAdding: .day, value: -7, to: now)
            case .month:
                return calendar.date(byAdding: .month, value: -1, to: now)
            case .threeMonths:
                return calendar.date(byAdding: .month, value: -3, to: now)
            case .sixMonths:
                return calendar.date(byAdding: .month, value: -6, to: now)
            case .ytd:
                return calendar.date(from: calendar.dateComponents([.year], from: now))
            case .year:
                return calendar.date(byAdding: .year, value: -1, to: now)
            case .threeYears:
                return calendar.date(byAdding: .year, value: -3, to: now)
            case .fiveYears:
                return calendar.date(byAdding: .year, value: -5, to: now)
            case .all:
                return nil
            }
        }
        /// Daily closes for all ranges.
        var isIntraday: Bool { false }

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

    enum ChartStyle: String, CaseIterable {
        case line
        case tradingview
    }

    @State private var chartRange: ChartRange = .month
    @State private var chartStyle: ChartStyle = .line
    @State private var hoverPoint: PricePoint?
    @State private var cachedGroupedTrades: [GroupedInsiderTrade] = []
    @ObservedObject private var insiderService = InsiderTradingService.shared
    @Environment(\.colorScheme) private var colorScheme

    private var isEligibleForInsider: Bool {
        insiderService.isEligibleUSSymbol(symbol)
    }

    private var cleanSym: String {
        symbol.uppercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ".US", with: "")
    }

    private var effectiveChartStyle: ChartStyle {
        showStylePicker ? chartStyle : .line
    }

    private var resolvedChartHeight: CGFloat {
        effectiveChartStyle == .tradingview && tradingViewSymbol != nil ? tradingViewHeight : chartHeight
    }

    /// The TradingView widget symbol for the current stock, or nil when the
    /// symbol has no reliable TradingView listing (e.g. Japanese mutual funds),
    /// in which case the TradingView style is disabled.
    private var tradingViewSymbol: String? {
        TradingViewSymbol.map(symbol, exchange: storageService.exchange(for: symbol))
    }

    private var priceSymbol: String {
        let isIndex = StorageService.isIndex(symbol: quote.symbol, type: storageService.type(for: quote.symbol))
        return isIndex ? "" : StorageService.currencySymbol(for: quote.currency)
    }

    private var displayedPriceInfo: (price: Double, diff: Double, diffPct: Double, label: String) {
        let basePrice = quote.displayPrice(extendedHours: storageService.showExtendedHours)
        guard history.count >= 2, let firstPrice = history.first?.close, firstPrice > 0 else {
            return (basePrice, quote.change, quote.changePercent, chartRange.changeLabel)
        }

        let lastPrice = basePrice > 0 ? basePrice : (history.last?.close ?? basePrice)
        let diff = lastPrice - firstPrice
        let diffPct = (diff / firstPrice) * 100
        return (lastPrice, diff, diffPct, chartRange.changeLabel)
    }

    private func hoverLabel(_ date: Date) -> String {
        chartRange.isIntraday ? date.formatted(.dateTime.hour().minute())
                              : date.formatted(date: .abbreviated, time: .omitted)
    }

    /// X-axis tick label, formatted for the selected period.
    private func xAxisLabel(_ date: Date) -> String {
        switch chartRange {
        case .week: return date.formatted(.dateTime.weekday(.abbreviated))
        case .month, .threeMonths, .sixMonths, .ytd: return date.formatted(.dateTime.day().month(.abbreviated))
        case .year, .threeYears, .fiveYears:
            return date.formatted(.dateTime.month(.abbreviated).year(.twoDigits))
        case .all:
            return date.formatted(.dateTime.year())
        }
    }

    // MARK: - Insider Trades Data

    struct GroupedInsiderTrade: Identifiable {
        let id: String
        let date: Date
        let price: Double
        let isBuy: Bool
        let trades: [InsiderTransaction]

        var totalShares: Double { trades.reduce(0) { $0 + $1.shares } }
        var totalValue: Double { trades.reduce(0) { $0 + $1.totalValue } }
        var count: Int { trades.count }
        var primaryOwner: String { trades.first?.ownerName ?? "Insider" }
        var primaryRole: String { trades.first?.displayRole ?? "Insider" }
    }

    private func updateCachedInsiderTrades() {
        guard storageService.showInsiderMarkers, isEligibleForInsider else {
            if !cachedGroupedTrades.isEmpty { cachedGroupedTrades = [] }
            return
        }
        cachedGroupedTrades = computeGroupedTrades()
    }

    private func computeGroupedTrades() -> [GroupedInsiderTrade] {
        guard let firstDate = history.first?.date, let lastDate = history.last?.date else { return [] }
        let minDate = min(firstDate, lastDate)
        let maxDate = max(firstDate, lastDate)
        let raw = insiderService.getTransactions(for: cleanSym, startDate: minDate, endDate: maxDate, openMarketOnly: true)
        let trades = raw.filter { $0.price > 0 && $0.shares > 0 }
        guard !trades.isEmpty else { return [] }

        var groups: [String: [InsiderTransaction]] = [:]
        let cal = Calendar.current
        let df = DateFormatter.secDate

        for trade in trades {
            let key: String
            switch chartRange {
            case .week, .month, .threeMonths:
                // Daily granularity
                key = "\(df.string(from: trade.transactionDate))_\(trade.isBuy)"
            case .sixMonths, .ytd, .year:
                // Weekly granularity
                if let weekStart = cal.dateInterval(of: .weekOfYear, for: trade.transactionDate)?.start {
                    key = "W_\(df.string(from: weekStart))_\(trade.isBuy)"
                } else {
                    key = "\(df.string(from: trade.transactionDate))_\(trade.isBuy)"
                }
            case .threeYears, .fiveYears, .all:
                // Monthly granularity
                if let monthStart = cal.dateInterval(of: .month, for: trade.transactionDate)?.start {
                    key = "M_\(df.string(from: monthStart))_\(trade.isBuy)"
                } else {
                    key = "\(df.string(from: trade.transactionDate))_\(trade.isBuy)"
                }
            }
            groups[key, default: []].append(trade)
        }

        return groups.compactMap { (key, groupTrades) -> GroupedInsiderTrade? in
            guard let first = groupTrades.first else { return nil }
            let totalShares = groupTrades.reduce(0.0) { $0 + $1.shares }
            let weightedPrice = totalShares > 0 ? (groupTrades.reduce(0.0) { $0 + $1.price * $1.shares } / totalShares) : first.price
            let fallbackPrice = nearestClose(for: first.transactionDate) ?? (history.last?.close ?? 0)
            let finalPrice = weightedPrice > 0 ? weightedPrice : fallbackPrice
            guard finalPrice > 0 else { return nil }
            return GroupedInsiderTrade(
                id: key,
                date: first.transactionDate,
                price: finalPrice,
                isBuy: first.isBuy,
                trades: groupTrades
            )
        }.sorted { $0.date < $1.date }
    }

    private func nearestClose(for date: Date) -> Double? {
        history.min(by: { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) })?.close
    }

    /// Smooth hover crosshair drawn as an overlay (not chart marks), so moving the
    /// mouse doesn't re-render the whole chart. Vertical rule + dot + tooltip.
    @ViewBuilder private func chartCrosshair(_ proxy: ChartProxy, tint: Color) -> some View {
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
                                    hoverPoint = history.min(by: { abs($0.date.timeIntervalSince(d)) < abs($1.date.timeIntervalSince(d)) })
                                }
                            case .ended:
                                hoverPoint = nil
                            }
                        }
                    if let h = hoverPoint,
                       let px = proxy.position(forX: h.date),
                       let py = proxy.position(forY: h.close) {
                        let cx = plot.minX + px
                        let dec = storageService.resolvedPriceDecimals(symbol: symbol, price: h.close)
                        let matchedInsider = cachedGroupedTrades.first(where: {
                            let diff = abs($0.date.timeIntervalSince(h.date))
                            switch chartRange {
                            case .week, .month, .threeMonths:
                                return Calendar.current.isDate($0.date, inSameDayAs: h.date)
                            case .sixMonths, .ytd, .year:
                                return diff < 86400 * 4
                            case .threeYears, .fiveYears, .all:
                                return diff < 86400 * 16
                            }
                        })
                        Group {
                            Path { p in p.move(to: CGPoint(x: cx, y: plot.minY)); p.addLine(to: CGPoint(x: cx, y: plot.maxY)) }
                                .stroke(DS.inkTertiary.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                            Circle().fill(tint).frame(width: 9, height: 9)
                                .overlay(Circle().strokeBorder(.white, lineWidth: 1.5))
                                .position(x: cx, y: plot.minY + py)

                            ChartTooltipWithInsider(title: hoverLabel(h.date),
                                                    value: "\(priceSymbol)\(StorageService.formatNumber(h.close, decimals: dec))",
                                                    tint: tint,
                                                    insiderTrade: matchedInsider)
                                .position(x: min(max(cx, plot.minX + 60), plot.maxX - 60), y: plot.minY + (matchedInsider != nil ? 20 : 12))
                        }
                        .allowsHitTesting(false)
                    }
                }
            }
        }
    }

    private var history: [PricePoint] {
        if chartRange.isIntraday {
            return stockService.intradayHistory[symbol] ?? []
        }
        
        let daily = stockService.priceHistory[symbol] ?? []
        let maxPoints = stockService.priceHistoryMax[symbol] ?? []
        
        if chartRange == .all {
            if !maxPoints.isEmpty {
                // If maxPoints spans further back than daily, or daily is missing, prefer full history
                if let maxEarliest = maxPoints.first?.date,
                   let dailyEarliest = daily.first?.date {
                    if maxEarliest < dailyEarliest {
                        return maxPoints
                    }
                } else if daily.isEmpty {
                    return maxPoints
                }
            }
            return daily
        }
        
        guard let cutoff = chartRange.startDate() else {
            return daily
        }
        
        // Helper to filter series and include baseline point immediately before cutoff
        func prepareSeries(_ source: [PricePoint]) -> [PricePoint] {
            guard !source.isEmpty else { return [] }
            var filtered = source.filter { $0.date >= cutoff }
            if let before = source.last(where: { $0.date < cutoff }) {
                filtered.insert(before, at: 0)
            }
            return filtered
        }
        
        let filteredDaily = prepareSeries(daily)
        
        // If daily data goes back to cutoff (or earlier via baseline)
        if let dailyFirst = daily.first?.date, dailyFirst <= cutoff {
            return filteredDaily
        }
        
        // If daily doesn't reach back to cutoff, but maxPoints has older data that extends further
        if !maxPoints.isEmpty {
            let filteredMax = prepareSeries(maxPoints)
            if let maxFirst = filteredMax.first?.date,
               let dailyFirst = filteredDaily.first?.date,
               maxFirst < dailyFirst {
                return filteredMax
            }
        }
        
        return filteredDaily
    }

    private var isLoadingCurrent: Bool {
        switch chartRange {
        case .all:
            return stockService.priceHistoryMax[symbol] == nil && stockService.priceHistory[symbol] == nil
        case .threeYears, .fiveYears:
            return stockService.priceHistory[symbol] == nil && stockService.priceHistoryMax[symbol] == nil
        default:
            return stockService.priceHistory[symbol] == nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Row 1: Last Price & Change Pill (left) + style picker (right), so
            // the chart below gets the full card width and a taller frame.
            let info = displayedPriceInfo
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    SectionLabel("Last price")
                    let dec = storageService.resolvedPriceDecimals(symbol: symbol, price: info.price)
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(StorageService.formatAmount(info.price, symbol: priceSymbol, decimals: dec))
                            .font(.inter(24, weight: .bold, relativeTo: .title).monospacedDigit())
                            .tracking(-0.4)
                            .foregroundStyle(DS.ink)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .contentTransition(.numericText())
                            .animation(.spring(response: 0.5, dampingFraction: 0.9), value: info.price)

                        HStack(spacing: 6) {
                            ChangePill(value: info.diff,
                                       text: String(format: "%+.\(storageService.percentDecimals)f%% \(info.label)", info.diffPct))
                            Text(StorageService.formatAmount(info.diff, symbol: priceSymbol, decimals: dec, signed: true, stripTrailingZeros: true))
                                .font(DS.caption.monospacedDigit())
                                .foregroundStyle(DS.pnlColor(info.diff))
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                    }
                }
                if showStylePicker {
                    Spacer(minLength: 8)
                    stylePicker
                }
            }

            // Row 2: Range Picker (7D, 1M, 3M, 6M, YTD, 1Y, 3Y, 5Y, All) placed above chart
            if effectiveChartStyle == .line || tradingViewSymbol == nil {
                HStack(spacing: 8) {
                    rangePicker

                    if isEligibleForInsider {
                        Spacer()
                        insiderToggleButton
                    }
                }
                .padding(.top, 2)
            }

            // Row 3: Chart.
            chart
                .frame(height: resolvedChartHeight)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .premiumCard()
        .task(id: symbol) {
            await stockService.ensurePriceHistory(for: symbol)
            if isEligibleForInsider {
                await insiderService.ensureTransactions(for: symbol)
            }
            updateCachedInsiderTrades()
        }
        .task(id: "\(symbol)-\(chartRange.rawValue)") {
            if chartRange == .all || chartRange == .fiveYears || chartRange == .threeYears {
                await stockService.ensureFullHistoryMax(for: symbol)
            }
            updateCachedInsiderTrades()
        }
        .onAppear {
            chartStyle = ChartStyle(rawValue: storageService.defaultChartStyle) ?? .line
            if let savedRange = ChartRange(rawValue: storageService.lastStockChartRange) {
                chartRange = savedRange
            }
            updateCachedInsiderTrades()
        }
        .onChange(of: storageService.defaultChartStyle) { _, newValue in
            withAnimation(.easeInOut(duration: 0.2)) {
                chartStyle = ChartStyle(rawValue: newValue) ?? .line
            }
        }
        .onChange(of: chartRange) { _, newRange in
            storageService.lastStockChartRange = newRange.rawValue
            updateCachedInsiderTrades()
        }
        .onChange(of: storageService.showInsiderMarkers) { _, _ in
            updateCachedInsiderTrades()
        }
        .onChange(of: insiderService.transactions[cleanSym]) { _, _ in
            updateCachedInsiderTrades()
        }
        .onChange(of: history.count) { _, _ in
            updateCachedInsiderTrades()
        }
    }

    private var rangePicker: some View {
        SegmentedRangePicker(options: ChartRange.allCases, label: \.rawValue, selection: $chartRange)
    }

    private var insiderToggleButton: some View {
        Button(action: {
            withAnimation(.easeInOut(duration: 0.18)) {
                storageService.showInsiderMarkers.toggle()
            }
        }) {
            HStack(spacing: 4) {
                Image(systemName: storageService.showInsiderMarkers ? "person.badge.shield.checkmark.fill" : "person.badge.shield.checkmark")
                    .font(.system(size: 10, weight: .semibold))
                Text("Insider")
                    .font(.inter(11, weight: .semibold, relativeTo: .caption))
            }
            .foregroundStyle(storageService.showInsiderMarkers ? .white : DS.inkSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(storageService.showInsiderMarkers ? DS.brand : DS.cardAlt)
            )
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .help(storageService.showInsiderMarkers ? "Hide insider trades on chart" : "Show insider trades on chart")
    }

    @ViewBuilder private var stylePicker: some View {
        if tradingViewSymbol != nil {
            HStack(spacing: 4) {
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        chartStyle = .line
                    }
                }) {
                    HStack(spacing: 5) {
                        Image(systemName: "line.uptrend.xyaxis")
                            .font(.system(size: 12, weight: .semibold))
                        Text("Line")
                            .font(.inter(11, weight: .semibold, relativeTo: .caption))
                    }
                    .foregroundStyle(chartStyle == .line ? .white : DS.inkSecondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(chartStyle == .line ? DS.brand : Color.clear))
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                .help("Line chart")

                Button(action: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        chartStyle = .tradingview
                    }
                }) {
                    HStack(spacing: 5) {
                        Text(verbatim: "Trading")
                            .font(.inter(11, weight: .bold, relativeTo: .caption))
                        Text(verbatim: "View")
                            .font(.inter(11, weight: .semibold, relativeTo: .caption))
                    }
                    .foregroundStyle(chartStyle == .tradingview ? .white : DS.inkSecondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(chartStyle == .tradingview ? DS.brand : Color.clear))
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                .help("TradingView chart")
            }
            .padding(3)
            .background(Capsule().fill(DS.cardAlt))
        }
    }

    @ViewBuilder private var chart: some View {
        if effectiveChartStyle == .tradingview, let tvSymbol = tradingViewSymbol {
            TradingViewChartView(tvSymbol: tvSymbol,
                                 theme: colorScheme == .dark ? "dark" : "light",
                                 interval: "D")
                // Force a brand-new web view per symbol so switching stocks
                // can never leave the previous symbol's chart on screen.
                .id(tvSymbol)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .padding(.bottom, 10)
        } else if history.count >= 2 {
            let periodUp = (history.last?.close ?? 0) >= (history.first?.close ?? 0)
            let tint = periodUp ? DS.up : DS.down
            Chart {
                ForEach(history) { point in
                    AreaMark(x: .value("Day", point.date), y: .value("Close", point.close))
                        .foregroundStyle(.linearGradient(colors: [tint.opacity(0.25), tint.opacity(0)],
                                                         startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("Day", point.date), y: .value("Close", point.close))
                        .foregroundStyle(tint).lineStyle(.init(lineWidth: 2))
                        .interpolationMethod(.monotone)
                }
                if let last = history.last {
                    PointMark(x: .value("Day", last.date), y: .value("Close", last.close))
                        .symbolSize(50)
                        .foregroundStyle(tint)
                }
                if storageService.showInsiderMarkers && isEligibleForInsider {
                    ForEach(cachedGroupedTrades) { trade in
                        PointMark(
                            x: .value("Day", trade.date),
                            y: .value("Close", trade.price)
                        )
                        .symbol {
                            ZStack {
                                Circle()
                                    .fill(trade.isBuy ? DS.up : DS.down)
                                    .frame(width: 8, height: 8)
                                Circle()
                                    .strokeBorder(Color.white, lineWidth: 1.5)
                                    .frame(width: 8, height: 8)
                            }
                            .shadow(color: (trade.isBuy ? DS.up : DS.down).opacity(0.6), radius: 2)
                        }
                        .annotation(position: trade.isBuy ? .bottom : .top, spacing: 3) {
                            HStack(spacing: 2) {
                                Image(systemName: trade.isBuy ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                                    .font(.system(size: 7, weight: .bold))
                                Text(trade.isBuy ? "Buy" : "Sell")
                                    .font(.inter(8, weight: .bold, relativeTo: .caption2))
                                if trade.count > 1 {
                                    Text("\(trade.count)x")
                                        .font(.inter(7, weight: .semibold, relativeTo: .caption2))
                                }
                            }
                            .foregroundStyle(trade.isBuy ? DS.up : DS.down)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(
                                Capsule()
                                    .fill(DS.cardAlt.opacity(0.95))
                                    .overlay(Capsule().stroke(DS.hairline, lineWidth: 0.5))
                            )
                        }
                    }
                }
            }
            .chartYScale(domain: chartDomain)
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { v in
                    AxisGridLine().foregroundStyle(DS.hairline)
                    AxisValueLabel {
                        if let d = v.as(Double.self) {
                            Text(StorageService.formatNumber(d, decimals: d >= 100 ? 0 : 2))
                                .font(DS.micro).foregroundStyle(DS.inkTertiary)
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine().foregroundStyle(DS.hairline.opacity(0.5))
                    if let d = value.as(Date.self) {
                        AxisValueLabel { Text(xAxisLabel(d)).font(DS.micro).foregroundStyle(DS.inkTertiary) }
                    }
                }
            }
            .chartOverlay { proxy in chartCrosshair(proxy, tint: tint) }
            .id("\(chartRange.rawValue)-\(chartStyle.rawValue)")
            .transition(.opacity.animation(.easeInOut(duration: 0.28)))
            .padding(.bottom, 8)
        } else {
            ZStack {
                DS.cardAlt
                DecorativeCurve()
                    .stroke(DS.hairline, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    .padding(.horizontal, 24)
                VStack(spacing: 5) {
                    if isLoadingCurrent {
                        ProgressView().scaleEffect(0.6)
                        Text("Loading price history…")
                            .font(.inter(11, weight: .medium, relativeTo: .caption)).foregroundStyle(DS.inkSecondary)
                    } else {
                        Image(systemName: "chart.xyaxis.line").font(.system(size: 20)).foregroundStyle(DS.inkTertiary)
                        Text("No price history available")
                            .font(.inter(11, weight: .medium, relativeTo: .caption)).foregroundStyle(DS.inkSecondary)
                    }
                }
            }
        }
    }

    private var chartDomain: ClosedRange<Double> {
        var mins = history.map(\.effectiveLow)
        var maxs = history.map(\.effectiveHigh)
        if storageService.showInsiderMarkers && isEligibleForInsider {
            for trade in cachedGroupedTrades where trade.price > 0 {
                mins.append(trade.price)
                maxs.append(trade.price)
            }
        }
        guard let min = mins.min(), let max = maxs.max(), max > min else { return 0...1 }
        let pad = (max - min) * 0.08
        return (min - pad)...(max + pad)
    }
}

/// A tiny price line for table rows — rendered using Canvas for near-zero CPU/GPU footprint.
struct Sparkline: View {
    let symbol: String
    var days: Int = 30
    var isYTD: Bool = false
    var width: CGFloat? = 64
    var height: CGFloat? = 22

    private static var pointsCache: [String: (count: Int, lastClose: Double, points: [PricePoint])] = [:]
    private static let cacheLock = NSLock()

    private var points: [PricePoint] {
        let stockService = StockService.shared
        guard let all = stockService.watchlistHistory[symbol] ?? stockService.priceHistoryMax[symbol], !all.isEmpty else { return [] }
        let cacheKey = "\(symbol)-\(days)-\(isYTD)"
        let lastClose = all.last?.close ?? 0
        let count = all.count

        Self.cacheLock.lock()
        if let entry = Self.pointsCache[cacheKey], entry.count == count, entry.lastClose == lastClose {
            Self.cacheLock.unlock()
            return entry.points
        }
        Self.cacheLock.unlock()

        let filtered: [PricePoint]
        if isYTD {
            let cal = Calendar.current
            let now = Date()
            guard let jan1 = cal.date(from: cal.dateComponents([.year], from: now)) else { return [] }
            filtered = all.filter { $0.date >= jan1 }
        } else {
            guard let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) else { return [] }
            filtered = all.filter { $0.date >= cutoff }
        }

        Self.cacheLock.lock()
        Self.pointsCache[cacheKey] = (count: count, lastClose: lastClose, points: filtered)
        Self.cacheLock.unlock()

        return filtered
    }

    var body: some View {
        let pts = points
        Group {
            if pts.count >= 2 {
                let up = (pts.last?.close ?? 0) >= (pts.first?.close ?? 0)
                let tint = up ? DS.up : DS.down

                Canvas { context, size in
                    guard size.width > 0, size.height > 0 else { return }
                    var minVal = Double.greatestFiniteMagnitude
                    var maxVal = -Double.greatestFiniteMagnitude
                    for pt in pts {
                        let c = pt.close
                        if c < minVal { minVal = c }
                        if c > maxVal { maxVal = c }
                    }
                    guard maxVal > minVal else { return }

                    let range = maxVal - minVal
                    let stepX = size.width / CGFloat(pts.count - 1)
                    let padY: CGFloat = 1.5
                    let drawableHeight = max(1.0, size.height - padY * 2)

                    var path = Path()
                    for (i, pt) in pts.enumerated() {
                        let x = CGFloat(i) * stepX
                        let normY = CGFloat((pt.close - minVal) / range)
                        let y = size.height - padY - (normY * drawableHeight)
                        if i == 0 {
                            path.move(to: CGPoint(x: x, y: y))
                        } else {
                            path.addLine(to: CGPoint(x: x, y: y))
                        }
                    }
                    context.stroke(path, with: .color(tint), lineWidth: 1.5)
                }
            } else {
                Capsule().fill(DS.cardAlt).frame(height: 2)
            }
        }
        .frame(width: width, height: height)
    }
}

/// Floating chart tooltip capable of displaying both price snapshot and matched insider trading events.
struct ChartTooltipWithInsider: View {
    let title: String
    let value: String
    let tint: Color
    var insiderTrade: PriceChartCard.GroupedInsiderTrade? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(DS.micro).foregroundStyle(DS.inkTertiary)
            Text(value).font(.inter(12, weight: .semibold, relativeTo: .body).monospacedDigit()).foregroundStyle(tint)

            if let trade = insiderTrade {
                Divider().opacity(0.3)
                HStack(spacing: 4) {
                    Circle()
                        .fill(trade.isBuy ? DS.up : DS.down)
                        .frame(width: 6, height: 6)
                    Text(trade.isBuy ? "BUY" : "SELL")
                        .font(.inter(9, weight: .bold, relativeTo: .caption2))
                        .foregroundStyle(trade.isBuy ? DS.up : DS.down)

                    let sharesStr = formatShares(trade.totalShares)
                    let valStr = formatCurrency(trade.totalValue)
                    if trade.count > 1 {
                        Text("\(trade.count) Trades: \(sharesStr) shs (\(valStr))")
                            .font(.inter(10, weight: .medium, relativeTo: .caption2))
                            .foregroundStyle(DS.ink)
                            .lineLimit(1)
                    } else {
                        Text("\(trade.primaryOwner): \(sharesStr) shs (\(valStr))")
                            .font(.inter(10, weight: .medium, relativeTo: .caption2))
                            .foregroundStyle(DS.ink)
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(DS.card)
            .shadow(color: .black.opacity(0.12), radius: 6, y: 2))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(DS.hairline))
        .fixedSize()
    }

    private func formatShares(_ shares: Double) -> String {
        if shares >= 1_000_000 {
            return String(format: "%.1fM", shares / 1_000_000)
        } else if shares >= 1_000 {
            return String(format: "%.1fK", shares / 1_000)
        }
        return String(format: "%.0f", shares)
    }

    private func formatCurrency(_ value: Double) -> String {
        let absVal = abs(value)
        if absVal >= 1_000_000 {
            return "$\(String(format: "%.1fM", absVal / 1_000_000))"
        } else if absVal >= 1_000 {
            return "$\(String(format: "%.0fK", absVal / 1_000))"
        }
        return "$\(String(format: "%.0f", absVal))"
    }
}
