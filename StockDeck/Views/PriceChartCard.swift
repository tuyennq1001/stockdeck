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

    private var effectiveChartStyle: ChartStyle {
        showStylePicker ? chartStyle : .line
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
        
        let daily = stockService.priceHistory[symbol] ?? []
        let cutoff: Date?
        if let days = chartRange.days {
            cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date())
        } else {
            cutoff = nil
        }
        
        let filteredDaily = cutoff != nil ? daily.filter { $0.date >= cutoff! } : daily
        
        // Tư duy triển khai ngang: Nếu khoảng thời gian thực tế <= 2 năm, ép dùng Daily để biểu đồ mượt nhất
        if let earliest = filteredDaily.first?.date, Calendar.current.dateComponents([.day], from: earliest, to: Date()).day ?? 0 <= 730 {
            return filteredDaily
        }
        
        if chartRange == .all {
            let maxPoints = stockService.priceHistoryMax[symbol] ?? []
            return cutoff != nil ? maxPoints.filter { $0.date >= cutoff! } : maxPoints
        }
        
        return filteredDaily
    }

    private var isLoadingCurrent: Bool {
        switch chartRange {
        case .all: return stockService.priceHistoryMax[symbol] == nil
        default: return stockService.priceHistory[symbol] == nil
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
                rangePicker
                    .padding(.top, 2)
            }

            // Row 3: Chart.
            chart
                .frame(height: chartHeight)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
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

    @ViewBuilder private var stylePicker: some View {
        if tradingViewSymbol != nil {
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
        let mins = history.map(\.effectiveLow)
        let maxs = history.map(\.effectiveHigh)
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
