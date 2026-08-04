import Foundation

/// Optional columns a user can add to the portfolio positions table.
/// Rank (#) and Symbol stay fixed; this list controls the investment
/// metrics that follow them.
enum PortfolioColumnMetric: String, CaseIterable, Codable, Hashable, Identifiable {
    case avgPrice, price, ext
    case cost, value, todayPnl, totalPnl
    case weight

    var id: String { rawValue }

    var title: String {
        switch self {
        case .avgPrice: return "Avg Price"
        case .price: return "Price"
        case .ext: return "Ext"
        case .cost: return "Total Cost"
        case .value: return "Total Value"
        case .todayPnl: return "Today P&L"
        case .totalPnl: return "Total P&L"
        case .weight: return "Weight"
        }
    }

    var category: PortfolioColumnCategory {
        switch self {
        case .avgPrice, .price, .ext:
            return .price
        case .cost, .value, .todayPnl, .totalPnl:
            return .position
        case .weight:
            return .weight
        }
    }

    static let defaultSelection: [PortfolioColumnMetric] = [
        .avgPrice, .price, .ext, .cost, .value, .todayPnl, .totalPnl, .weight
    ]
}

enum PortfolioColumnCategory: String, CaseIterable, Identifiable {
    case price = "Price"
    case position = "Position"
    case weight = "Weight"

    var id: String { rawValue }
}