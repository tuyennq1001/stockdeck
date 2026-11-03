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

        let sorted = result.sorted { $0.date < $1.date }
        return sanitizeSplitAnomalies(sorted)
    }

    /// Sanitizes multi-bar split anomalies common in Yahoo Finance aggregate data:
    /// 1. Leading unadjusted split segment (e.g. first 1-5 bars missed split adjustment and remain 10x-30x higher or lower than the rest).
    /// 2. Isolated pockets (1-3 bars) around split dates that were double-divided or missed adjustment before reverting.
    static func sanitizeSplitAnomalies(_ points: [PricePoint]) -> [PricePoint] {
        let n = points.count
        guard n >= 4 else { return points }

        var result = points

        // 1. Check leading cliff (first k bars, 1 <= k <= 5, with unadjusted split)
        let maxK = min(6, n - 2)
        for k in 1..<maxK {
            let nextSlice = result[k..<min(k + 5, n)].map(\.close).filter { $0.isFinite && $0 > 0 }
            guard nextSlice.count >= 2 else { continue }
            let baseline = nextSlice.reduce(0.0, +) / Double(nextSlice.count)
            guard baseline > 0 else { continue }

            let leadSlice = result[0..<k].map(\.close).filter { $0.isFinite && $0 > 0 }
            guard leadSlice.count == k else { continue }

            let lastLead = leadSlice[k - 1]
            let ratio = lastLead / baseline
            if ratio > 3.0 || ratio < 0.33 {
                let allMatch = leadSlice.allSatisfy { c in
                    ratio > 3.0 ? (c / baseline > 3.0) : (c / baseline < 0.33)
                }
                let nextMin = nextSlice.min() ?? baseline
                let nextMax = nextSlice.max() ?? baseline
                let nextStable = nextMin > 0 && (nextMax / nextMin < 2.0)
                if allMatch && nextStable {
                    let kClose = result[k].close
                    guard kClose > 0 else { continue }
                    let factor = lastLead / kClose
                    guard factor.isFinite && factor > 0 else { continue }
                    for j in 0..<k {
                        let pt = result[j]
                        let c = pt.close / factor
                        let o = pt.open.map { $0 / factor }
                        let h = pt.high.map { $0 / factor }
                        let l = pt.low.map { $0 / factor }
                        result[j] = PricePoint(date: pt.date, close: c, open: o, high: h, low: l, volume: pt.volume)
                    }
                    break
                }
            }
        }

        // 2. Check isolated pockets (1 to 3 bars) that jump or crash and immediately revert
        var i = 1
        while i < result.count - 2 {
            let prevClose = result[i - 1].close
            guard prevClose.isFinite, prevClose > 0 else {
                i += 1
                continue
            }

            var foundPocket = false
            for plen in [1, 2, 3] {
                guard i + plen < result.count else { continue }
                let pocketCloses = result[i..<(i + plen)].map(\.close)
                guard pocketCloses.allSatisfy({ $0.isFinite && $0 > 0 }) else { continue }
                let nextClose = result[i + plen].close
                guard nextClose.isFinite, nextClose > 0 else { continue }

                // Surrounding baseline bars before & after pocket must be reasonably consistent
                let minNeighbor = min(prevClose, nextClose)
                let maxNeighbor = max(prevClose, nextClose)
                guard minNeighbor > 0, (maxNeighbor / minNeighbor) < 1.75 else { continue }

                let baseline = (prevClose + nextClose) / 2.0
                guard baseline > 0 else { continue }
                let ratios = pocketCloses.map { $0 / baseline }

                let allHigh = ratios.allSatisfy { $0 > 3.0 }
                let allLow = ratios.allSatisfy { $0 < 0.33 }
                if allHigh || allLow {
                    let avgRatio = ratios.reduce(0.0, +) / Double(ratios.count)
                    guard avgRatio.isFinite && avgRatio > 0 else { continue }
                    for p in 0..<plen {
                        let idx = i + p
                        let pt = result[idx]
                        let c = pt.close / avgRatio
                        let o = pt.open.map { $0 / avgRatio }
                        let h = pt.high.map { $0 / avgRatio }
                        let l = pt.low.map { $0 / avgRatio }
                        result[idx] = PricePoint(date: pt.date, close: c, open: o, high: h, low: l, volume: pt.volume)
                    }
                    i += plen
                    foundPocket = true
                    break
                }
            }

            if !foundPocket {
                i += 1
            }
        }

        return result
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
        let sanitized = sanitizeSplitAnomalies(daily)
        let sorted = sanitized.sorted { $0.date < $1.date }
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
