import Foundation

/// Optional columns a user can add to a watchlist. Rank, symbol, and price stay fixed;
/// this list controls the investment metrics that follow them.
enum WatchlistMetric: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case price
    case today, todayChange, oneMonth, threeMonths, ytd, sixMonths, oneYear, twoYears, threeYears, fiveYears, tenYears
    case ath, fromAth, atl, fromAtl
    case marketCap, buyTarget
    case chart24h, chart7d, chart30d, chart60d, chart90d, chartYtd, chart1y

    var id: String { rawValue }

    var title: String {
        switch self {
        case .price: return "Price"
        case .today, .todayChange: return "Today %"
        case .oneMonth: return "1M %"
        case .threeMonths: return "3M %"
        case .ytd: return "YTD %"
        case .sixMonths: return "6M %"
        case .oneYear: return "1Y %"
        case .twoYears: return "2Y %"
        case .threeYears: return "3Y %"
        case .fiveYears: return "5Y %"
        case .tenYears: return "10Y %"
        case .ath: return "ATH"
        case .fromAth: return "From ATH"
        case .atl: return "ATL"
        case .fromAtl: return "From ATL"
        case .marketCap: return "Mkt Cap"
        case .buyTarget: return "Buy Target"
        case .chart24h: return "24h chart"
        case .chart7d: return "7d chart"
        case .chart30d: return "30d chart"
        case .chart60d: return "60d chart"
        case .chart90d: return "90d chart"
        case .chartYtd: return "YTD chart"
        case .chart1y: return "1Y chart"
        }
    }

    var category: WatchlistMetricCategory {
        switch self {
        case .price:
            return .core
        case .today, .todayChange, .oneMonth, .threeMonths, .ytd, .sixMonths, .oneYear, .twoYears, .threeYears, .fiveYears, .tenYears:
            return .change
        case .ath, .fromAth, .atl, .fromAtl, .marketCap, .buyTarget:
            return .price
        case .chart24h, .chart7d, .chart30d, .chart60d, .chart90d, .chartYtd, .chart1y:
            return .chart
        }
    }

    var isChart: Bool {
        category == .chart
    }

    static let defaultSelection: [WatchlistMetric] = [.todayChange, .oneMonth, .threeMonths, .ytd, .chart7d]
}

enum WatchlistMetricCategory: String, CaseIterable, Identifiable {
    case core = "Core"
    case change = "Change"
    case price = "Price"
    case chart = "Chart"

    var id: String { rawValue }
}
