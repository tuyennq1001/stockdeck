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
        case candlestick
    }

    @State private var chartRange: ChartRange = .month
    @State private var chartStyle: ChartStyle = .line
    @State private var hoverPoint: PricePoint?

    private var priceSymbol: String { StorageService.currencySymbol(for: quote.currency) }

    private var displayedPriceInfo: (price: Double, diff: Double, diffPct: Double, label: String) {
        let basePrice = quote.displayPrice(extendedHours: storageService.showExtendedHours)
        if let hp = hoverPoint {
            let startPrice = history.first?.close ?? basePrice
            let diff = hp.close - startPrice
            let diffPct = startPrice > 0 ? (diff / startPrice) * 100 : 0
            return (hp.close, diff, diffPct, chartRange.changeLabel)
        }

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

    private func calculateCandleWidth(pointCount: Int) -> CGFloat {
        if pointCount <= 30 { return 7 }
        if pointCount <= 60 { return 5 }
        if pointCount <= 120 { return 3 }
        if pointCount <= 300 { return 2 }
        return 1
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
            // Row 1: Last Price & Change Pill
            VStack(alignment: .leading, spacing: 4) {
                let info = displayedPriceInfo
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

            // Row 2: Range Picker + Style Picker
            if (stockService.priceHistory[symbol]?.count ?? 0) >= 2 {
                HStack(spacing: 6) {
                    rangePicker
                    Spacer(minLength: 0)
                    stylePicker
                }
            }

            // Row 3: Chart
            chart
                .frame(height: 190)
        }
        .padding(DS.pad)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .premiumCard()
        .task(id: symbol) { await stockService.ensurePriceHistory(for: symbol) }
        .task(id: "\(symbol)-\(chartRange.rawValue)") {
            if chartRange == .all { await stockService.ensurePriceHistoryMax(for: symbol) }
        }
    }

    private var rangePicker: some View {
        SegmentedRangePicker(options: ChartRange.allCases, label: \.rawValue, selection: $chartRange)
    }

    private var stylePicker: some View {
        HStack(spacing: 2) {
            Button(action: { chartStyle = .line }) {
                Image(systemName: "line.uptrend.xyaxis")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(chartStyle == .line ? .white : DS.inkSecondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(chartStyle == .line ? DS.brand : Color.clear))
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .help("Line chart")

            Button(action: { chartStyle = .candlestick }) {
                Image(systemName: "chart.bar.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(chartStyle == .candlestick ? .white : DS.inkSecondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(chartStyle == .candlestick ? DS.brand : Color.clear))
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .help("Candlestick chart")
        }
        .padding(2)
        .background(Capsule().fill(DS.cardAlt))
    }

    @ViewBuilder private var chart: some View {
        if history.count >= 2 {
            let periodUp = (history.last?.close ?? 0) >= (history.first?.close ?? 0)
            let tint = periodUp ? DS.up : DS.down
            Chart {
                if chartStyle == .line {
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
                } else {
                    let candleWidth = calculateCandleWidth(pointCount: history.count)
                    ForEach(history) { point in
                        let isUp = point.close >= point.effectiveOpen
                        let candleTint = isUp ? DS.up : DS.down

                        RuleMark(
                            x: .value("Day", point.date),
                            yStart: .value("Low", point.effectiveLow),
                            yEnd: .value("High", point.effectiveHigh)
                        )
                        .foregroundStyle(candleTint)
                        .lineStyle(.init(lineWidth: 1))

                        BarMark(
                            x: .value("Day", point.date),
                            yStart: .value("Open", min(point.effectiveOpen, point.close)),
                            yEnd: .value("Close", max(point.effectiveOpen, point.close)),
                            width: .fixed(candleWidth)
                        )
                        .foregroundStyle(candleTint)
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

    private var points: [PricePoint] {
        guard let all = stockService.priceHistory[symbol],
              let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: Date())
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
