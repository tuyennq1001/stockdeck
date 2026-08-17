import Foundation

/// One day's P&L in the preferred currency, computed from real cost basis —
/// the daily counterpart of `MonthlyPnl`. `pnl` is the profit/loss realized
/// *during* that day (cumulative P&L minus the day before); `pnlPercent` is
/// that amount relative to the position value at the start of the day.
struct DailyPnlRow: Identifiable, Equatable {
    let date: Date
    let label: String
    let pnl: Double?
    let pnlPercent: Double?

    var id: Date { date }
}

/// Builds a per-day P&L table from current holdings × real price history.
///
/// Exactly like `MonthlyPnl`, but bucketed by calendar day instead of month:
/// for every day in the window it computes the cumulative P&L of the held
/// positions (each lot: `(price − avgPrice) / scale × qty × leverage × FX`).
/// A day's own P&L is the difference between the cumulative P&L at the end of
/// that day and the day before. Holdings purchased after a day are excluded
/// from it, and a day without a price for a symbol simply omits that holding
/// (no fabricated numbers). Days without any tradable data are trimmed so the
/// chart starts at the first day that actually has prices.
enum DailyPnl {
    static let defaultDayCount = 365

    static func rows(holdings: [Holding],
                     historyBySymbol: [String: [PricePoint]],
                     rateBySymbol: [String: Double],
                     today: Date = Date(),
                     calendar: Calendar = .current,
                     dayCount: Int = defaultDayCount) -> [DailyPnlRow] {
        guard !holdings.isEmpty, dayCount > 0 else { return [] }

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
            let end = endOfDay(start).addingTimeInterval(7 * 86400)
            guard let point = points.last(where: { $0.date <= end }),
                  point.close.isFinite, point.close > 0 else { return nil }
            return point.close
        }

        // Holdings without a known purchase date (e.g. Binance balances synced
        // without cost basis) are anchored to the earliest known purchase date
        // of the portfolio, so their price history doesn't fabricate P&L for
        // days before the owner actually held anything.
        let earliestKnownPurchase = holdings.compactMap(\.purchaseDate).min()

        var cumulativePnl: [Date: Double] = [:]
        var cumulativeValue: [Date: Double] = [:]
        var hasData: [Date: Bool] = [:]

        for day in days {
            let end = endOfDay(day)
            var pnl = 0.0
            var value = 0.0
            var anyData = false
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
        // at the first day that actually has prices for held positions.
        guard let oldestDataIndex = days.lastIndex(where: { hasData[$0] ?? false }) else {
            return []
        }
        let keptDays = Array(days[0...oldestDataIndex])

        // The oldest day has no previous day to diff against. Using its full
        // cumulative P&L as a "day P&L" spikes the first bar (the position's
        // entire gain since purchase piles onto one day), so we rebase it
        // against the actual price that preceded the day in the real history.
        // When even that isn't available the day is skipped entirely.
        func baselinePnl(for day: Date) -> (pnl: Double, value: Double)? {
            let startInstant = day.addingTimeInterval(1)
            var pnl = 0.0
            var value = 0.0
            var any = false
            for h in holdings {
                let ownedFrom = h.purchaseDate ?? earliestKnownPurchase
                if let ownedFrom, ownedFrom >= startInstant { continue }
                let scale = h.isJapaneseFund ? 10000.0 : 1.0
                let rate = rateBySymbol[h.symbol].flatMap { $0.isFinite ? $0 : nil } ?? 1.0
                let qty = h.quantity.isFinite ? h.quantity : 0
                let lev = h.effectiveLeverage.isFinite ? h.effectiveLeverage : 1
                guard let points = historyBySymbol[h.symbol],
                      let point = points.last(where: { $0.date < startInstant }),
                      point.close.isFinite, point.close > 0 else { continue }
                let pricePerUnit = point.close / scale
                value += pricePerUnit * qty * lev * rate
                if h.hasKnownCostBasis {
                    pnl += ((pricePerUnit - h.avgPrice / scale) * qty * lev * rate)
                }
                any = true
            }
            guard any else { return nil }
            return (pnl, value)
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d"

        var result: [DailyPnlRow] = []
        for (index, day) in keptDays.enumerated() {
            let pnl = cumulativePnl[day] ?? 0
            if index == keptDays.count - 1 {
                // Oldest day: diff against the real preceding price instead of
                // dumping the whole cumulative P&L onto one day.
                guard let baseline = baselinePnl(for: day) else { continue }
                let own = pnl - baseline.pnl
                let pct: Double? = abs(baseline.value) >= 0.01 ? own / abs(baseline.value) * 100 : nil
                result.append(DailyPnlRow(date: day, label: formatter.string(from: day), pnl: own, pnlPercent: pct))
                continue
            }
            let prev = keptDays[index + 1]
            let own = pnl - (cumulativePnl[prev] ?? 0)
            let pct: Double? = {
                let prevValue = cumulativeValue[keptDays[index + 1]] ?? 0
                guard abs(prevValue) >= 0.01 else { return nil }
                return own / abs(prevValue) * 100
            }()
            result.append(DailyPnlRow(date: day, label: formatter.string(from: day), pnl: own, pnlPercent: pct))
        }
        return result
    }
}
