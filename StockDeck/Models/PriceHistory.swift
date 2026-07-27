import Foundation

/// A price point (closing or full OHLC bar) for detail charts.
struct PricePoint: Identifiable, Equatable {
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
}
