import Foundation

/// A price point (closing or full OHLC bar) for detail charts.
struct PricePoint: Identifiable, Equatable, Codable {
    let date: Date
    let close: Double
    let open: Double?
    let high: Double?
    let low: Double?
    var id: Date { date }

    init(date: Date, close: Double, open: Double? = nil, high: Double? = nil, low: Double? = nil) {
        self.date = date
        self.close = close
        self.open = open
        self.high = high
        self.low = low
    }

    var effectiveOpen: Double { open ?? close }
    var effectiveHigh: Double { max(high ?? close, max(effectiveOpen, close)) }
    var effectiveLow: Double { min(low ?? close, min(effectiveOpen, close)) }
}

/// Pure transforms over Yahoo v8 chart arrays.
enum PriceHistory {
    /// Pairs the v8 chart `timestamp` array with OHLC arrays into
    /// chronological price points, skipping nil holes.
    static func points(timestamps: [Int], closes: [Double?], opens: [Double?]? = nil, highs: [Double?]? = nil, lows: [Double?]? = nil) -> [PricePoint] {
        let count = timestamps.count
        var result: [PricePoint] = []
        result.reserveCapacity(count)

        let opensArr = opens ?? []
        let highsArr = highs ?? []
        let lowsArr = lows ?? []

        for i in 0..<count {
            guard i < closes.count, let close = closes[i] else { continue }
            let ts = timestamps[i]
            let date = Date(timeIntervalSince1970: TimeInterval(ts))
            let open = i < opensArr.count ? opensArr[i] : nil
            let high = i < highsArr.count ? highsArr[i] : nil
            let low = i < lowsArr.count ? lowsArr[i] : nil

            result.append(PricePoint(date: date, close: close, open: open, high: high, low: low))
        }

        return result.sorted { $0.date < $1.date }
    }

    /// Percentage move from the market close at (or immediately before) a
    /// requested boundary to the current regular-session price. Falling back to
    /// the first close after the boundary handles newly listed instruments.
    static func percentChange(points: [PricePoint], currentPrice: Double, since boundary: Date) -> Double? {
        guard currentPrice.isFinite, currentPrice > 0, !points.isEmpty else { return nil }
        var low = 0
        var high = points.count - 1
        var baselineIdx: Int? = nil

        while low <= high {
            let mid = low + (high - low) / 2
            if points[mid].date <= boundary {
                baselineIdx = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }

        let baseline = baselineIdx.map { points[$0] } ?? points.first
        guard let baseline, baseline.close.isFinite, baseline.close > 0 else { return nil }
        return (currentPrice - baseline.close) / baseline.close * 100
    }

    /// Resamples a daily (or finer) close series into one point per calendar
    /// month — the last close of the month, dated at the month's start. This is
    /// the same shape Yahoo's `interval=1mo` bars produce, so the full-history
    /// series used by the "All" / 3Y / 5Y chart ranges and the long performance
    /// periods can be derived locally from the 10-year daily series instead of
    /// issuing a second network request.
    static func deriveMonthly(from daily: [PricePoint], calendar: Calendar = .current) -> [PricePoint] {
        let sorted = daily.sorted { $0.date < $1.date }
        var lastCloseByMonth: [Date: Double] = [:]
        for p in sorted where p.close.isFinite {
            let monthStart = calendar.dateInterval(of: .month, for: p.date)?.start
                ?? calendar.startOfDay(for: p.date)
            lastCloseByMonth[monthStart] = p.close
        }
        return lastCloseByMonth.sorted { $0.key < $1.key }
            .map { PricePoint(date: $0.key, close: $0.value) }
    }
}
