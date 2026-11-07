import Foundation

enum MetricPeriod: String, CaseIterable, Identifiable, Sendable {
    case today = "Today"
    case oneMonth = "1M"
    case threeMonths = "3M"
    case sixMonths = "6M"
    case ytd = "YTD"
    case oneYear = "1Y"
    case twoYears = "2Y"
    case threeYears = "3Y"
    case fiveYears = "5Y"
    case tenYears = "10Y"

    var id: String { rawValue }

    var tooltip: String {
        switch self {
        case .today: return "Biến động giá trong phiên hôm nay"
        case .oneMonth: return "Biến động trong 1 tháng gần nhất"
        case .threeMonths: return "Biến động trong 3 tháng gần nhất"
        case .sixMonths: return "Biến động trong 6 tháng gần nhất"
        case .ytd: return "Biến động từ phiên đóng cửa cuối năm trước đến nay"
        case .oneYear: return "Biến động trong 1 năm gần nhất"
        case .twoYears: return "Biến động trong 2 năm gần nhất"
        case .threeYears: return "Biến động trong 3 năm gần nhất"
        case .fiveYears: return "Biến động trong 5 năm gần nhất"
        case .tenYears: return "Biến động trong 10 năm gần nhất"
        }
    }
}

struct SymbolPerformanceMetrics: Sendable {
    let symbol: String
    let price: Double
    let today: Double?
    let oneMonth: Double?
    let threeMonths: Double?
    let sixMonths: Double?
    let ytd: Double?
    let oneYear: Double?
    let twoYears: Double?
    let threeYears: Double?
    let fiveYears: Double?
    let tenYears: Double?
    let ath: Double?
    let atl: Double?
    let fromAth: Double?
    let fromAtl: Double?

    func value(for period: MetricPeriod) -> Double? {
        switch period {
        case .today: return today
        case .oneMonth: return oneMonth
        case .threeMonths: return threeMonths
        case .sixMonths: return sixMonths
        case .ytd: return ytd
        case .oneYear: return oneYear
        case .twoYears: return twoYears
        case .threeYears: return threeYears
        case .fiveYears: return fiveYears
        case .tenYears: return tenYears
        }
    }

    @MainActor
    static func compute(symbol: String, stockService: StockService) -> SymbolPerformanceMetrics {
        let q = stockService.quotes[symbol]
        let regularPrice = q?.price ?? 0
        let today = q?.changePercent

        let history = PriceHistory.sanitizeSplitAnomalies(stockService.priceHistory[symbol] ?? [])
        let allTimeHistory = PriceHistory.sanitizeSplitAnomalies(stockService.priceHistoryMax[symbol] ?? [])

        let cal = Calendar.current
        let now = Date()
        let d1m = cal.date(byAdding: .month, value: -1, to: now) ?? now
        let d3m = cal.date(byAdding: .month, value: -3, to: now) ?? now
        let d6m = cal.date(byAdding: .month, value: -6, to: now) ?? now
        let dYtd = cal.date(from: cal.dateComponents([.year], from: now)) ?? now
        let d1y = cal.date(byAdding: .year, value: -1, to: now) ?? now
        let d2y = cal.date(byAdding: .year, value: -2, to: now) ?? now
        let d3y = cal.date(byAdding: .year, value: -3, to: now) ?? now
        let d5y = cal.date(byAdding: .year, value: -5, to: now) ?? now
        let d10y = cal.date(byAdding: .year, value: -10, to: now) ?? now

        func series(covering boundary: Date) -> [PricePoint] {
            if let first = history.first?.date, first <= boundary {
                return history
            }
            return allTimeHistory.isEmpty ? history : allTimeHistory
        }

        let m1 = PriceHistory.percentChange(points: series(covering: d1m), currentPrice: regularPrice, since: d1m)
        let m3 = PriceHistory.percentChange(points: series(covering: d3m), currentPrice: regularPrice, since: d3m)
        let m6 = PriceHistory.percentChange(points: series(covering: d6m), currentPrice: regularPrice, since: d6m)
        let ytdVal = PriceHistory.percentChange(points: series(covering: dYtd), currentPrice: regularPrice, since: dYtd)
        let y1 = PriceHistory.percentChange(points: series(covering: d1y), currentPrice: regularPrice, since: d1y)
        let y2 = PriceHistory.percentChange(points: series(covering: d2y), currentPrice: regularPrice, since: d2y)
        let y3 = PriceHistory.percentChange(points: series(covering: d3y), currentPrice: regularPrice, since: d3y)
        let y5 = PriceHistory.percentChange(points: series(covering: d5y), currentPrice: regularPrice, since: d5y)
        let y10 = PriceHistory.percentChange(points: series(covering: d10y), currentPrice: regularPrice, since: d10y)

        // ATH & ATL calculation
        var histHigh: Double? = nil
        var histLow: Double? = nil
        let pointsToScan = allTimeHistory.isEmpty ? history : allTimeHistory
        for pt in pointsToScan {
            let close = pt.close
            let rawHigh = pt.effectiveHigh
            let rawLow = pt.effectiveLow
            let h = (close > 0 && rawHigh > close * 3.0) ? close : rawHigh
            let l = (close > 0 && rawLow > 0 && rawLow < close * 0.25) ? close : rawLow
            if histHigh == nil || h > histHigh! { histHigh = h }
            if histLow == nil || l < histLow! { histLow = l }
        }
        if !allTimeHistory.isEmpty {
            for pt in history {
                let close = pt.close
                let rawHigh = pt.effectiveHigh
                let rawLow = pt.effectiveLow
                let h = (close > 0 && rawHigh > close * 3.0) ? close : rawHigh
                let l = (close > 0 && rawLow > 0 && rawLow < close * 0.25) ? close : rawLow
                if histHigh == nil || h > histHigh! { histHigh = h }
                if histLow == nil || l < histLow! { histLow = l }
            }
        }

        let qHigh = max(q?.fiftyTwoWeekHigh ?? 0, regularPrice)
        let athVal: Double? = histHigh.map { max($0, qHigh) } ?? (qHigh > 0 ? qHigh : nil)
        let qLow = q?.fiftyTwoWeekLow != nil ? min(q!.fiftyTwoWeekLow!, regularPrice > 0 ? regularPrice : Double.greatestFiniteMagnitude) : regularPrice
        let atlVal: Double?
        if let l = histLow, qLow > 0 {
            atlVal = min(l, qLow)
        } else if let l = histLow {
            atlVal = l
        } else if qLow > 0 {
            atlVal = qLow
        } else {
            atlVal = nil
        }

        let fromAth: Double?
        if let ath = athVal, ath > 0, regularPrice > 0 {
            fromAth = regularPrice >= ath ? 0.0 : min(0.0, (regularPrice - ath) / ath * 100)
        } else {
            fromAth = nil
        }

        let fromAtl: Double?
        if let atl = atlVal, atl > 0, regularPrice > 0 {
            fromAtl = regularPrice <= atl ? 0.0 : max(0.0, (regularPrice - atl) / atl * 100)
        } else {
            fromAtl = nil
        }

        return SymbolPerformanceMetrics(
            symbol: symbol,
            price: regularPrice,
            today: today,
            oneMonth: m1,
            threeMonths: m3,
            sixMonths: m6,
            ytd: ytdVal,
            oneYear: y1,
            twoYears: y2,
            threeYears: y3,
            fiveYears: y5,
            tenYears: y10,
            ath: athVal,
            atl: atlVal,
            fromAth: fromAth,
            fromAtl: fromAtl
        )
    }
}
