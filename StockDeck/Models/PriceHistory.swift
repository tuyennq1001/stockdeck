import Foundation

/// A price point (closing or full OHLC bar) for detail charts.
struct PricePoint: Identifiable, Equatable, Codable, Sendable {
    let date: Date
    let close: Double
    let open: Double?
    let high: Double?
    let low: Double?
    let volume: Double?
    var id: Date { date }

    init(date: Date, close: Double, open: Double? = nil, high: Double? = nil, low: Double? = nil, volume: Double? = nil) {
        self.date = date
        self.close = close
        self.open = open
        self.high = high
        self.low = low
        self.volume = volume
    }

    var effectiveOpen: Double { open ?? close }
    var effectiveHigh: Double { max(high ?? close, max(effectiveOpen, close)) }
    var effectiveLow: Double { min(low ?? close, min(effectiveOpen, close)) }
}

/// Pure transforms over Yahoo v8 chart arrays.
enum PriceHistory {
    /// Binary lookup on chronological chart data. Ties keep the earlier point,
    /// matching the previous linear minimum without scanning every hover tick.
    static func nearestPoint(to date: Date, in points: [PricePoint]) -> PricePoint? {
        guard !points.isEmpty else { return nil }
        var low = 0
        var high = points.count
        while low < high {
            let middle = low + (high - low) / 2
            if points[middle].date < date { low = middle + 1 }
            else { high = middle }
        }
        if low == 0 { return points[0] }
        if low == points.count { return points[points.count - 1] }
        let before = points[low - 1]
        let after = points[low]
        return date.timeIntervalSince(before.date) <= after.date.timeIntervalSince(date) ? before : after
    }

    /// Pairs the v8 chart `timestamp` array with OHLC arrays into
    /// chronological price points, skipping nil holes. Sanitizes corrupt
    /// single-bar split anomalies where high or open was left unadjusted.
    static func points(timestamps: [Int], closes: [Double?], opens: [Double?]? = nil, highs: [Double?]? = nil, lows: [Double?]? = nil, volumes: [Double?]? = nil) -> [PricePoint] {
        let count = timestamps.count
        var result: [PricePoint] = []
        result.reserveCapacity(count)

        let opensArr = opens ?? []
        let highsArr = highs ?? []
        let lowsArr = lows ?? []
        let volsArr = volumes ?? []

        for i in 0..<count {
            guard i < closes.count, let close = closes[i], close.isFinite, close > 0 else { continue }
            let ts = timestamps[i]
            let date = Date(timeIntervalSince1970: TimeInterval(ts))
            var open = i < opensArr.count ? opensArr[i] : nil
            var high = i < highsArr.count ? highsArr[i] : nil
            var low = i < lowsArr.count ? lowsArr[i] : nil
            let volume = i < volsArr.count ? volsArr[i] : nil

            // Sanitize unadjusted split anomalies from Yahoo aggregate bars:
            // if high or open is > 3.0x close (or low is < 0.25x close) while close is consistent,
            // fall back to close so corrupted split multiples do not corrupt ATH/ATL.
            if let h = high, h > close * 3.0 { high = close }
            if let o = open, o > close * 3.0 { open = close }
            if let l = low, l > 0, l < close * 0.25 { low = close }

            result.append(PricePoint(date: date, close: close, open: open, high: high, low: low, volume: volume))
        }

        return result.sorted { $0.date < $1.date }
    }

    /// Percentage move from the market close at (or immediately before) a
    /// requested boundary to the current regular-session price. Returns nil
    /// if no close exists at or before the boundary (e.g. newly listed instruments
    /// or insufficient historical data).
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

        guard let baselineIdx else { return nil }
        let baseline = points[baselineIdx]
        guard baseline.close.isFinite, baseline.close > 0 else { return nil }
        return (currentPrice - baseline.close) / baseline.close * 100
    }

    /// Resamples a daily (or finer) OHLC series into one point per calendar month.
    /// Preserves the true monthly open (first day), high (monthly max),
    /// low (monthly min), close (last day), and total volume.
    static func deriveMonthly(from daily: [PricePoint], calendar: Calendar = .current) -> [PricePoint] {
        let sorted = daily.sorted { $0.date < $1.date }
        struct MonthlyBucket {
            var open: Double?
            var high: Double
            var low: Double
            var close: Double
            var volume: Double?
        }
        var buckets: [Date: MonthlyBucket] = [:]
        for p in sorted where p.close.isFinite && p.close > 0 {
            let monthStart = calendar.dateInterval(of: .month, for: p.date)?.start
                ?? calendar.startOfDay(for: p.date)
            let effHigh = p.effectiveHigh
            let effLow = p.effectiveLow
            if var bucket = buckets[monthStart] {
                bucket.high = max(bucket.high, effHigh)
                bucket.low = min(bucket.low, effLow)
                bucket.close = p.close
                if let v = p.volume, v > 0 {
                    bucket.volume = (bucket.volume ?? 0) + v
                }
                buckets[monthStart] = bucket
            } else {
                buckets[monthStart] = MonthlyBucket(
                    open: p.open ?? p.close,
                    high: effHigh,
                    low: effLow,
                    close: p.close,
                    volume: p.volume
                )
            }
        }
        return buckets.sorted { $0.key < $1.key }
            .map { PricePoint(date: $0.key, close: $0.value.close, open: $0.value.open, high: $0.value.high, low: $0.value.low, volume: $0.value.volume) }
    }
}
