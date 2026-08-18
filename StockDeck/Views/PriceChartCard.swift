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
                return max(1, cal.dateComponents([.day], from: jan1, to: now).day ?? 30)
            case .year: return 365
            case .threeYears: return 365 * 3
            case .fiveYears: return 365 * 5
            case .all: return nil
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
    @Environment(\.colorScheme) private var colorScheme

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

        let lastPrice = history.last?.close ?? basePrice
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
        case .year, .threeYears, .fiveYears, .all:
            return date.formatted(.dateTime.month(.abbreviated).year(.twoDigits))
        }
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
                        Group {
                            Path { p in p.move(to: CGPoint(x: cx, y: plot.minY)); p.addLine(to: CGPoint(x: cx, y: plot.maxY)) }
                                .stroke(DS.inkTertiary.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                            Circle().fill(tint).frame(width: 9, height: 9)
                                .overlay(Circle().strokeBorder(.white, lineWidth: 1.5))
                                .position(x: cx, y: plot.minY + py)

                            ChartTooltip(title: hoverLabel(h.date),
                                         value: "\(priceSymbol)\(StorageService.formatNumber(h.close, decimals: dec))",
                                         tint: tint)
                                .position(x: min(max(cx, plot.minX + 50), plot.maxX - 50), y: plot.minY + 12)
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
        if chartRange == .all {
            return stockService.priceHistoryMax[symbol] ?? []
        }
        guard let all = stockService.priceHistory[symbol] else { return [] }
        guard let days = chartRange.days,
              let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date())
        else { return all }
        return all.filter { $0.date >= cutoff }
    }

    private var isLoadingCurrent: Bool {
        switch chartRange {
        case .all: return stockService.priceHistoryMax[symbol] == nil
        default: return stockService.priceHistory[symbol] == nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Row 1: Last Price & Change Pill (left) + style picker (right), so
            // the chart below gets the full card width and a taller frame.
            let info = displayedPriceInfo
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    SectionLabel("Last price")
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(StorageService.formatAmount(info.price, symbol: priceSymbol))
                            .font(.inter(26, weight: .bold, relativeTo: .title).monospacedDigit())
                            .tracking(-0.4)
                            .foregroundStyle(DS.ink)
                            .lineLimit(1)
                            .contentTransition(.numericText())
                            .animation(.spring(response: 0.5, dampingFraction: 0.9), value: info.price)

                        HStack(spacing: 6) {
                            ChangePill(value: info.diff,
                                       text: String(format: "%+.\(storageService.percentDecimals)f%% \(info.label)", info.diffPct))
                            Text(StorageService.formatAmount(info.diff, symbol: priceSymbol, signed: true))
                                .font(DS.caption.monospacedDigit())
                                .foregroundStyle(DS.pnlColor(info.diff))
                                .lineLimit(1)
                        }
                    }
                }
                Spacer(minLength: 8)
                stylePicker
            }

            // Row 2: Chart. The line chart's range picker floats at the bottom-left
            // inside the chart — the same corner TradingView uses — and TradingView
            // mode has its own ranges, so no overlay is drawn there.
            chart
                .overlay(alignment: .bottomLeading) {
                    if chartStyle == .line && (stockService.priceHistory[symbol]?.count ?? 0) >= 2 {
                        rangePicker
                            .padding(.leading, 12).padding(.bottom, 16)
                    }
                }
                .frame(height: 500)
        }
        .padding(DS.pad)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .premiumCard()
        .task(id: symbol) { await stockService.ensurePriceHistory(for: symbol) }
        .task(id: "\(symbol)-\(chartRange.rawValue)") {
            if chartRange == .all { await stockService.ensurePriceHistoryMax(for: symbol) }
        }
        .onAppear {
            chartStyle = ChartStyle(rawValue: storageService.defaultChartStyle) ?? .line
            if let savedRange = ChartRange(rawValue: storageService.lastStockChartRange) {
                chartRange = savedRange
            }
        }
        .onChange(of: storageService.defaultChartStyle) { _, newValue in
            chartStyle = ChartStyle(rawValue: newValue) ?? .line
        }
        .onChange(of: chartRange) { _, newRange in
            storageService.lastStockChartRange = newRange.rawValue
        }
    }

    private var rangePicker: some View {
        SegmentedRangePicker(options: ChartRange.allCases, label: \.rawValue, selection: $chartRange)
    }

    private var stylePicker: some View {
        HStack(spacing: 4) {
            Button(action: { chartStyle = .line }) {
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

            Button(action: { chartStyle = .tradingview }) {
                HStack(spacing: 5) {
                    Text("Trading")
                        .font(.inter(11, weight: .bold, relativeTo: .caption))
                    Text("View")
                        .font(.inter(11, weight: .semibold, relativeTo: .caption))
                }
                .foregroundStyle(chartStyle == .tradingview ? .white : DS.inkSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Capsule().fill(chartStyle == .tradingview ? DS.brand : Color.clear))
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .disabled(tradingViewSymbol == nil)
            .help(tradingViewSymbol == nil ? "Not available on TradingView" : "TradingView chart")
        }
        .padding(3)
        .background(Capsule().fill(DS.cardAlt))
    }

    @ViewBuilder private var chart: some View {
        if chartStyle == .tradingview {
            if let tvSymbol = tradingViewSymbol {
                TradingViewChartView(tvSymbol: tvSymbol,
                                     theme: colorScheme == .dark ? "dark" : "light",
                                     interval: "D")
                    // Force a brand-new web view per symbol so switching stocks
                    // can never leave the previous symbol's chart on screen.
                    .id(tvSymbol)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .padding(.horizontal, DS.pad)
                    .padding(.bottom, 10)
            } else {
                ZStack {
                    DS.cardAlt
                    VStack(spacing: 5) {
                        Image(systemName: "chart.xyaxis.line").font(.system(size: 20)).foregroundStyle(DS.inkTertiary)
                        Text("TradingView chart not available for this symbol")
                            .font(.inter(11, weight: .medium, relativeTo: .caption)).foregroundStyle(DS.inkSecondary)
                    }
                }
            }
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
            .padding(.horizontal, DS.pad).padding(.bottom, 12)
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
        let mins = history.map(\.effectiveLow)
        let maxs = history.map(\.effectiveHigh)
        guard let min = mins.min(), let max = maxs.max(), max > min else { return 0...1 }
        let pad = (max - min) * 0.08
        return (min - pad)...(max + pad)
    }
}

/// A tiny 30-day price line for table rows — no axes, tinted by direction.
/// Lazily triggers the (cached) history fetch for its symbol.
///
/// Reads the shared service directly (not @EnvironmentObject): `Table` cells on
/// macOS are hosted outside the SwiftUI environment chain, so an environment
/// object would crash here.
struct Sparkline: View {
    @ObservedObject private var stockService = StockService.shared
    let symbol: String
    var days: Int = 30

    private var points: [PricePoint] {
        guard let all = stockService.watchlistHistory[symbol],
              let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date())
        else { return [] }
        return all.filter { $0.date >= cutoff }
    }

    var body: some View {
        Group {
            if points.count >= 2 {
                let up = (points.last?.close ?? 0) >= (points.first?.close ?? 0)
                let tint = up ? DS.up : DS.down
                Chart(points) { point in
                    LineMark(x: .value("Day", point.date), y: .value("Close", point.close))
                        .foregroundStyle(tint).lineStyle(.init(lineWidth: 1.5))
                        .interpolationMethod(.monotone)
                }
                .chartYScale(domain: sparkDomain)
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .chartLegend(.hidden)
            } else {
                Capsule().fill(DS.cardAlt).frame(height: 2)
            }
        }
        .frame(width: 64, height: 22)
        // History is filled by the watchlist's batched spark request, so no
        // per-row fetch here (that would be one request per symbol).
    }

    private var sparkDomain: ClosedRange<Double> {
        let closes = points.map(\.close)
        guard let min = closes.min(), let max = closes.max(), max > min else { return 0...1 }
        return min...max
    }
}
