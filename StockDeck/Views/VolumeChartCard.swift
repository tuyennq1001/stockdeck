import SwiftUI
import Charts

/// A dedicated, beautifully styled card displaying historical trading volume and MA20 moving average.
/// Implements discrete session indexing (no weekend/holiday gaps like TradingView),
/// full-history MA20 warm-up, and 1D / 1W / 1M timeframe selection.
struct VolumeChartCard: View {
    let symbol: String
    let quote: StockQuote
    var chartHeight: CGFloat = 145

    @ObservedObject private var stockService = StockService.shared
    @ObservedObject private var storageService = StorageService.shared

    @State private var timeframe: Timeframe
    @State private var preparedData: PreparedVolumeData
    @State private var hoverPoint: VolumePoint?

    init(symbol: String, quote: StockQuote, chartHeight: CGFloat = 145) {
        self.symbol = symbol
        self.quote = quote
        self.chartHeight = chartHeight
        let initialTimeframe = Timeframe(rawValue: StorageService.shared.lastVolumeChartTimeframe) ?? .daily
        self._timeframe = State(initialValue: initialTimeframe)

        let stockService = StockService.shared
        let initialInput = HistoryInput(
            symbol: symbol,
            timeframe: initialTimeframe,
            daily: stockService.priceHistory[symbol] ?? [],
            watchlist: stockService.watchlistHistory[symbol] ?? [],
            full: stockService.priceHistoryMax[symbol] ?? [],
            quoteRegularMarketVolume: quote.regularMarketVolume
        )
        self._preparedData = State(initialValue: Self.processVolumeData(input: initialInput))
    }

    enum Timeframe: String, CaseIterable, Identifiable, Sendable {
        case daily = "1D"
        case weekly = "1W"
        case monthly = "1M"

        var id: String { rawValue }

        var targetBarCount: Int {
            switch self {
            case .daily: return 50
            case .weekly: return 52
            case .monthly: return 42
            }
        }
    }

    struct VolumePoint: Identifiable, Equatable, Sendable {
        let id: String
        let index: Int
        let date: Date
        let volume: Double
        let value: Double
        let isUp: Bool
        let ma: Double?
        let close: Double
        let dayCount: Int
    }

    struct PreparedVolumeData: Sendable {
        let points: [VolumePoint]
        let latestVolume: Double
        let latestValue: Double
        let latestMA20: Double
        let latestRatioVsMA20: Double?
        let isLatestUp: Bool
    }

    struct HistoryInput: Equatable, Sendable {
        let symbol: String
        let timeframe: Timeframe
        let daily: [PricePoint]
        let watchlist: [PricePoint]
        let full: [PricePoint]
        let quoteRegularMarketVolume: Double?

        init(symbol: String, timeframe: Timeframe, daily: [PricePoint], watchlist: [PricePoint], full: [PricePoint], quoteRegularMarketVolume: Double? = nil) {
            self.symbol = symbol
            self.timeframe = timeframe
            self.daily = daily
            self.watchlist = watchlist
            self.full = full
            self.quoteRegularMarketVolume = quoteRegularMarketVolume
        }
    }

    private var historyInput: HistoryInput {
        HistoryInput(
            symbol: symbol,
            timeframe: timeframe,
            daily: stockService.priceHistory[symbol] ?? [],
            watchlist: stockService.watchlistHistory[symbol] ?? [],
            full: stockService.priceHistoryMax[symbol] ?? [],
            quoteRegularMarketVolume: quote.regularMarketVolume
        )
    }

    private var displayedValue: Double {
        if let hover = hoverPoint { return hover.value }
        return preparedData.latestValue
    }

    private var displayedMA: Double {
        if let hover = hoverPoint { return hover.ma ?? 0 }
        return preparedData.latestMA20
    }

    private var displayedRatio: Double? {
        if let hover = hoverPoint {
            guard let ma = hover.ma, ma > 0 else { return nil }
            return ((hover.value - ma) / ma) * 100.0
        }
        return preparedData.latestRatioVsMA20
    }

    private var displayedIsUp: Bool {
        if let hover = hoverPoint { return hover.isUp }
        return preparedData.isLatestUp
    }

    private var hasVolumeData: Bool {
        preparedData.points.contains(where: { $0.value > 0 })
    }

    private var isVNIndex: Bool {
        let clean = symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            .replacingOccurrences(of: ".HM", with: "").replacingOccurrences(of: ".HN", with: "").replacingOccurrences(of: ".VN", with: "")
            .replacingOccurrences(of: "^", with: "")
        return clean == "VNINDEX" || clean == "HNXINDEX" || clean == "UPINDEX"
    }

    private var isLoadingCurrent: Bool {
        switch timeframe {
        case .monthly:
            return stockService.priceHistory[symbol] == nil && stockService.priceHistoryMax[symbol] == nil
        default:
            return stockService.priceHistory[symbol] == nil
        }
    }

    private func formatTradingValue(_ val: Double, isCompact: Bool = false) -> String {
        let isVi = storageService.appLanguage == "vi"
        let curr = quote.currency.uppercased()
        let isVND = curr == "VND" || isVNIndex

        if isVND {
            let ty = val / 1_000_000_000.0
            if isVi {
                if isCompact {
                    if ty >= 1000.0 {
                        let kTy = ty / 1000.0
                        if kTy == round(kTy) {
                            return "\(Int(round(kTy)))K tỷ"
                        } else {
                            return String(format: "%.1fK tỷ", kTy)
                        }
                    } else if ty >= 1.0 {
                        let formatter = NumberFormatter()
                        formatter.numberStyle = .decimal
                        formatter.groupingSeparator = "."
                        formatter.maximumFractionDigits = 0
                        let formatted = formatter.string(from: NSNumber(value: Int(round(ty)))) ?? "\(Int(round(ty)))"
                        return "\(formatted) tỷ"
                    } else if val >= 1_000_000.0 {
                        let tr = val / 1_000_000.0
                        return String(format: "%.0f tr", tr)
                    }
                    return "\(Int(val))"
                } else {
                    return StorageService.formatIndexTurnover(val, isVietnamese: true)
                }
            } else {
                if isCompact {
                    if val >= 1_000_000_000_000.0 {
                        let t = val / 1_000_000_000_000.0
                        return t == round(t) ? "\(Int(round(t)))T" : String(format: "%.1fT", t)
                    } else if val >= 1_000_000_000.0 {
                        let b = val / 1_000_000_000.0
                        return b == round(b) ? "\(Int(round(b)))B" : String(format: "%.1fB", b)
                    } else {
                        let m = val / 1_000_000.0
                        return m == round(m) ? "\(Int(round(m)))M" : String(format: "%.1fM", m)
                    }
                } else {
                    return StorageService.formatIndexTurnover(val, currency: "VND", isVietnamese: false)
                }
            }
        } else {
            let symbol = StorageService.currencySymbol(for: quote.currency)
            let absVal = abs(val)
            if isCompact {
                if absVal >= 1_000_000_000_000.0 {
                    let t = absVal / 1_000_000_000_000.0
                    return t == round(t) ? "\(Int(round(t)))T" : String(format: "%.1fT", t)
                } else if absVal >= 1_000_000_000.0 {
                    let b = absVal / 1_000_000_000.0
                    return b == round(b) ? "\(Int(round(b)))B" : String(format: "%.1fB", b)
                } else if absVal >= 1_000_000.0 {
                    let m = absVal / 1_000_000.0
                    return m == round(m) ? "\(Int(round(m)))M" : String(format: "%.1fM", m)
                } else if absVal >= 1_000.0 {
                    let k = absVal / 1_000.0
                    return k == round(k) ? "\(Int(round(k)))K" : String(format: "%.1fK", k)
                }
                return "\(Int(round(val)))"
            } else {
                return StorageService.formatCompactAmount(val, symbol: symbol)
            }
        }
    }

    private func formatDateForHover(_ date: Date) -> String {
        switch timeframe {
        case .daily:
            return date.formatted(date: .abbreviated, time: .omitted)
        case .weekly:
            return "Week of " + date.formatted(date: .abbreviated, time: .omitted)
        case .monthly:
            return date.formatted(.dateTime.month(.wide).year())
        }
    }

    private func formatAxisDate(_ date: Date) -> String {
        switch timeframe {
        case .daily:
            return date.formatted(.dateTime.day().month(.abbreviated))
        case .weekly:
            return date.formatted(.dateTime.month(.abbreviated).year(.twoDigits))
        case .monthly:
            return date.formatted(.dateTime.year())
        }
    }

    private var xAxisIndices: [Int] {
        let count = preparedData.points.count
        guard count >= 4 else { return Array(0..<count) }

        let cal = Calendar.current
        var boundaryIndices: [Int] = []

        switch timeframe {
        case .daily:
            for i in 1..<count {
                let prev = preparedData.points[i - 1].date
                let curr = preparedData.points[i].date
                if !cal.isDate(prev, equalTo: curr, toGranularity: .month) {
                    boundaryIndices.append(i)
                }
            }
        case .weekly:
            for i in 1..<count {
                let prev = preparedData.points[i - 1].date
                let curr = preparedData.points[i].date
                let pMonth = cal.component(.month, from: prev)
                let cMonth = cal.component(.month, from: curr)
                if pMonth != cMonth && [1, 4, 7, 10].contains(cMonth) {
                    boundaryIndices.append(i)
                }
            }
        case .monthly:
            for i in 1..<count {
                let prev = preparedData.points[i - 1].date
                let curr = preparedData.points[i].date
                if !cal.isDate(prev, equalTo: curr, toGranularity: .year) {
                    boundaryIndices.append(i)
                }
            }
        }

        if boundaryIndices.count >= 2 && boundaryIndices.count <= 6 {
            return boundaryIndices
        }

        let step = max(1, count / 4)
        var indices: [Int] = []
        var cur = step / 2
        while cur < count {
            indices.append(cur)
            cur += step
        }
        return indices
    }

    private func computeBarWidth(count: Int) -> CGFloat {
        if count <= 20 { return 12.0 }
        if count <= 35 { return 9.0 }
        if count <= 55 { return 6.5 }
        if count <= 75 { return 5.0 }
        return 3.5
    }

    private var timeframePicker: some View {
        SegmentedRangePicker(
            options: Timeframe.allCases,
            label: \.rawValue,
            selection: $timeframe
        )
    }

    @ViewBuilder
    var body: some View {
        if stockService.isJapaneseMutualFund(symbol) {
            EmptyView()
        } else {
            cardContent
        }
    }

    private var cardContent: some View {
        let amber = Color(red: 0.88, green: 0.50, blue: 0.05)
        let pts = preparedData.points
        let barW = computeBarWidth(count: pts.count)
        let maxVal = pts.map(\.value).max() ?? 0
        let maxMA = pts.compactMap(\.ma).max() ?? 0
        let topY = max(maxVal, maxMA) * 1.08

        return VStack(alignment: .leading, spacing: 10) {
            // Header Row: Section Label + Ratio Badge (left) & Timeframe Picker (right)
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        SectionLabel(storageService.appLanguage == "vi" ? "Giá trị giao dịch" : "Trading Value")

                        let displayedDate = hoverPoint?.date ?? pts.last?.date
                        if let date = displayedDate {
                            Text(formatDateForHover(date))
                                .font(DS.micro.weight(.medium))
                                .foregroundStyle(DS.inkSecondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    Capsule()
                                        .fill(DS.cardAlt)
                                )
                        }
                    }

                    // Stats: Value & MA20
                    HStack(spacing: 10) {
                        let isVi = storageService.appLanguage == "vi"
                        if displayedValue > 0 {
                            HStack(spacing: 3) {
                                Text(isVi ? "GTGD:" : "Val:")
                                    .font(DS.micro)
                                    .foregroundStyle(DS.inkTertiary)
                                Text(formatTradingValue(displayedValue))
                                    .font(.inter(13, weight: .bold, relativeTo: .body).monospacedDigit())
                                    .foregroundStyle(displayedIsUp ? DS.up : DS.down)
                            }
                        }

                        if displayedMA > 0 {
                            HStack(spacing: 3) {
                                Circle().fill(amber).frame(width: 5, height: 5)
                                Text("MA20:")
                                    .font(DS.micro)
                                    .foregroundStyle(DS.inkTertiary)
                                Text(formatTradingValue(displayedMA))
                                    .font(.inter(13, weight: .semibold, relativeTo: .body).monospacedDigit())
                                    .foregroundStyle(amber)
                            }
                        }
                    }
                }

                Spacer()

                timeframePicker
            }

            // Volume Plot (Discrete session indexing without weekend gaps)
            if !pts.isEmpty && hasVolumeData {
                Chart {
                    ForEach(pts) { item in
                        BarMark(
                            x: .value("Index", item.index),
                            y: .value("Value", item.value),
                            width: .fixed(barW)
                        )
                        .foregroundStyle(
                            (item.isUp ? DS.up : DS.down)
                                .opacity(hoverPoint == nil || hoverPoint?.id == item.id ? 0.85 : 0.40)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: min(1.5, barW / 2), style: .continuous))

                        if let ma = item.ma {
                            LineMark(
                                x: .value("Index", item.index),
                                y: .value("MA", ma)
                            )
                            .foregroundStyle(amber)
                            .lineStyle(StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                            .interpolationMethod(.monotone)
                        }
                    }

                    if let hover = hoverPoint {
                        RuleMark(x: .value("Index", hover.index))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                            .foregroundStyle(DS.inkTertiary.opacity(0.55))
                    }
                }
                .chartXScale(domain: -0.5 ... (Double(pts.count) - 0.5))
                .chartYScale(domain: 0 ... (topY > 0 ? topY : 1.0))
                .chartXAxis {
                    AxisMarks(values: xAxisIndices) { value in
                        AxisGridLine().foregroundStyle(DS.hairline.opacity(0.35))
                        if let idx = value.as(Int.self), idx >= 0, idx < pts.count {
                            AxisValueLabel {
                                Text(formatAxisDate(pts[idx].date))
                                    .font(DS.micro)
                                    .foregroundStyle(DS.inkTertiary)
                            }
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { v in
                        AxisGridLine().foregroundStyle(DS.hairline.opacity(0.35))
                        AxisValueLabel {
                            if let d = v.as(Double.self), d > 0 {
                                Text(formatTradingValue(d, isCompact: true))
                                    .font(DS.micro.monospacedDigit())
                                    .foregroundStyle(DS.inkTertiary)
                            }
                        }
                    }
                }
                .chartOverlay { proxy in
                    GeometryReader { geo in
                        if let plotFrame = proxy.plotFrame {
                            let plot = geo[plotFrame]
                            Rectangle().fill(.clear).contentShape(Rectangle())
                                .onContinuousHover { phase in
                                    switch phase {
                                    case .active(let loc):
                                        let relativeX = loc.x - plot.origin.x
                                        if let idxDouble: Double = proxy.value(atX: relativeX) {
                                            let rounded = Int(round(idxDouble))
                                            let clamped = min(max(0, rounded), pts.count - 1)
                                            if clamped >= 0 && clamped < pts.count {
                                                hoverPoint = pts[clamped]
                                            }
                                        }
                                    case .ended:
                                        hoverPoint = nil
                                    }
                                }
                        }
                    }
                }
                .frame(height: chartHeight)
                .transition(.opacity.animation(.easeInOut(duration: 0.2)))
            } else {
                ZStack {
                    DS.cardAlt
                    VStack(spacing: 6) {
                        if isLoadingCurrent {
                            ProgressView().scaleEffect(0.6)
                            Text("Loading volume history…")
                                .font(DS.micro)
                                .foregroundStyle(DS.inkSecondary)
                        } else {
                            Image(systemName: "chart.bar.xaxis")
                                .font(.system(size: 18))
                                .foregroundStyle(DS.inkTertiary)
                            Text("No volume history available")
                                .font(DS.micro)
                                .foregroundStyle(DS.inkSecondary)
                        }
                    }
                }
                .frame(height: chartHeight)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .premiumCard()
        .task(id: historyInput) {
            let input = historyInput
            let result = await Task.detached(priority: .userInitiated) { () -> PreparedVolumeData in
                Self.processVolumeData(input: input)
            }.value
            preparedData = result
        }
        .task(id: symbol) {
            await stockService.ensurePriceHistory(for: symbol)
        }
        .task(id: "\(symbol)-\(timeframe.rawValue)") {
            if timeframe == .monthly {
                await stockService.ensureFullHistoryMax(for: symbol)
            }
        }
        .onChange(of: timeframe) { _, newTF in
            storageService.lastVolumeChartTimeframe = newTF.rawValue
        }
    }

    /// Background processing function: performs full-history aggregation, MA20 warmup, and discrete session indexing
    /// so the volume bars are spaced evenly (no weekend gaps) and the MA20 curve begins smoothly.
    nonisolated static func processVolumeData(input: HistoryInput) -> PreparedVolumeData {
        let pHist = input.daily
        let wHist = input.watchlist
        let fHist = input.full

        let allDaily: [PricePoint]
        if input.timeframe == .monthly && fHist.contains(where: { ($0.volume ?? 0) > 0 }) {
            allDaily = fHist
        } else if pHist.contains(where: { ($0.volume ?? 0) > 0 }) {
            allDaily = pHist
        } else if wHist.contains(where: { ($0.volume ?? 0) > 0 }) {
            allDaily = wHist
        } else if fHist.contains(where: { ($0.volume ?? 0) > 0 }) {
            allDaily = fHist
        } else {
            allDaily = pHist.isEmpty ? wHist : pHist
        }

        guard !allDaily.isEmpty else {
            return PreparedVolumeData(points: [], latestVolume: 0, latestValue: 0, latestMA20: 0, latestRatioVsMA20: nil, isLatestUp: true)
        }

        let sortedAll = allDaily.sorted(by: { $0.date < $1.date })
        let cal = Calendar.current

        let clean = input.symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            .replacingOccurrences(of: ".HM", with: "").replacingOccurrences(of: ".HN", with: "").replacingOccurrences(of: ".VN", with: "")
            .replacingOccurrences(of: "^", with: "")
        let isVNIdx = clean == "VNINDEX" || clean == "HNXINDEX" || clean == "UPINDEX"

        let lastValidVolume = sortedAll.last(where: { ($0.volume ?? 0) > 0 })?.volume ?? 0
        let effectivePricePerShare: Double
        if let liveTurnover = input.quoteRegularMarketVolume, liveTurnover > 0, lastValidVolume > 0 {
            effectivePricePerShare = liveTurnover / lastValidVolume
        } else {
            effectivePricePerShare = 23_500.0 // Average price per share on HOSE
        }

        let latestPointDate = sortedAll.last?.date

        func computeValue(volume: Double, close: Double, date: Date) -> Double {
            if isVNIdx {
                if date == latestPointDate, let liveTurnover = input.quoteRegularMarketVolume, liveTurnover > 0 {
                    return liveTurnover
                }
                return volume * effectivePricePerShare
            } else if input.symbol.hasPrefix("^") {
                return volume * (close / 100.0)
            } else {
                return volume * close
            }
        }

        // 1. Group into periods
        let fullPeriods: [(date: Date, volume: Double, value: Double, isUp: Bool, close: Double, dayCount: Int)]

        switch input.timeframe {
        case .daily:
            fullPeriods = sortedAll.map { pt in
                let v = pt.volume ?? 0
                let val = computeValue(volume: v, close: pt.close, date: pt.date)
                let up = pt.close >= pt.effectiveOpen
                return (date: pt.date, volume: v, value: val, isUp: up, close: pt.close, dayCount: 1)
            }

        case .weekly:
            var groups: [(date: Date, points: [PricePoint])] = []
            var currentWeekStart: Date?
            var currentPoints: [PricePoint] = []

            for pt in sortedAll {
                let weekStart = cal.dateInterval(of: .weekOfYear, for: pt.date)?.start ?? pt.date
                if let cur = currentWeekStart, cal.isDate(cur, inSameDayAs: weekStart) {
                    currentPoints.append(pt)
                } else {
                    if let cur = currentWeekStart, !currentPoints.isEmpty {
                        groups.append((date: cur, points: currentPoints))
                    }
                    currentWeekStart = weekStart
                    currentPoints = [pt]
                }
            }
            if let cur = currentWeekStart, !currentPoints.isEmpty {
                groups.append((date: cur, points: currentPoints))
            }

            fullPeriods = groups.compactMap { grp in
                guard let first = grp.points.first, let last = grp.points.last else { return nil }
                let sumVol = grp.points.reduce(0.0) { $0 + ($1.volume ?? 0) }
                let sumVal = grp.points.reduce(0.0) { $0 + computeValue(volume: $1.volume ?? 0, close: $1.close, date: $1.date) }
                let isUp = last.close >= first.effectiveOpen
                return (date: grp.date, volume: sumVol, value: sumVal, isUp: isUp, close: last.close, dayCount: grp.points.count)
            }

        case .monthly:
            var groups: [(date: Date, points: [PricePoint])] = []
            var currentMonthStart: Date?
            var currentPoints: [PricePoint] = []

            for pt in sortedAll {
                let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: pt.date)) ?? pt.date
                if let cur = currentMonthStart, cal.isDate(cur, equalTo: monthStart, toGranularity: .month) {
                    currentPoints.append(pt)
                } else {
                    if let cur = currentMonthStart, !currentPoints.isEmpty {
                        groups.append((date: cur, points: currentPoints))
                    }
                    currentMonthStart = monthStart
                    currentPoints = [pt]
                }
            }
            if let cur = currentMonthStart, !currentPoints.isEmpty {
                groups.append((date: cur, points: currentPoints))
            }

            fullPeriods = groups.compactMap { grp in
                guard let first = grp.points.first, let last = grp.points.last else { return nil }
                let sumVol = grp.points.reduce(0.0) { $0 + ($1.volume ?? 0) }
                let sumVal = grp.points.reduce(0.0) { $0 + computeValue(volume: $1.volume ?? 0, close: $1.close, date: $1.date) }
                let isUp = last.close >= first.effectiveOpen
                return (date: grp.date, volume: sumVol, value: sumVal, isUp: isUp, close: last.close, dayCount: grp.points.count)
            }
        }

        // 2. Compute MA20 across the FULL history so MA is fully warmed up at the start of the visible slice
        let maPeriod = 20
        var fullWithMA: [(date: Date, volume: Double, value: Double, isUp: Bool, ma: Double?, close: Double, dayCount: Int)] = []
        fullWithMA.reserveCapacity(fullPeriods.count)

        for i in 0..<fullPeriods.count {
            let start = max(0, i - maPeriod + 1)
            var sumVal: Double = 0
            var count = 0
            for j in start...i {
                if fullPeriods[j].value > 0 {
                    sumVal += fullPeriods[j].value
                    count += 1
                }
            }
            let maVal: Double? = count > 0 ? (sumVal / Double(count)) : nil
            let p = fullPeriods[i]
            fullWithMA.append((date: p.date, volume: p.volume, value: p.value, isUp: p.isUp, ma: maVal, close: p.close, dayCount: p.dayCount))
        }

        // 3. Slice to targetBarCount
        let targetCount = input.timeframe.targetBarCount
        let sliced = fullWithMA.count > targetCount ? Array(fullWithMA.suffix(targetCount)) : fullWithMA

        // 4. Assign discrete 0-based sequential indices
        var resultPoints: [VolumePoint] = []
        resultPoints.reserveCapacity(sliced.count)

        for (idx, p) in sliced.enumerated() {
            resultPoints.append(VolumePoint(
                id: "\(idx)-\(p.date.timeIntervalSince1970)",
                index: idx,
                date: p.date,
                volume: p.volume,
                value: p.value,
                isUp: p.isUp,
                ma: p.ma,
                close: p.close,
                dayCount: p.dayCount
            ))
        }

        let latest = resultPoints.last
        let latVol = latest?.volume ?? 0
        let latVal = latest?.value ?? 0
        let latMA = latest?.ma ?? 0
        let latRatio = (latMA > 0) ? (((latVal - latMA) / latMA) * 100.0) : nil
        let latUp = latest?.isUp ?? true

        return PreparedVolumeData(
            points: resultPoints,
            latestVolume: latVol,
            latestValue: latVal,
            latestMA20: latMA,
            latestRatioVsMA20: latRatio,
            isLatestUp: latUp
        )
    }
}
