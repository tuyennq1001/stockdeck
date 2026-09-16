import Foundation

/// One month's P&L in the preferred currency, computed from real cost basis —
/// not from value snapshots, so adding cash or positions never fabricates profit.
/// `pnl` is the profit/loss realized in that specific month; `pnlPercent` is that
/// amount relative to the position value at the start of the month.
struct MonthlyPnlRow: Identifiable, Equatable {
    let monthStart: Date
    let label: String
    let pnl: Double?            // Net total PnL = unrealized + realized
    let unrealizedPnl: Double?  // Open positions mark-to-market delta
    let realizedPnl: Double?    // Closed trades executed in this month
    let pnlPercent: Double?

    var id: Date { monthStart }

    init(monthStart: Date,
         label: String,
         pnl: Double?,
         unrealizedPnl: Double? = nil,
         realizedPnl: Double? = nil,
         pnlPercent: Double?) {
        self.monthStart = monthStart
        self.label = label
        self.pnl = pnl
        self.unrealizedPnl = unrealizedPnl
        self.realizedPnl = realizedPnl
        self.pnlPercent = pnlPercent
    }
}

/// Builds a per-month P&L table from current holdings × real price history,
/// combined with realized P&L from closed trades on their sell dates.
///
/// For every month in the window it computes the cumulative P&L of the held
/// positions (each lot: `(price − avgPrice) / scale × qty × leverage × FX`,
/// exactly like `Holding.pnl`). A month's own P&L is the difference between the
/// cumulative P&L at the end of that month and the month before — i.e. the
/// profit realized *during* the month, plus realized profit/loss from trades
/// closed in that month.
enum MonthlyPnl {
    static let defaultMonthCount = 12

    /// Number of whole months of history available across all symbols, capped
    /// at `maxMonths`. Used to extend the window beyond the default 12 when the
    /// price history actually covers it.
    static func monthCount(for historyBySymbol: [String: [PricePoint]],
                           today: Date = Date(),
                           calendar: Calendar = .current,
                           maxMonths: Int = 36) -> Int {
        let earliest = historyBySymbol.values
            .flatMap { $0 }
            .map(\.date)
            .min()
        guard let earliest else { return defaultMonthCount }
        guard earliest < today else { return defaultMonthCount }
        let components = calendar.dateComponents([.month], from: earliest, to: today)
        let span = (components.month ?? 0) + 1
        return min(max(span, 1), maxMonths)
    }

    static func rows(holdings: [Holding],
                     closedTrades: [ClosedTrade] = [],
                     historyBySymbol: [String: [PricePoint]],
                     rateBySymbol: [String: Double],
                     today: Date = Date(),
                     calendar: Calendar = .current,
                     monthCount: Int = defaultMonthCount) -> [MonthlyPnlRow] {
        guard (!holdings.isEmpty || !closedTrades.isEmpty) else { return [] }

        // Newest-first list of month starts covering the window.
        let months: [Date] = {
            let current = calendar.dateInterval(of: .month, for: today)?.start
                ?? calendar.startOfDay(for: today)
            return (0..<monthCount).compactMap {
                calendar.date(byAdding: .month, value: -$0, to: current)
            }
        }()

        // End of each month = start of the following month.
        func endOfMonth(_ start: Date) -> Date {
            calendar.date(byAdding: .month, value: 1, to: start) ?? start
        }

        // Price of a symbol at (or just after) the end of the month, from its
        // price history. Returns nil when the series has nothing in range.
        func price(atMonthStart start: Date, for symbol: String) -> Double? {
            guard let points = historyBySymbol[symbol], !points.isEmpty else { return nil }
            let end = endOfMonth(start)
            guard let point = points.last(where: { $0.date < end }),
                  point.close.isFinite, point.close > 0 else { return nil }
            return point.close
        }

        // Group closed trades by month start
        func monthStart(for date: Date) -> Date {
            calendar.dateInterval(of: .month, for: date)?.start ?? calendar.startOfDay(for: date)
        }
        var closedTradesByMonth: [Date: [ClosedTrade]] = [:]
        for trade in closedTrades {
            guard let sellDate = trade.sellDate else { continue }
            let mStart = monthStart(for: sellDate)
            closedTradesByMonth[mStart, default: []].append(trade)
        }

        // Holdings without a known purchase date (e.g. Binance balances synced
        // without cost basis) are anchored to the earliest known purchase date
        // of the portfolio, so their price history doesn't fabricate P&L for
        // months before the owner actually held anything.
        let earliestKnownPurchase = (holdings.compactMap(\.purchaseDate) + closedTrades.compactMap(\.buyDate)).min()

        var cumulativePnl: [Date: Double] = [:]
        var cumulativeValue: [Date: Double] = [:]
        var hasData: [Date: Bool] = [:]

        for month in months {
            let end = endOfMonth(month)
            var pnl = 0.0
            var value = 0.0
            var anyData = !(closedTradesByMonth[month]?.isEmpty ?? true)
            for h in holdings {
                let ownedFrom = h.purchaseDate ?? earliestKnownPurchase
                if let ownedFrom, ownedFrom > end { continue }
                guard let price = price(atMonthStart: month, for: h.symbol) else { continue }
                let scale = h.isJapaneseFund ? 10000.0 : 1.0
                let rate = rateBySymbol[h.symbol].flatMap { $0.isFinite ? $0 : nil } ?? 1.0
                let qty = h.quantity.isFinite ? h.quantity : 0
                let lev = h.effectiveLeverage.isFinite ? h.effectiveLeverage : 1
                let pricePerUnit = price / scale
                value += pricePerUnit * qty * lev * rate
                anyData = true
                if h.hasKnownCostBasis {
                    pnl += ((pricePerUnit - h.avgPrice / scale) * qty * lev * rate)
                }
            }
            cumulativePnl[month] = pnl
            cumulativeValue[month] = value
            hasData[month] = anyData
        }

        // Trim the oldest months that carry no data at all, so the chart starts
        // at the first month that actually has prices or closed trades for held positions.
        guard let oldestDataIndex = months.lastIndex(where: { hasData[$0] ?? false }) else {
            return []
        }
        let keptMonths = Array(months[0...oldestDataIndex])

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM yyyy"

        var result: [MonthlyPnlRow] = []
        for (index, month) in keptMonths.enumerated() {
            var own: Double = 0
            var prevTotalValue: Double = 0
            
            let prevMonth = index < keptMonths.count - 1 ? keptMonths[index + 1] : nil
            
            for h in holdings {
                let ownedFrom = h.purchaseDate ?? earliestKnownPurchase
                if let ownedFrom, ownedFrom > endOfMonth(month) { continue }
                
                guard let priceToday = price(atMonthStart: month, for: h.symbol) else { continue }
                let scale = h.isJapaneseFund ? 10000.0 : 1.0
                let rate = rateBySymbol[h.symbol].flatMap { $0.isFinite ? $0 : nil } ?? 1.0
                let qty = h.quantity.isFinite ? h.quantity : 0
                let lev = h.effectiveLeverage.isFinite ? h.effectiveLeverage : 1
                let pricePerUnitToday = priceToday / scale
                
                var pricePerUnitPrev: Double? = nil
                var wasOwnedPrev = false
                
                if let prevMonth {
                    let prevEnd = endOfMonth(prevMonth)
                    if let ownedFrom, ownedFrom > prevEnd {
                        wasOwnedPrev = false
                    } else {
                        wasOwnedPrev = true
                        if let p = price(atMonthStart: prevMonth, for: h.symbol) {
                            pricePerUnitPrev = p / scale
                        }
                    }
                } else {
                    // Oldest month with data: no prior month to diff against, so
                    // show its cumulative P&L rather than inventing a delta.
                    wasOwnedPrev = false
                }
                
                if wasOwnedPrev {
                    if let prev = pricePerUnitPrev {
                        own += (pricePerUnitToday - prev) * qty * lev * rate
                        prevTotalValue += prev * qty * lev * rate
                    }
                } else {
                    if h.hasKnownCostBasis {
                        own += (pricePerUnitToday - (h.avgPrice / scale)) * qty * lev * rate
                        prevTotalValue += (h.avgPrice / scale) * qty * lev * rate
                    }
                }
            }
            
            var realizedThisMonth = 0.0
            var hasRealized = false
            if let trades = closedTradesByMonth[month] {
                for ct in trades {
                    let rate = rateBySymbol[ct.symbol].flatMap { $0.isFinite ? $0 : nil } ?? 1.0
                    realizedThisMonth += ct.realizedPnl * rate
                    hasRealized = true
                    prevTotalValue += ct.costBasis * rate
                }
            }
            
            let totalMonthPnl = own + realizedThisMonth
            let pct: Double? = {
                if prevMonth == nil {
                    // Oldest month shows cumulative P&L but suppresses the percentage
                    // because it would represent lifetime return, not a month's return.
                    return nil
                }
                return abs(prevTotalValue) >= 0.01 ? totalMonthPnl / abs(prevTotalValue) * 100 : nil
            }()
            result.append(MonthlyPnlRow(
                monthStart: month,
                label: formatter.string(from: month),
                pnl: totalMonthPnl,
                unrealizedPnl: own,
                realizedPnl: hasRealized ? realizedThisMonth : nil,
                pnlPercent: pct
            ))
        }
        return result
    }
}
