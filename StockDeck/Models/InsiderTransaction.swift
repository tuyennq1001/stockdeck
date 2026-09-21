import Foundation

/// Represents an insider transaction filed under SEC Form 4 (or equivalent regulatory bodies).
public struct InsiderTransaction: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let symbol: String
    public let ownerName: String
    public let officerTitle: String?
    public let isDirector: Bool
    public let isOfficer: Bool
    public let isTenPercentOwner: Bool
    public let transactionDate: Date
    public let filingDate: Date?
    /// Transaction code from SEC Form 4:
    /// - `P`: Open market or private purchase
    /// - `S`: Open market or private sale
    /// - `A`: Grant, award, or other acquisition
    /// - `M`: Exercise of derivative (option)
    /// - `F`: Payment of exercise price or tax liability by delivering/withholding shares
    /// - `G`: Gift
    public let transactionCode: String
    /// "A" for Acquired, "D" for Disposed
    public let acquiredDisposed: String
    public let shares: Double
    public let price: Double
    public let sharesOwnedFollowing: Double

    public init(
        id: String,
        symbol: String,
        ownerName: String,
        officerTitle: String? = nil,
        isDirector: Bool = false,
        isOfficer: Bool = false,
        isTenPercentOwner: Bool = false,
        transactionDate: Date,
        filingDate: Date? = nil,
        transactionCode: String,
        acquiredDisposed: String,
        shares: Double,
        price: Double,
        sharesOwnedFollowing: Double
    ) {
        self.id = id
        self.symbol = symbol
        self.ownerName = ownerName
        self.officerTitle = officerTitle
        self.isDirector = isDirector
        self.isOfficer = isOfficer
        self.isTenPercentOwner = isTenPercentOwner
        self.transactionDate = transactionDate
        self.filingDate = filingDate
        self.transactionCode = transactionCode.uppercased()
        self.acquiredDisposed = acquiredDisposed.uppercased()
        self.shares = shares
        self.price = price
        self.sharesOwnedFollowing = sharesOwnedFollowing
    }

    /// Whether this transaction represents an acquisition/purchase of shares
    public var isBuy: Bool {
        acquiredDisposed == "A" || transactionCode == "P"
    }

    /// Whether this is an open market buy/sell transaction (P or S) with an execution price > 0,
    /// which represents the purest discretionary investment decision by management.
    public var isOpenMarket: Bool {
        (transactionCode == "P" || transactionCode == "S") && price > 0
    }

    /// Total dollar/currency value of the transaction
    public var totalValue: Double {
        shares * price
    }

    /// Human-friendly description of the transaction code
    public var codeDescription: String {
        switch transactionCode {
        case "P": return "Open Market Buy"
        case "S": return "Open Market Sell"
        case "M": return "Option Exercise"
        case "A": return "Stock Award / Grant"
        case "F": return "Tax Withholding"
        case "G": return "Gift"
        default: return isBuy ? "Acquisition" : "Disposition"
        }
    }

    /// Concise role label
    public var displayRole: String {
        if let title = officerTitle, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return title
        }
        if isDirector { return "Director" }
        if isTenPercentOwner { return "10% Owner" }
        if isOfficer { return "Officer" }
        return "Insider"
    }
}

/// Sentiment summary aggregating insider buying and selling over a lookback period
public struct InsiderSentimentSummary: Codable, Equatable, Sendable {
    public let symbol: String
    public let lookbackMonths: Int
    public let totalBuyShares: Double
    public let totalSellShares: Double
    public let totalBuyValue: Double
    public let totalSellValue: Double
    public let buyCount: Int
    public let sellCount: Int
    public let openMarketBuyCount: Int
    public let openMarketSellCount: Int

    public var netShares: Double {
        totalBuyShares - totalSellShares
    }

    public var netValue: Double {
        totalBuyValue - totalSellValue
    }

    public enum Sentiment: String, Codable, Sendable {
        case netBuying = "Net Buying"
        case netSelling = "Net Selling"
        case neutral = "Neutral"
    }

    public var sentiment: Sentiment {
        if netValue > 10_000 || (totalBuyShares > 0 && totalSellShares == 0) {
            return .netBuying
        } else if netValue < -10_000 || (totalSellShares > 0 && totalBuyShares == 0) {
            return .netSelling
        }
        return .neutral
    }

    public init(
        symbol: String,
        lookbackMonths: Int = 3,
        totalBuyShares: Double,
        totalSellShares: Double,
        totalBuyValue: Double,
        totalSellValue: Double,
        buyCount: Int,
        sellCount: Int,
        openMarketBuyCount: Int,
        openMarketSellCount: Int
    ) {
        self.symbol = symbol
        self.lookbackMonths = lookbackMonths
        self.totalBuyShares = totalBuyShares
        self.totalSellShares = totalSellShares
        self.totalBuyValue = totalBuyValue
        self.totalSellValue = totalSellValue
        self.buyCount = buyCount
        self.sellCount = sellCount
        self.openMarketBuyCount = openMarketBuyCount
        self.openMarketSellCount = openMarketSellCount
    }
}
