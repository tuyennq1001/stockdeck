import Foundation

struct ClosedTrade: Identifiable, Codable, Equatable, Hashable {
    var id: UUID
    var symbol: String
    var quantity: Double
    var buyPrice: Double
    var sellPrice: Double
    var buyDate: Date?
    var sellDate: Date?
    var account: String?
    var leverage: Double?

    init(
        id: UUID = UUID(),
        symbol: String,
        quantity: Double,
        buyPrice: Double,
        sellPrice: Double,
        buyDate: Date? = nil,
        sellDate: Date? = nil,
        account: String? = nil,
        leverage: Double? = nil
    ) {
        self.id = id
        self.symbol = symbol
        self.quantity = quantity
        self.buyPrice = buyPrice
        self.sellPrice = sellPrice
        self.buyDate = buyDate
        self.sellDate = sellDate
        self.account = account
        self.leverage = leverage
    }

    private enum CodingKeys: String, CodingKey {
        case id, symbol, quantity, buyPrice, sellPrice, buyDate, sellDate, account, leverage
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        symbol = try container.decode(String.self, forKey: .symbol)
        quantity = try container.decode(Double.self, forKey: .quantity)
        buyPrice = try container.decodeIfPresent(Double.self, forKey: .buyPrice) ?? 0.0
        sellPrice = try container.decodeIfPresent(Double.self, forKey: .sellPrice) ?? 0.0
        buyDate = try container.decodeIfPresent(Date.self, forKey: .buyDate)
        sellDate = try container.decodeIfPresent(Date.self, forKey: .sellDate)
        account = try container.decodeIfPresent(String.self, forKey: .account)
        leverage = try container.decodeIfPresent(Double.self, forKey: .leverage)
    }

    var isJapaneseFund: Bool {
        StockService.isJapaneseMutualFund(symbol)
    }

    var scale: Double {
        isJapaneseFund ? 10000.0 : 1.0
    }

    var costBasis: Double {
        (abs(quantity) * buyPrice) / scale
    }

    var proceeds: Double {
        (abs(quantity) * sellPrice) / scale
    }

    var realizedPnl: Double {
        (proceeds - costBasis) * (leverage ?? 1.0)
    }

    var realizedPnlPercent: Double {
        costBasis > 0 ? (realizedPnl / costBasis) * 100 : 0
    }

    var holdingPeriodDays: Int? {
        guard let b = buyDate, let s = sellDate else { return nil }
        let calendar = Calendar.current
        let components = calendar.dateComponents([.day], from: b, to: s)
        return max(components.day ?? 0, 0)
    }
}

/// Represents a consolidated view of multiple closed trade lots of the same symbol, account, and sell date.
struct ConsolidatedClosedTrade: Identifiable, Sendable {
    let id: String
    let portfolioId: UUID
    let portfolioName: String
    let symbol: String
    let account: String?
    let sellDate: Date?
    let lots: [ClosedTrade]

    init(
        portfolioId: UUID,
        portfolioName: String,
        symbol: String,
        account: String?,
        sellDate: Date?,
        lots: [ClosedTrade]
    ) {
        self.portfolioId = portfolioId
        self.portfolioName = portfolioName
        self.symbol = symbol
        self.account = account
        self.sellDate = sellDate
        self.lots = lots

        let dateKey = sellDate.map { TradeDateKey.compactString(from: $0) } ?? "nodate"
        self.id = "\(portfolioId.uuidString)_\(symbol)_\(account ?? "")_\(dateKey)"
    }

    var isJapaneseFund: Bool {
        StockService.isJapaneseMutualFund(symbol)
    }

    var scale: Double {
        isJapaneseFund ? 10000.0 : 1.0
    }

    var quantity: Double {
        lots.reduce(0) { $0 + abs($1.quantity) }
    }

    var costBasis: Double {
        lots.reduce(0) { $0 + $1.costBasis }
    }

    var proceeds: Double {
        lots.reduce(0) { $0 + $1.proceeds }
    }

    var realizedPnl: Double {
        lots.reduce(0) { $0 + $1.realizedPnl }
    }

    var realizedPnlPercent: Double {
        costBasis > 0 ? (realizedPnl / costBasis) * 100 : 0
    }

    var buyPrice: Double {
        guard quantity > 0 else { return 0 }
        return (costBasis * scale) / quantity
    }

    var sellPrice: Double {
        guard quantity > 0 else { return 0 }
        return (proceeds * scale) / quantity
    }

    var holdingPeriodDays: Int? {
        let validDays = lots.compactMap(\.holdingPeriodDays)
        guard !validDays.isEmpty else { return nil }
        return validDays.reduce(0, +) / validDays.count
    }

    static func consolidate(
        tradesWithPortfolio: [(trade: ClosedTrade, portfolioId: UUID, portfolioName: String)]
    ) -> [ConsolidatedClosedTrade] {
        var groups: [String: [(trade: ClosedTrade, portfolioId: UUID, portfolioName: String)]] = [:]
        var orderKeys: [String] = []

        for item in tradesWithPortfolio {
            let dateKey = item.trade.sellDate.map { TradeDateKey.ymdString(from: $0) } ?? "nodate"
            let key = "\(item.portfolioId.uuidString)|\(item.trade.symbol.uppercased())|\(item.trade.account ?? "")|\(dateKey)"
            if groups[key] == nil {
                orderKeys.append(key)
                groups[key] = []
            }
            groups[key]?.append(item)
        }

        return orderKeys.compactMap { key in
            guard let group = groups[key], let first = group.first else { return nil }
            return ConsolidatedClosedTrade(
                portfolioId: first.portfolioId,
                portfolioName: first.portfolioName,
                symbol: first.trade.symbol,
                account: first.trade.account,
                sellDate: first.trade.sellDate,
                lots: group.map(\.trade)
            )
        }
    }

    static func consolidate(
        trades: [ClosedTrade],
        portfolioId: UUID = UUID(),
        portfolioName: String = ""
    ) -> [ConsolidatedClosedTrade] {
        consolidate(tradesWithPortfolio: trades.map { ($0, portfolioId, portfolioName) })
    }
}


