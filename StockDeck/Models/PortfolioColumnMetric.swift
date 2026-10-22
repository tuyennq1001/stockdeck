import Foundation

/// Optional columns a user can add to the portfolio positions table.
/// Rank (#) and Symbol stay fixed; this list controls the investment
/// metrics that follow them.
enum PortfolioColumnMetric: String, CaseIterable, Codable, Hashable, Identifiable {
    case avgPrice, price, change
    case cost, value, todayPnl, totalPnl, shares, lots
    case weight
    case marketCap, pe, forwardPe, pb, divYield, eps
    case volume50d, volume50w

    var id: String { rawValue }

    var isVolumeMetric: Bool { self == .volume50d || self == .volume50w }

    /// Volume columns remain decodable so existing saved layouts can migrate cleanly.
    static var selectableCases: [PortfolioColumnMetric] {
        allCases.filter { !$0.isVolumeMetric }
    }

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
        case .marketCap: return "Mkt Cap"
        case .pe: return "P/E"
        case .forwardPe: return "Fwd P/E"
        case .pb: return "P/B"
        case .divYield: return "Div Yield"
        case .eps: return "EPS"
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
        case .marketCap, .pe, .forwardPe, .pb, .divYield, .eps:
            return .valuation
        case .volume50d, .volume50w:
            return .chart
        }
    }

    static func from(raw: String) -> PortfolioColumnMetric? {
        if raw == "volume20w" { return .volume50w }
        if raw == "volume7d" || raw == "volume30d" { return .volume50d }
        return PortfolioColumnMetric(rawValue: raw)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let value = PortfolioColumnMetric.from(raw: raw) else {
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
    case valuation = "Valuation"
    case chart = "Chart"

    var id: String { rawValue }

    static var selectionCases: [PortfolioColumnCategory] {
        allCases.filter { category in
            PortfolioColumnMetric.selectableCases.contains { $0.category == category }
        }
    }
}
