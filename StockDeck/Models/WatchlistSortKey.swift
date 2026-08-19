import Foundation

/// Unified sorting keys for Watchlists across Desktop, Popover, and Mobile.
enum WatchlistSortKey: Equatable, Hashable {
    case order, symbol, price, changePercent, extChangePercent, metric(WatchlistMetric)

    var rawString: String {
        switch self {
        case .order: return "order"
        case .symbol: return "symbol"
        case .price: return "price"
        case .changePercent: return "changePercent"
        case .extChangePercent: return "extChangePercent"
        case .metric(let m): return "metric:\(m.rawValue)"
        }
    }

    static func from(rawString: String?) -> WatchlistSortKey {
        guard let rawString else { return .order }
        if rawString == "order" || rawString == "manual" { return .order }
        if rawString == "symbol" { return .symbol }
        if rawString == "price" || rawString == "metric:price" { return .price }
        if rawString == "changePercent" || rawString == "metric:today" { return .changePercent }
        if rawString == "extChangePercent" || rawString == "metric:ext" { return .extChangePercent }
        if rawString == "absoluteChange" || rawString == "metric:todayChange" { return .metric(.todayChange) }
        if rawString.hasPrefix("metric:") {
            let metricRaw = String(rawString.dropFirst("metric:".count))
            if let m = WatchlistMetric(rawValue: metricRaw) {
                return .metric(m)
            }
        }
        return .order
    }
}
