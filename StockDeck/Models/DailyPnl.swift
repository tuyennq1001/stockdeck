import Foundation

/// One day's P&L in the preferred currency, computed from real cost basis —
/// the daily counterpart of `MonthlyPnl`. `pnl` is the profit/loss realized
/// *during* that day (cumulative P&L minus the day before); `pnlPercent` is
/// that amount relative to the position value at the start of the day.
struct DailyPnlRow: Identifiable, Equatable {
    let date: Date
    let label: String
    let pnl: Double?            // Net total PnL = unrealized + realized
    let unrealizedPnl: Double?  // Open positions mark-to-market delta
    let realizedPnl: Double?    // Closed trades executed on this day
    let pnlPercent: Double?

    var id: Date { date }

    init(date: Date,
         label: String,
         pnl: Double?,
         unrealizedPnl: Double? = nil,
         realizedPnl: Double? = nil,
         pnlPercent: Double?) {
        self.date = date
        self.label = label
        self.pnl = pnl
        self.unrealizedPnl = unrealizedPnl
        self.realizedPnl = realizedPnl
        self.pnlPercent = pnlPercent
    }
}

/// Builds a per-day P&L table from current holdings × real price history,
/// combined with realized P&L from closed trades on their sell dates.
///
/// Exactly like `MonthlyPnl`, but bucketed by calendar day instead of month:
/// for every day in the window it computes the cumulative P&L of the held
/// positions (each lot: `(price − avgPrice) / scale × qty × leverage × FX`).
/// A day's own P&L is the difference between the cumulative P&L at the end of
/// that day and the day before, plus any realized profit/loss from trades
/// closed on that day.
enum DailyPnl {
    static let defaultDayCount = 365

    private static func makeDayFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d"
        return formatter
    }

    private static func realizedForDay(
        _ trades: [ClosedTrade]?,
        rateBySymbol: [String: Double]
    ) -> (realized: Double, costBasis: Double, hasRealized: Bool) {
        guard let trades, !trades.isEmpty else { return (0, 0, false) }
        var realized = 0.0
        var costBasis = 0.0
        for ct in trades {
            let rate = rateBySymbol[ct.symbol].flatMap { $0.isFinite ? $0 : nil } ?? 1.0
            realized += ct.realizedPnl * rate
            costBasis += ct.costBasis * rate
        }
        return (realized, costBasis, true)
    }

    private static func makeTodayRow(
        day: Date,
        label: String,
        summary: TodayPerformance.Summary,
        closedTradesForToday: [ClosedTrade]?,
        rateBySymbol: [String: Double]
    ) -> DailyPnlRow {
        let realizedStats = realizedForDay(closedTradesForToday, rateBySymbol: rateBySymbol)
        let totalPnl = summary.gain + realizedStats.realized
        let prevTotalValue = summary.previousCloseValue + realizedStats.costBasis
        let pct: Double? = abs(prevTotalValue) >= 0.01 ? totalPnl / abs(prevTotalValue) * 100 : nil
        return DailyPnlRow(
            date: day,
            label: label,
            pnl: totalPnl,
            unrealizedPnl: summary.gain,
            realizedPnl: realizedStats.hasRealized ? realizedStats.realized : nil,
            pnlPercent: pct
        )
    }

    static func rows(holdings: [Holding],
                     closedTrades: [ClosedTrade] = [],
                     historyBySymbol: [String: [PricePoint]],
                     rateBySymbol: [String: Double],
                     todaySummary: TodayPerformance.Summary? = nil,
                     today: Date = Date(),
                     calendar: Calendar = .current,
                     dayCount: Int = defaultDayCount) -> [DailyPnlRow] {
        guard (!holdings.isEmpty || !closedTrades.isEmpty), dayCount > 0 else { return [] }

        // Newest-first list of calendar-day starts covering the window.
        let todayStart = calendar.startOfDay(for: today)
        let days: [Date] = (0..<dayCount).compactMap {
            calendar.date(byAdding: .day, value: -$0, to: todayStart)
        }

        func endOfDay(_ start: Date) -> Date {
            calendar.date(byAdding: .day, value: 1, to: start) ?? start
        }

        // Price of a symbol at (or just after) the end of the day, from its
        // price history. Returns nil when the series has nothing in range.
        func price(atDayStart start: Date, for symbol: String) -> Double? {
            guard let points = historyBySymbol[symbol], !points.isEmpty else { return nil }
            let end = endOfDay(start)
            guard let point = points.last(where: { $0.date < end }),
                  point.close.isFinite, point.close > 0 else { return nil }
            return point.close
        }

        // Group closed trades by calendar day start
        var closedTradesByDay: [Date: [ClosedTrade]] = [:]
        for trade in closedTrades {
            guard let sellDate = trade.sellDate else { continue }
            let dayStart = calendar.startOfDay(for: sellDate)
            closedTradesByDay[dayStart, default: []].append(trade)
        }

        // Holdings without a known purchase date (e.g. Binance balances synced
        // without cost basis) are anchored to the earliest known purchase date
        // of the portfolio, so their price history doesn't fabricate P&L for
        // days before the owner actually held anything.
        let earliestKnownPurchase = (holdings.compactMap(\.purchaseDate) + closedTrades.compactMap(\.buyDate)).min()

        var cumulativePnl: [Date: Double] = [:]
        var cumulativeValue: [Date: Double] = [:]
        var hasData: [Date: Bool] = [:]

        for day in days {
            let end = endOfDay(day)
            var pnl = 0.0
            var value = 0.0
            var anyData = !(closedTradesByDay[day]?.isEmpty ?? true) || (day == todayStart && todaySummary != nil)
            for h in holdings {
                let ownedFrom = h.purchaseDate ?? earliestKnownPurchase
                if let ownedFrom, ownedFrom > end { continue }
                guard let price = price(atDayStart: day, for: h.symbol) else { continue }
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
            cumulativePnl[day] = pnl
            cumulativeValue[day] = value
            hasData[day] = anyData
        }

        // Trim the oldest days that carry no data at all, so the chart starts
        // at the first day that actually has prices or closed trades for held positions.
        guard let oldestDataIndex = days.lastIndex(where: { hasData[$0] ?? false }) else {
            return []
        }
        let keptDays = Array(days[0...oldestDataIndex])

        // The oldest day has no previous day to diff against. Using its full
        // cumulative P&L as a "day P&L" spikes the first bar (the position's
        // entire gain since purchase piles onto one day), so we rebase it
        // against the actual price that preceded the day in the real history.
        // When even that isn't available the day is skipped entirely.
        let formatter = makeDayFormatter()

        var result: [DailyPnlRow] = []
        for (index, day) in keptDays.enumerated() {
            let label = formatter.string(from: day)
            if day == todayStart, let todaySummary {
                result.append(makeTodayRow(
                    day: day,
                    label: label,
                    summary: todaySummary,
                    closedTradesForToday: closedTradesByDay[day],
                    rateBySymbol: rateBySymbol
                ))
                continue
            }

            var own: Double = 0
            var prevTotalValue: Double = 0
            
            let prevDay = index < keptDays.count - 1 ? keptDays[index + 1] : nil
            
            for h in holdings {
                let ownedFrom = h.purchaseDate ?? earliestKnownPurchase
                if let ownedFrom, ownedFrom > endOfDay(day) { continue }
                
                guard let priceToday = price(atDayStart: day, for: h.symbol) else { continue }
                let scale = h.isJapaneseFund ? 10000.0 : 1.0
                let rate = rateBySymbol[h.symbol].flatMap { $0.isFinite ? $0 : nil } ?? 1.0
                let qty = h.quantity.isFinite ? h.quantity : 0
                let lev = h.effectiveLeverage.isFinite ? h.effectiveLeverage : 1
                let pricePerUnitToday = priceToday / scale
                
                var pricePerUnitPrev: Double? = nil
                var wasOwnedPrev = false
                
                if let prevDay {
                    let prevEnd = endOfDay(prevDay)
                    if let ownedFrom, ownedFrom > prevEnd {
                        wasOwnedPrev = false
                    } else {
                        wasOwnedPrev = true
                        if let p = price(atDayStart: prevDay, for: h.symbol) {
                            pricePerUnitPrev = p / scale
                        }
                    }
                } else {
                    let startInstant = day.addingTimeInterval(1)
                    if let ownedFrom, ownedFrom >= startInstant {
                        wasOwnedPrev = false
                    } else {
                        wasOwnedPrev = true
                        if let points = historyBySymbol[h.symbol],
                           let point = points.last(where: { $0.date < startInstant }),
                           point.close.isFinite, point.close > 0 {
                            pricePerUnitPrev = point.close / scale
                        }
                    }
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
            
            let realizedStats = realizedForDay(closedTradesByDay[day], rateBySymbol: rateBySymbol)
            prevTotalValue += realizedStats.costBasis
            let totalPnl = own + realizedStats.realized
            let pct: Double? = abs(prevTotalValue) >= 0.01 ? totalPnl / abs(prevTotalValue) * 100 : nil
            result.append(DailyPnlRow(
                date: day,
                label: label,
                pnl: totalPnl,
                unrealizedPnl: own,
                realizedPnl: realizedStats.hasRealized ? realizedStats.realized : nil,
                pnlPercent: pct
            ))
        }
        return result
    }

    static func updatingTodayRow(
        in rows: [DailyPnlRow],
        with todaySummary: TodayPerformance.Summary,
        closedTrades: [ClosedTrade] = [],
        rateBySymbol: [String: Double] = [:],
        today: Date = Date(),
        calendar: Calendar = .current
    ) -> [DailyPnlRow] {
        let todayStart = calendar.startOfDay(for: today)
        let todayClosed = closedTrades.filter { trade in
            guard let sellDate = trade.sellDate else { return false }
            return calendar.isDate(sellDate, inSameDayAs: todayStart)
        }
        let formatter = makeDayFormatter()
        let updatedToday = makeTodayRow(
            day: todayStart,
            label: formatter.string(from: todayStart),
            summary: todaySummary,
            closedTradesForToday: todayClosed,
            rateBySymbol: rateBySymbol
        )
        var out = rows
        if let first = out.first, calendar.isDate(first.date, inSameDayAs: todayStart) {
            if first == updatedToday { return rows }
            out[0] = updatedToday
        } else {
            out.insert(updatedToday, at: 0)
        }
        return out
    }
}
