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

    enum ChartRange: String, CaseIterable, Sendable {
        case month = "1M", threeMonths = "3M", sixMonths = "6M", ytd = "YTD", year = "1Y", threeYears = "3Y", fiveYears = "5Y", sevenYears = "7Y", tenYears = "10Y", all = "All"
        /// Lookback window in days; nil = the whole fetched history.
        var days: Int? {
            switch self {
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
            case .sevenYears: return 365 * 7
            case .tenYears: return 365 * 10
            case .all: return nil
            }
        }

        /// Calendar-accurate period start date matching Watchlist and Portfolio benchmark metrics.
        func startDate(from now: Date = Date(), calendar: Calendar = .current) -> Date? {
            switch self {
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
            case .sevenYears:
                return calendar.date(byAdding: .year, value: -7, to: now)
            case .tenYears:
                return calendar.date(byAdding: .year, value: -10, to: now)
            case .all:
                return nil
            }
        }
        /// Daily closes for all ranges.
        var isIntraday: Bool { false }

        var changeLabel: String {
            changeLabel(isVi: false)
        }

        func changeLabel(isVi: Bool) -> String {
            switch self {
            case .month: return isVi ? "1 tháng qua" : "past 1M"
            case .threeMonths: return isVi ? "3 tháng qua" : "past 3M"
            case .sixMonths: return isVi ? "6 tháng qua" : "past 6M"
            case .ytd: return "YTD"
            case .year: return isVi ? "1 năm qua" : "past 1Y"
            case .threeYears: return isVi ? "3 năm qua" : "past 3Y"
            case .fiveYears: return isVi ? "5 năm qua" : "past 5Y"
            case .sevenYears: return isVi ? "7 năm qua" : "past 7Y"
            case .tenYears: return isVi ? "10 năm qua" : "past 10Y"
            case .all: return isVi ? "Toàn thời gian" : "all-time"
            }
        }
    }

    @State private var chartRange: ChartRange
    @State private var preparedHistory: PreparedHistory

    init(symbol: String, quote: StockQuote, chartHeight: CGFloat = 280) {
        self.symbol = symbol
        self.quote = quote
        self.chartHeight = chartHeight
        let initialRange = ChartRange(rawValue: StorageService.shared.lastStockChartRange) ?? .month
        self._chartRange = State(initialValue: initialRange)

        let stockService = StockService.shared
        let initialInput = HistoryInput(
            symbol: symbol,
            range: initialRange,
            daily: stockService.priceHistory[symbol] ?? [],
            watchlist: stockService.watchlistHistory[symbol] ?? [],
            full: stockService.priceHistoryMax[symbol] ?? [],
            intraday: stockService.intradayHistory[symbol] ?? []
        )
        let initialPoints = Self.computeHistory(initialInput)
        let initialLow = initialPoints.map(\.close).min() ?? .infinity
        let initialHigh = initialPoints.map(\.close).max() ?? -.infinity
        self._preparedHistory = State(initialValue: PreparedHistory(points: initialPoints, low: initialLow, high: initialHigh))
    }

    private var isVi: Bool {
        storageService.appLanguage.lowercased() == "vi"
    }

    struct HistoryInput: Equatable, Sendable {
        let symbol: String
        let range: ChartRange
        let daily: [PricePoint]
        let watchlist: [PricePoint]
        let full: [PricePoint]
        let intraday: [PricePoint]
    }

    struct PreparedHistory: Sendable {
        let points: [PricePoint]
        let low: Double
        let high: Double
    }

    private var historyInput: HistoryInput {
        HistoryInput(symbol: symbol, range: chartRange,
                     daily: stockService.priceHistory[symbol] ?? [],
                     watchlist: stockService.watchlistHistory[symbol] ?? [],
                     full: stockService.priceHistoryMax[symbol] ?? [],
                     intraday: stockService.intradayHistory[symbol] ?? [])
    }
    @State private var cachedGroupedTrades: [GroupedInsiderTrade] = []
    @ObservedObject private var insiderService = InsiderTradingService.shared

    private var isEligibleForInsider: Bool {
        insiderService.isEligibleSymbol(symbol)
    }

    private var hasInsiderChartTrades: Bool {
        insiderService.hasExecutedChartTrades(for: symbol)
    }

    private var cleanSym: String {
        insiderService.cleanSymbol(symbol)
    }

    private var priceSymbol: String {
        let isIndex = StorageService.isIndex(symbol: quote.symbol, type: storageService.type(for: quote.symbol))
        return isIndex ? "" : StorageService.currencySymbol(for: quote.currency)
    }

    private func displayedPriceInfo(using history: [PricePoint]) -> (price: Double, diff: Double, diffPct: Double, label: String) {
        let basePrice = quote.displayPrice(extendedHours: storageService.showExtendedHours)
        let label = chartRange.changeLabel(isVi: isVi)
        guard history.count >= 2, let firstPrice = history.first?.close, firstPrice > 0 else {
            return (basePrice, quote.change, quote.changePercent, label)
        }

        let lastPrice = basePrice > 0 ? basePrice : (history.last?.close ?? basePrice)
        let diff = lastPrice - firstPrice
        let diffPct = (diff / firstPrice) * 100
        return (lastPrice, diff, diffPct, label)
    }

    // MARK: - Insider Trades Data

    struct GroupedInsiderTrade: Identifiable, Equatable {
        let id: String
        let date: Date
        let price: Double // Chart plot price mapped to split-adjusted closing line
        let executionPrice: Double // Actual historical execution price per share (e.g. pre-split $1200)
        let isBuy: Bool
        let trades: [InsiderTransaction]

        var totalShares: Double { trades.reduce(0) { $0 + $1.shares } }
        var totalValue: Double {
            trades.reduce(0) { sum, tx in
                if tx.price > 0 {
                    return sum + tx.totalValue
                } else {
                    return sum + (tx.shares * executionPrice)
                }
            }
        }
        var count: Int { trades.count }
        var isRule10b51: Bool { !trades.isEmpty && trades.allSatisfy(\.isRule10b51) }
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
        let currentHistory = preparedHistory.points
        guard let firstDate = currentHistory.first?.date, let lastDate = currentHistory.last?.date else { return [] }
        let minDate = min(firstDate, lastDate)
        let maxDate = max(firstDate, lastDate)
        let raw = insiderService.getTransactions(
            for: symbol,
            startDate: minDate,
            endDate: maxDate,
            openMarketOnly: storageService.insiderOpenMarketOnly
        )
        var trades = raw.filter { $0.shares > 0 && !$0.isPendingPlan && ($0.price > 0 || $0.isVNDisclosure) }
        if storageService.excludeInsider10b51 {
            trades = trades.filter { !$0.isRule10b51 }
        }
        guard !trades.isEmpty else { return [] }

        var groups: [String: [InsiderTransaction]] = [:]
        let cal = Calendar.current
        let df = DateFormatter.secDate

        for trade in trades {
            let key: String
            switch chartRange {
            case .month, .threeMonths:
                // Daily granularity
                key = "\(df.string(from: trade.transactionDate))_\(trade.isBuy)"
            case .sixMonths, .ytd, .year:
                // Weekly granularity
                if let weekStart = cal.dateInterval(of: .weekOfYear, for: trade.transactionDate)?.start {
                    key = "W_\(df.string(from: weekStart))_\(trade.isBuy)"
                } else {
                    key = "\(df.string(from: trade.transactionDate))_\(trade.isBuy)"
                }
            case .threeYears, .fiveYears, .sevenYears, .tenYears, .all:
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
            let pricedTrades = groupTrades.filter { $0.price > 0 }
            let pricedShares = pricedTrades.reduce(0.0) { $0 + $1.shares }
            let weightedPrice = pricedShares > 0 ? (pricedTrades.reduce(0.0) { $0 + $1.price * $1.shares } / pricedShares) : 0
            let closeOnDate = nearestClose(for: first.transactionDate, in: currentHistory) ?? (currentHistory.last?.close ?? 0)
            guard closeOnDate > 0 else { return nil }
            let execPrice = weightedPrice > 0 ? weightedPrice : closeOnDate
            return GroupedInsiderTrade(
                id: key,
                date: first.transactionDate,
                price: closeOnDate,
                executionPrice: execPrice,
                isBuy: first.isBuy,
                trades: groupTrades
            )
        }.sorted { $0.date < $1.date }
    }

    private func nearestClose(for date: Date, in history: [PricePoint]) -> Double? {
        PriceHistory.nearestPoint(to: date, in: history)?.close
    }

    nonisolated static func computeHistory(_ input: HistoryInput, now: Date = Date()) -> [PricePoint] {
        let chartRange = input.range
        if chartRange.isIntraday {
            return input.intraday
        }
        
        let pHist = input.daily
        let wHist = input.watchlist
        let daily: [PricePoint]
        if pHist.isEmpty {
            daily = wHist
        } else if wHist.isEmpty {
            daily = pHist
        } else {
            let pHasVol = pHist.contains(where: { ($0.volume ?? 0) > 0 })
            let wHasVol = wHist.contains(where: { ($0.volume ?? 0) > 0 })
            if pHasVol && !wHasVol {
                daily = pHist
            } else if wHasVol && !pHasVol {
                daily = wHist
            } else {
                let pLast = pHist.last?.date ?? .distantPast
                let wLast = wHist.last?.date ?? .distantPast
                if pLast > wLast {
                    daily = pHist
                } else if wLast > pLast {
                    daily = wHist
                } else {
                    daily = pHist.count >= wHist.count ? pHist : wHist
                }
            }
        }
        let maxPoints = input.full
        
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
        
        guard let cutoff = chartRange.startDate(from: now) else {
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
        case .threeYears, .fiveYears, .sevenYears, .tenYears:
            return stockService.priceHistory[symbol] == nil && stockService.priceHistoryMax[symbol] == nil
        default:
            return stockService.priceHistory[symbol] == nil
        }
    }

    private func isRangeAvailable(_ range: ChartRange) -> Bool {
        switch range {
        case .month, .threeMonths, .sixMonths, .ytd:
            return true
        case .year, .threeYears, .fiveYears, .sevenYears, .tenYears:
            guard let cutoff = range.startDate() else { return true }
            let dailyFirst = (stockService.priceHistory[symbol] ?? stockService.watchlistHistory[symbol])?.first?.date
            let maxFirst = stockService.priceHistoryMax[symbol]?.first?.date
            let earliestDate: Date?
            if let d = dailyFirst, let m = maxFirst {
                earliestDate = min(d, m)
            } else {
                earliestDate = dailyFirst ?? maxFirst
            }
            guard let earliest = earliestDate else { return true }
            let tolerance: TimeInterval = 15 * 86400
            return earliest.timeIntervalSince(cutoff) <= tolerance
        case .all:
            return true
        }
    }

    var body: some View {
        let currentHistory = preparedHistory.points
        let info = displayedPriceInfo(using: currentHistory)
        
        return VStack(alignment: .leading, spacing: 10) {
            // Row 1: Last Price & Change Pill, so
            // the chart below gets the full card width and a taller frame.
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        SectionLabel("Last price")
                        if let buyTarget = storageService.buyTarget(for: symbol) {
                            let inZone = buyTarget.isInBuyZone(currentPrice: quote.effectivePrice)
                            let targetPriceStr = "\(priceSymbol)\(StorageService.formatCompactNumber(buyTarget.targetPrice, decimals: storageService.resolvedPriceDecimals(symbol: symbol, price: buyTarget.targetPrice)))"
                            HStack(spacing: 3) {
                                Image(systemName: "target")
                                    .font(.system(size: 9, weight: .bold))
                                Text(isVi ? "Giá mua mục tiêu: \(targetPriceStr)" : "Buy Target: \(targetPriceStr)")
                                    .font(.inter(10, weight: .semibold, relativeTo: .caption2).monospacedDigit())
                                if inZone {
                                    Text(isVi ? "• VÙNG MUA" : "• IN ZONE")
                                        .font(.system(size: 8.5, weight: .bold))
                                } else if let dist = buyTarget.percentDistance(from: quote.effectivePrice) {
                                    Text(String(format: "(%+.1f%%)", dist))
                                        .font(.inter(9.5, weight: .medium, relativeTo: .caption2).monospacedDigit())
                                }
                            }
                            .foregroundStyle(inZone ? DS.up : DS.brand)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                Capsule().fill(inZone ? DS.up.opacity(0.12) : DS.brand.opacity(0.10))
                            )
                        }
                    }
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
            }

            // Row 2: Range Picker (1M, 3M, 6M, YTD, 1Y, 3Y, 5Y, 7Y, 10Y, All) placed above chart
            rangePicker
                .padding(.top, 2)

            // Row 3: Chart.
            PriceChartPlot(currentHistory: currentHistory,
                           chartRange: chartRange,
                           cachedGroupedTrades: cachedGroupedTrades,
                           showInsiderMarkers: storageService.showInsiderMarkers && hasInsiderChartTrades,
                           buyTarget: storageService.buyTarget(for: symbol),
                           symbol: symbol, priceSymbol: priceSymbol,
                           valueDecimals: storageService.valueDecimals,
                           domain: chartDomain(using: currentHistory),
                           isLoadingCurrent: isLoadingCurrent)
                .equatable()
                .frame(height: chartHeight)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .premiumCard()
        .task(id: historyInput) {
            // Capture immutable arrays on MainActor; filter and scan off-thread.
            let input = historyInput
            let worker = Task.detached(priority: .userInitiated) { () throws -> PreparedHistory in
                try Task.checkCancellation()
                let points = Self.computeHistory(input)
                var low = Double.infinity
                var high = -Double.infinity
                for (index, point) in points.enumerated() {
                    if index % 256 == 0 { try Task.checkCancellation() }
                    low = min(low, point.effectiveLow)
                    high = max(high, point.effectiveHigh)
                }
                return PreparedHistory(points: points, low: low, high: high)
            }
            do {
                let result = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    worker.cancel()
                }
                try Task.checkCancellation()
                preparedHistory = result
                updateCachedInsiderTrades()
            } catch { /* Cancelled scope/range work must not publish stale history. */ }
        }
        .task(id: symbol) {
            await stockService.ensurePriceHistory(for: symbol)
            if isEligibleForInsider {
                await insiderService.ensureTransactions(for: symbol)
            }
        }
        .task(id: "\(symbol)-\(chartRange.rawValue)") {
            if chartRange == .all || chartRange == .tenYears || chartRange == .sevenYears || chartRange == .fiveYears || chartRange == .threeYears {
                await stockService.ensureFullHistoryMax(for: symbol)
            }
        }
        .onAppear {
            updateCachedInsiderTrades()
        }
        .onChange(of: chartRange) { _, newRange in
            storageService.lastStockChartRange = newRange.rawValue
            updateCachedInsiderTrades()
        }
        .onChange(of: storageService.showInsiderMarkers) { _, _ in
            updateCachedInsiderTrades()
        }
        .onChange(of: storageService.excludeInsider10b51) { _, _ in
            updateCachedInsiderTrades()
        }
        .onChange(of: storageService.insiderOpenMarketOnly) { _, _ in
            updateCachedInsiderTrades()
        }
        .onChange(of: insiderService.transactions[cleanSym]) { _, _ in
            updateCachedInsiderTrades()
        }
        .onChange(of: currentHistory.count) { _, _ in
            updateCachedInsiderTrades()
        }
    }

    private var rangePicker: some View {
        SegmentedRangePicker(
            options: ChartRange.allCases,
            label: \.rawValue,
            selection: $chartRange,
            isOptionEnabled: { isRangeAvailable($0) },
            disabledHelp: { _ in isVi ? "Dữ liệu lịch sử chưa đủ cho mốc này" : "Historical data does not yet span this period" }
        )
    }

    private func chartDomain(using currentHistory: [PricePoint]) -> ClosedRange<Double> {
        var minVal = preparedHistory.low
        var maxVal = preparedHistory.high
        if storageService.showInsiderMarkers && isEligibleForInsider {
            for trade in cachedGroupedTrades where trade.price > 0 {
                if trade.price < minVal { minVal = trade.price }
                if trade.price > maxVal { maxVal = trade.price }
            }
        }
        if let target = storageService.buyTarget(for: symbol), target.targetPrice > 0 {
            if target.targetPrice < minVal { minVal = target.targetPrice }
            if target.targetPrice > maxVal { maxVal = target.targetPrice }
        }
        guard minVal != .infinity, maxVal != -Double.infinity, maxVal > minVal else { return 0...1 }
        let pad = (maxVal - minVal) * 0.08
        return (minVal - pad)...(maxVal + pad)
    }
}

/// A tiny price line for table rows — rendered using Canvas for near-zero CPU/GPU footprint.
struct Sparkline: View {
    let symbol: String
    var days: Int = 30
    var isYTD: Bool = false
    var width: CGFloat? = 64
    var height: CGFloat? = 22

    private static var pointsCache: [String: (revision: UInt64, points: [PricePoint])] = [:]
    private static let cacheLock = NSLock()

    private var points: [PricePoint] {
        let stockService = StockService.shared
        guard let all = stockService.watchlistHistory[symbol] ?? stockService.priceHistoryMax[symbol], !all.isEmpty else { return [] }
        let cacheKey = "\(symbol)-\(days)-\(isYTD)"
        let revision = stockService.historyRevision

        Self.cacheLock.lock()
        if let entry = Self.pointsCache[cacheKey], entry.revision == revision {
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
        Self.pointsCache[cacheKey] = (revision: revision, points: filtered)
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

/// A tiny volume bar chart for table rows — rendered using Canvas for near-zero CPU/GPU footprint.
/// Supports both 30D daily mode and 20W weekly mode, overlaying a warmed-up MA line.
struct VolumeSparkline: View {
    let symbol: String
    var mode: Mode = .days50
    var width: CGFloat? = 64
    var height: CGFloat? = 22

    enum Mode: String, Hashable, Sendable {
        case days50 = "50d"
        case weeks50 = "50w"
    }

    init(symbol: String, mode: Mode = .days50, width: CGFloat? = 64, height: CGFloat? = 22) {
        self.symbol = symbol
        self.mode = mode
        self.width = width
        self.height = height
    }

    /// Convenience init for backwards compatibility
    init(symbol: String, days: Int, width: CGFloat? = 64, height: CGFloat? = 22) {
        self.symbol = symbol
        self.mode = (days > 70) ? .weeks50 : .days50
        self.width = width
        self.height = height
    }

    struct VolumeBarItem: Equatable {
        let volRatio: CGFloat
        let maRatio: CGFloat?
        let isUp: Bool
        let volume: Double
        let ma: Double?
    }

    private static var barsCache: [String: (revision: UInt64, bars: [VolumeBarItem])] = [:]
    private static let cacheLock = NSLock()

    private var bars: [VolumeBarItem] {
        let stockService = StockService.shared
        let all: [PricePoint]
        if let p = stockService.priceHistory[symbol], p.contains(where: { ($0.volume ?? 0) > 0 }) {
            all = p
        } else if let w = stockService.watchlistHistory[symbol], w.contains(where: { ($0.volume ?? 0) > 0 }) {
            all = w
        } else if let m = stockService.priceHistoryMax[symbol], m.contains(where: { ($0.volume ?? 0) > 0 }) {
            all = m
        } else {
            all = []
        }
        guard !all.isEmpty else { return [] }
        let cacheKey = "\(symbol)-vol-\(mode.rawValue)"
        let revision = stockService.historyRevision

        Self.cacheLock.lock()
        if let entry = Self.barsCache[cacheKey], entry.revision == revision {
            Self.cacheLock.unlock()
            return entry.bars
        }
        Self.cacheLock.unlock()

        let sortedAll = all.sorted(by: { $0.date < $1.date })
        let maPeriod = 50
        let cal = Calendar.current

        let fullPeriods: [(volume: Double, isUp: Bool, close: Double)]

        switch mode {
        case .days50:
            fullPeriods = sortedAll.map { pt in
                let v = pt.volume ?? 0
                let up = pt.close >= pt.effectiveOpen
                return (volume: v, isUp: up, close: pt.close)
            }

        case .weeks50:
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

            fullPeriods = groups.compactMap { grp -> (volume: Double, isUp: Bool, close: Double)? in
                guard let first = grp.points.first, let last = grp.points.last else { return nil }
                let sumVol = grp.points.reduce(0.0) { $0 + ($1.volume ?? 0) }
                let isUp = last.close >= first.effectiveOpen
                return (volume: sumVol, isUp: isUp, close: last.close)
            }
        }

        guard !fullPeriods.isEmpty else {
            Self.cacheLock.lock()
            Self.barsCache[cacheKey] = (revision: revision, bars: [])
            Self.cacheLock.unlock()
            return []
        }

        // Compute MA across the full series
        var withMA: [(volume: Double, isUp: Bool, ma: Double?)] = []
        withMA.reserveCapacity(fullPeriods.count)
        for i in 0..<fullPeriods.count {
            let start = max(0, i - maPeriod + 1)
            var sum: Double = 0
            var count = 0
            for j in start...i {
                if fullPeriods[j].volume > 0 {
                    sum += fullPeriods[j].volume
                    count += 1
                }
            }
            let maVal: Double? = count > 0 ? (sum / Double(count)) : nil
            let p = fullPeriods[i]
            withMA.append((volume: p.volume, isUp: p.isUp, ma: maVal))
        }

        // Slice to visible count: 50 trading sessions or 50 weeks
        let targetCount = 50
        let sliced = withMA.count > targetCount ? Array(withMA.suffix(targetCount)) : withMA

        var maxVal: Double = 0
        for item in sliced {
            if item.volume > maxVal { maxVal = item.volume }
            if let ma = item.ma, ma > maxVal { maxVal = ma }
        }

        guard maxVal > 0 else {
            Self.cacheLock.lock()
            Self.barsCache[cacheKey] = (revision: revision, bars: [])
            Self.cacheLock.unlock()
            return []
        }

        var result: [VolumeBarItem] = []
        result.reserveCapacity(sliced.count)
        for item in sliced {
            let vRatio = CGFloat(min(max(item.volume / maxVal, 0.0), 1.0))
            let mRatio = item.ma.map { CGFloat(min(max($0 / maxVal, 0.0), 1.0)) }
            result.append(VolumeBarItem(volRatio: vRatio, maRatio: mRatio, isUp: item.isUp, volume: item.volume, ma: item.ma))
        }

        Self.cacheLock.lock()
        Self.barsCache[cacheKey] = (revision: revision, bars: result)
        Self.cacheLock.unlock()

        return result
    }

    private func formatVol(_ val: Double) -> String {
        let absVal = abs(val)
        if absVal >= 1_000_000_000 {
            return String(format: "%.2fB", val / 1_000_000_000)
        } else if absVal >= 1_000_000 {
            return String(format: "%.1fM", val / 1_000_000)
        } else if absVal >= 1_000 {
            return String(format: "%.0fK", val / 1_000)
        }
        return String(format: "%.0f", val)
    }

    private var tooltipText: String {
        guard let last = bars.last, last.volume > 0 else { return "" }
        let volStr = formatVol(last.volume)
        if let ma = last.ma, ma > 0 {
            let diff = ((last.volume - ma) / ma) * 100.0
            let sign = diff >= 0 ? "+" : ""
            let maLabel = (mode == .weeks50) ? "MA50W" : "MA50"
            return "Vol: \(volStr) • \(maLabel): \(formatVol(ma)) (\(sign)\(String(format: "%.1f%%", diff)))"
        }
        return "Vol: \(volStr)"
    }

    var body: some View {
        let barData = bars
        Group {
            if !barData.isEmpty {
                Canvas { context, size in
                    guard size.width > 0, size.height > 0 else { return }
                    let count = barData.count
                    guard count > 0 else { return }

                    let spacing: CGFloat = (count > 30) ? 0.5 : 1.0
                    let totalSpacing = CGFloat(count - 1) * spacing
                    let barWidth = max(0.8, (size.width - totalSpacing) / CGFloat(count))
                    let minBarHeight: CGFloat = 2.0

                    // 1. Draw volume bars with 50% opacity
                    for (i, bar) in barData.enumerated() {
                        let x = CGFloat(i) * (barWidth + spacing)
                        let barHeight = max(minBarHeight, bar.volRatio * size.height)
                        let y = size.height - barHeight
                        let rect = CGRect(x: x, y: y, width: barWidth, height: barHeight)
                        let tint = bar.isUp ? DS.up : DS.down
                        context.fill(Path(roundedRect: rect, cornerRadius: min(1.0, barWidth / 2)), with: .color(tint.opacity(0.50)))
                    }

                    // 2. Draw smoothed MA line on top in amber
                    var maPath = Path()
                    var hasPoint = false
                    for (i, bar) in barData.enumerated() {
                        guard let maRatio = bar.maRatio else { continue }
                        let xCenter = CGFloat(i) * (barWidth + spacing) + barWidth / 2.0
                        let yMa = size.height - (maRatio * size.height)
                        let pt = CGPoint(x: xCenter, y: min(max(yMa, 1.0), size.height - 1.0))
                        if !hasPoint {
                            maPath.move(to: pt)
                            hasPoint = true
                        } else {
                            maPath.addLine(to: pt)
                        }
                    }

                    if hasPoint {
                        let amber = Color(red: 0.88, green: 0.50, blue: 0.05)
                        context.stroke(maPath, with: .color(amber), style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round))
                    }
                }
            } else {
                Capsule().fill(DS.cardAlt).frame(height: 2)
            }
        }
        .frame(width: width, height: height)
        .help(tooltipText)
        .task(id: symbol) {
            let s = StockService.shared
            if !s.isJapaneseMutualFund(symbol) && (s.priceHistory[symbol]?.contains(where: { ($0.volume ?? 0) > 0 }) != true) {
                await s.ensurePriceHistory(for: symbol)
            }
        }
    }
}

/// Floating chart tooltip capable of displaying both price snapshot and matched insider trading events.
struct ChartTooltipWithInsider: View {
    let title: String
    let value: String
    let tint: Color
    var insiderTrade: PriceChartCard.GroupedInsiderTrade? = nil
    var symbol: String = ""

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
                    let isVi = StorageService.shared.appLanguage.lowercased() == "vi"
                    Text(trade.isBuy ? (isVi ? "MUA" : "BUY") : (isVi ? "BÁN" : "SELL"))
                        .font(.inter(9, weight: .bold, relativeTo: .caption2))
                        .foregroundStyle(trade.isBuy ? DS.up : DS.down)

                    if trade.isRule10b51 {
                        Text("10b5-1")
                            .font(.inter(8, weight: .bold, relativeTo: .caption2))
                            .foregroundStyle(DS.brand)
                            .padding(.horizontal, 3.5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(DS.brand.opacity(0.12)))
                    }

                    let valStr = formatTradeValue(trade.totalValue)
                    if trade.count > 1 {
                        Text(isVi ? "\(trade.count) lệnh: \(valStr)" : "\(trade.count) Trades: \(valStr)")
                            .font(.inter(10, weight: .medium, relativeTo: .caption2))
                            .foregroundStyle(DS.ink)
                            .lineLimit(1)
                    } else {
                        Text("\(trade.primaryOwner): \(valStr)")
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

    private func formatTradeValue(_ val: Double) -> String {
        guard val > 0 else { return "—" }
        let isVN = InsiderTradingService.shared.market(for: symbol) == .vn
        if isVN {
            let ty = val / 1_000_000_000.0
            if ty >= 1000.0 {
                return String(format: "%.1fK tỷ ₫", ty / 1000.0)
            } else if ty >= 1.0 {
                let formatter = NumberFormatter()
                formatter.numberStyle = .decimal
                formatter.groupingSeparator = "."
                formatter.maximumFractionDigits = ty >= 100 ? 0 : 1
                let formatted = formatter.string(from: NSNumber(value: ty)) ?? String(format: "%.1f", ty)
                return "\(formatted) tỷ ₫"
            } else if val >= 1_000_000.0 {
                let tr = val / 1_000_000.0
                return String(format: "%.0f tr ₫", tr)
            }
            return "\(Int(val)) ₫"
        } else {
            let absVal = abs(val)
            if absVal >= 1_000_000_000 {
                return "$\(String(format: "%.2fB", absVal / 1_000_000_000))"
            } else if absVal >= 1_000_000 {
                return "$\(String(format: "%.1fM", absVal / 1_000_000))"
            } else if absVal >= 1_000 {
                return "$\(String(format: "%.0fK", absVal / 1_000))"
            }
            return "$\(String(format: "%.0f", absVal))"
        }
    }
}

/// Pointer state stays here: moving the mouse does not invalidate the price
/// card, filter history again, or rebuild the underlying chart marks.
private struct PriceChartCrosshair: View {
    let proxy: ChartProxy
    let tint: Color
    let currentHistory: [PricePoint]
    let chartRange: PriceChartCard.ChartRange
    let cachedGroupedTrades: [PriceChartCard.GroupedInsiderTrade]
    let symbol: String
    let priceSymbol: String
    let valueDecimals: Int
    @State private var hoverPoint: PricePoint?

    private func hoverLabel(_ date: Date) -> String {
        chartRange.isIntraday ? date.formatted(.dateTime.hour().minute())
                              : date.formatted(date: .abbreviated, time: .omitted)
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
                                    let next = PriceHistory.nearestPoint(to: d, in: currentHistory)
                                    if next != hoverPoint { hoverPoint = next }
                                }
                            case .ended:
                                hoverPoint = nil
                            }
                        }
                    if let h = hoverPoint,
                       let px = proxy.position(forX: h.date),
                       let py = proxy.position(forY: h.close) {
                        let cx = plot.minX + px
                        let dec = valueDecimals >= 0 ? valueDecimals : StorageService.priceDecimals(symbol: symbol, price: h.close)
                        let matchedInsider = cachedGroupedTrades.first(where: {
                            let diff = abs($0.date.timeIntervalSince(h.date))
                            switch chartRange {
                            case .month, .threeMonths:
                                return Calendar.current.isDate($0.date, inSameDayAs: h.date)
                            case .sixMonths, .ytd, .year:
                                return diff < 86400 * 4
                            case .threeYears, .fiveYears, .sevenYears, .tenYears, .all:
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
                                                    insiderTrade: matchedInsider,
                                                    symbol: symbol)
                                .position(x: min(max(cx, plot.minX + 60), plot.maxX - 60), y: plot.minY + (matchedInsider != nil ? 20 : 12))
                        }
                        .allowsHitTesting(false)
                    }
                }
            }
        }
    }
}

/// Chart marks depend only on chart inputs. Unrelated quote/news updates from
/// the surrounding detail page cannot rebuild this expensive drawing subtree.
private struct PriceChartPlot: View, Equatable {
    let currentHistory: [PricePoint]
    let chartRange: PriceChartCard.ChartRange
    let cachedGroupedTrades: [PriceChartCard.GroupedInsiderTrade]
    let showInsiderMarkers: Bool
    let buyTarget: StockTarget?
    let symbol: String
    let priceSymbol: String
    let valueDecimals: Int
    let domain: ClosedRange<Double>
    let isLoadingCurrent: Bool

    /// X-axis tick label, formatted for the selected period.
    private func xAxisLabel(_ date: Date) -> String {
        switch chartRange {
        case .month, .threeMonths, .sixMonths, .ytd:
            return date.formatted(.dateTime.day().month(.abbreviated))
        case .year, .threeYears, .fiveYears:
            return date.formatted(.dateTime.month(.abbreviated).year(.twoDigits))
        case .sevenYears, .tenYears, .all:
            return date.formatted(.dateTime.year())
        }
    }

    @ViewBuilder var body: some View {
        if currentHistory.count >= 2 {
            let periodUp = (currentHistory.last?.close ?? 0) >= (currentHistory.first?.close ?? 0)
            let tint = periodUp ? DS.up : DS.down
            Chart {
                ForEach(currentHistory) { point in
                    AreaMark(x: .value("Day", point.date), y: .value("Close", point.close))
                        .foregroundStyle(.linearGradient(colors: [tint.opacity(0.25), tint.opacity(0)],
                                                         startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("Day", point.date), y: .value("Close", point.close))
                        .foregroundStyle(tint).lineStyle(.init(lineWidth: 2))
                        .interpolationMethod(.monotone)
                }
                if let last = currentHistory.last {
                    PointMark(x: .value("Day", last.date), y: .value("Close", last.close))
                        .symbolSize(50)
                        .foregroundStyle(tint)
                }
                if showInsiderMarkers {
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
                if let buyTarget {
                    RuleMark(y: .value("Buy Target", buyTarget.targetPrice))
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
                        .foregroundStyle(DS.up)
                        .annotation(position: .top, alignment: .trailing) {
                            HStack(spacing: 3) {
                                Text("🎯 Buy")
                                    .font(.system(size: 8, weight: .bold))
                                Text("\(priceSymbol)\(StorageService.formatCompactNumber(buyTarget.targetPrice, decimals: (valueDecimals >= 0 ? valueDecimals : StorageService.priceDecimals(symbol: symbol, price: buyTarget.targetPrice))))")
                                    .font(.inter(8.5, weight: .semibold, relativeTo: .caption2).monospacedDigit())
                            }
                            .foregroundStyle(DS.up)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(DS.cardAlt.opacity(0.92))
                                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(DS.up.opacity(0.4), lineWidth: 0.5))
                            )
                        }
                }
            }
            .chartYScale(domain: domain)
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
            .chartOverlay { proxy in
                PriceChartCrosshair(proxy: proxy, tint: tint, currentHistory: currentHistory,
                                    chartRange: chartRange, cachedGroupedTrades: cachedGroupedTrades,
                                    symbol: symbol, priceSymbol: priceSymbol,
                                    valueDecimals: valueDecimals)
                    .id("\(symbol)-\(chartRange.rawValue)")
            }
            .id("\(symbol)-\(chartRange.rawValue)")
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

}
