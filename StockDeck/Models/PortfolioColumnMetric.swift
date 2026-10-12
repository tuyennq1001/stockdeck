import Foundation

/// Optional columns a user can add to the portfolio positions table.
/// Rank (#) and Symbol stay fixed; this list controls the investment
/// metrics that follow them.
enum PortfolioColumnMetric: String, CaseIterable, Codable, Hashable, Identifiable {
    case avgPrice, price, change
    case cost, value, todayPnl, totalPnl, shares, lots
    case weight
    case volume50d, volume50w

    var id: String { rawValue }

    var title: String {
        switch self {
        case .avgPrice: return "Avg Price"
        case .price: return "Price"
        case .change: return "Today %"
        case .cost: return "Total Cost"
        case .value: return "Total Value"
        case .todayPnl: return "Today PnL"
        case .totalPnl: return "Total PnL"
        case .shares: return "Shares"
        case .lots: return "Lots"
        case .weight: return "Weight"
        case .volume50d: return "50D Vol"
        case .volume50w: return "50W Vol"
        }
    }

    var category: PortfolioColumnCategory {
        switch self {
        case .avgPrice, .price, .change:
            return .price
        case .cost, .value, .todayPnl, .totalPnl, .shares, .lots:
            return .position
        case .weight:
            return .weight
        case .volume50d, .volume50w:
            return .chart
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        if raw == "volume20w" {
            self = .volume50w
            return
        }
        if raw == "volume7d" || raw == "volume30d" {
            self = .volume50d
            return
        }
        guard let value = PortfolioColumnMetric(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown metric: \(raw)")
        }
        self = value
    }

    static let defaultSelection: [PortfolioColumnMetric] = [
        .avgPrice, .price, .change, .cost, .value, .todayPnl, .totalPnl, .weight
    ]
}

enum PortfolioColumnCategory: String, CaseIterable, Identifiable {
    case price = "Price"
    case position = "Position"
    case weight = "Weight"
    case chart = "Chart"

    var id: String { rawValue }
}