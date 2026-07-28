import Foundation

/// A reconstructed point on the estimated portfolio value curve.
struct ValuePoint: Identifiable, Equatable {
    let date: Date
    let value: Double
    var id: Date { date }
}

/// Estimates a past portfolio-value curve from each holding's real daily price
/// history times the *current* position — so the Overview chart shows a trend on
/// day one, before real daily snapshots accumulate.
///
/// This is explicitly an estimate (labelled as such in the UI): it assumes the
/// current holdings were held over the whole window and uses the current FX rate.
/// Real snapshots, once present, take precedence.
enum PortfolioBackfill {
    static func series(holdings: [Holding],
                       historyBySymbol: [String: [PricePoint]],
                       rateBySymbol: [String: Double]) -> [ValuePoint] {
        guard !holdings.isEmpty else { return [] }

        // Filter holdings to those that have price history data
        let validHoldings = holdings.filter { !(historyBySymbol[$0.symbol]?.isEmpty ?? true) }
        guard !validHoldings.isEmpty else { return [] }

        // Collect all unique timestamps across valid holdings
        var allDatesSet = Set<Date>()
        for h in validHoldings {
            if let points = historyBySymbol[h.symbol] {
                for p in points {
                    allDatesSet.insert(p.date)
                }
            }
        }
        let sortedDates = allDatesSet.sorted()
        guard !sortedDates.isEmpty else { return [] }

        // Build sorted (date, price) array per symbol
        var symbolHistory: [String: [(date: Date, price: Double)]] = [:]
        for h in validHoldings {
            if let points = historyBySymbol[h.symbol] {
                symbolHistory[h.symbol] = points.map { ($0.date, $0.close) }.sorted(by: { $0.date < $1.date })
            }
        }

        // Initialize forward-fill prices with first available price for each symbol
        var lastPrice: [String: Double] = [:]
        var historyIndex: [String: Int] = [:]
        for h in validHoldings {
            if let firstP = symbolHistory[h.symbol]?.first {
                lastPrice[h.symbol] = firstP.price
                historyIndex[h.symbol] = 0
            }
        }

        var result: [ValuePoint] = []
        result.reserveCapacity(sortedDates.count)

        for date in sortedDates {
            for h in validHoldings {
                guard let points = symbolHistory[h.symbol] else { continue }
                var idx = historyIndex[h.symbol] ?? 0
                while idx < points.count && points[idx].date <= date {
                    lastPrice[h.symbol] = points[idx].price
                    idx += 1
                }
                historyIndex[h.symbol] = idx
            }

            var total = 0.0
            for h in validHoldings {
                let price = lastPrice[h.symbol] ?? 0
                let rate = rateBySymbol[h.symbol] ?? 1
                total += price * h.quantity * h.effectiveLeverage * rate
            }
            result.append(ValuePoint(date: date, value: total))
        }

        return result
    }
}

/// Change of a drawn value curve over its own span — the delta between its first
/// and last points. Drives the hero pill so it reflects the *selected* period
/// (24H/7D/1M/…) instead of always showing the day-over-day change.
enum PortfolioPeriodChange {
    /// Absolute change (last − first) over the series, or nil if under 2 points.
    static func value(_ points: [ValuePoint]) -> Double? {
        guard let first = points.first?.value, let last = points.last?.value,
              points.count >= 2 else { return nil }
        return last - first
    }

    /// Percentage change vs the first point, or nil if the span is degenerate
    /// (fewer than 2 points, or a starting value too close to zero to divide by).
    static func percent(_ points: [ValuePoint]) -> Double? {
        guard let first = points.first?.value, let last = points.last?.value,
              points.count >= 2, abs(first) >= 0.01 else { return nil }
        return (last - first) / abs(first) * 100
    }
}
