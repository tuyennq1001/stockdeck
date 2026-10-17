import Foundation

/// Supported markets for regulatory insider trading disclosures.
public enum InsiderMarket: String, Codable, Sendable, Equatable {
    case us
    case vn
    case unsupported
}

/// Represents an insider transaction filed under SEC Form 4 (US) or SSC/Exchange disclosures (Vietnam).
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
    /// Transaction code:
    /// - `P`: Open market or private purchase
    /// - `S`: Open market or private sale
    /// - `PLAN`: Newly registered / pending transaction (Vietnam disclosure)
    /// - `ESOP`: Employee Stock Ownership Plan issuance/purchase
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
    public let relatedPersonName: String?
    public let relatedPersonTitle: String?
    public let transactionNote: String?
    public let ownershipRatioAfter: Double?
    public let plannedShares: Double?
    public let isVNDisclosure: Bool
    public let isRule10b51: Bool

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
        sharesOwnedFollowing: Double,
        relatedPersonName: String? = nil,
        relatedPersonTitle: String? = nil,
        transactionNote: String? = nil,
        ownershipRatioAfter: Double? = nil,
        plannedShares: Double? = nil,
        isVNDisclosure: Bool = false,
        isRule10b51: Bool = false
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
        self.relatedPersonName = relatedPersonName
        self.relatedPersonTitle = relatedPersonTitle
        self.transactionNote = transactionNote
        self.ownershipRatioAfter = ownershipRatioAfter
        self.plannedShares = plannedShares
        self.isVNDisclosure = isVNDisclosure
        self.isRule10b51 = isRule10b51
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.symbol = try c.decode(String.self, forKey: .symbol)
        self.ownerName = try c.decode(String.self, forKey: .ownerName)
        self.officerTitle = try c.decodeIfPresent(String.self, forKey: .officerTitle)
        self.isDirector = try c.decodeIfPresent(Bool.self, forKey: .isDirector) ?? false
        self.isOfficer = try c.decodeIfPresent(Bool.self, forKey: .isOfficer) ?? false
        self.isTenPercentOwner = try c.decodeIfPresent(Bool.self, forKey: .isTenPercentOwner) ?? false
        self.transactionDate = try c.decode(Date.self, forKey: .transactionDate)
        self.filingDate = try c.decodeIfPresent(Date.self, forKey: .filingDate)
        self.transactionCode = try c.decode(String.self, forKey: .transactionCode).uppercased()
        self.acquiredDisposed = try c.decode(String.self, forKey: .acquiredDisposed).uppercased()
        self.shares = try c.decode(Double.self, forKey: .shares)
        self.price = try c.decode(Double.self, forKey: .price)
        self.sharesOwnedFollowing = try c.decode(Double.self, forKey: .sharesOwnedFollowing)
        self.relatedPersonName = try c.decodeIfPresent(String.self, forKey: .relatedPersonName)
        self.relatedPersonTitle = try c.decodeIfPresent(String.self, forKey: .relatedPersonTitle)
        self.transactionNote = try c.decodeIfPresent(String.self, forKey: .transactionNote)
        self.ownershipRatioAfter = try c.decodeIfPresent(Double.self, forKey: .ownershipRatioAfter)
        self.plannedShares = try c.decodeIfPresent(Double.self, forKey: .plannedShares)
        self.isVNDisclosure = try c.decodeIfPresent(Bool.self, forKey: .isVNDisclosure) ?? false
        self.isRule10b51 = try c.decodeIfPresent(Bool.self, forKey: .isRule10b51) ?? false
    }

    /// Whether this transaction represents an acquisition/purchase of shares
    public var isBuy: Bool {
        acquiredDisposed == "A" || transactionCode == "P"
    }

    /// Whether this represents a newly registered / pending trade not yet completed
    public var isPendingPlan: Bool {
        transactionCode == "PLAN"
    }

    /// Whether this is an open market buy/sell transaction (or active registration in VN),
    /// excluding ESOP, grants, awards, gifts, and option exercises.
    public var isOpenMarket: Bool {
        if isVNDisclosure {
            return (transactionCode == "P" || transactionCode == "S" || transactionCode == "PLAN") && shares > 0
        }
        return (transactionCode == "P" || transactionCode == "S") && price > 0
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
        case "PLAN": return isBuy ? "Registered to Buy (Pending)" : "Registered to Sell (Pending)"
        case "ESOP": return "ESOP Transaction"
        case "M": return "Option Exercise"
        case "A": return "Stock Award / Grant"
        case "F": return "Tax Withholding"
        case "G": return "Gift"
        default: return isBuy ? "Acquisition" : "Disposition"
        }
    }

    /// Concise role label (including related insider relationship for Vietnam disclosures)
    public var displayRole: String {
        let cleanTitle = officerTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let cleanRelName = relatedPersonName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let cleanRelTitle = relatedPersonTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if !cleanRelName.isEmpty {
            let rolePrefix = cleanTitle.isEmpty ? "Người liên quan" : cleanTitle
            if !cleanRelTitle.isEmpty {
                return "\(rolePrefix) — \(cleanRelTitle) \(cleanRelName)"
            }
            return "\(rolePrefix) — \(cleanRelName)"
        }
        if !cleanTitle.isEmpty {
            return cleanTitle
        }
        if isDirector { return "Director" }
        if isTenPercentOwner { return "10% Owner" }
        if isOfficer { return "Officer" }
        return isVNDisclosure ? "Cổ đông nội bộ" : "Insider"
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

    public var buyShareRatio: Double {
        let total = totalBuyShares + totalSellShares
        guard total > 0 else { return 0.5 }
        return totalBuyShares / total
    }

    public var buyValueRatio: Double {
        let totalVal = totalBuyValue + totalSellValue
        if totalVal > 0 {
            return totalBuyValue / totalVal
        }
        return buyShareRatio
    }

    public enum Sentiment: String, Codable, Sendable {
        case netBuying = "Net Buying"
        case netSelling = "Net Selling"
        case neutral = "Neutral"
    }

    public var sentiment: Sentiment {
        if totalBuyValue > 0 || totalSellValue > 0 {
            if netValue > 10_000 || (totalBuyShares > 0 && totalSellShares == 0) {
                return .netBuying
            } else if netValue < -10_000 || (totalSellShares > 0 && totalBuyShares == 0) {
                return .netSelling
            }
            return .neutral
        } else {
            if netShares > 1_000 || (totalBuyShares > 0 && totalSellShares == 0) {
                return .netBuying
            } else if netShares < -1_000 || (totalSellShares > 0 && totalBuyShares == 0) {
                return .netSelling
            }
            return .neutral
        }
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
