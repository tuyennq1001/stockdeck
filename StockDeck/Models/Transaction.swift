import Foundation

/// Fast, thread-safe date key formatter to avoid repeated DateFormatter allocations in tight loops.
public enum TradeDateKey {
    private static let ymdFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.locale = Locale(identifier: "en_US_POSIX")
        return df
    }()

    private static let compactFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd"
        df.locale = Locale(identifier: "en_US_POSIX")
        return df
    }()

    private static let lock = NSLock()

    public static func ymdString(from date: Date) -> String {
        lock.lock()
        defer { lock.unlock() }
        return ymdFormatter.string(from: date)
    }

    public static func compactString(from date: Date) -> String {
        lock.lock()
        defer { lock.unlock() }
        return compactFormatter.string(from: date)
    }
}

/// Defines the kind of transaction recorded in a portfolio's ledger.
public enum TransactionType: String, Codable, CaseIterable, Sendable {
    case buy = "BUY"
    case sell = "SELL"
    case transferIn = "TRANSFER_IN"
    case transferOut = "TRANSFER_OUT"
    case dividend = "DIVIDEND"
    case spinOff = "SPIN_OFF"
    case split = "SPLIT"
    case cashDeposit = "DEPOSIT"
    case cashWithdrawal = "WITHDRAWAL"

    public var displayName: String {
        switch self {
        case .buy: return "Buy"
        case .sell: return "Sell"
        case .transferIn: return "Transfer In"
        case .transferOut: return "Transfer Out"
        case .dividend: return "Dividend"
        case .spinOff: return "Spin-off"
        case .split: return "Split"
        case .cashDeposit: return "Deposit"
        case .cashWithdrawal: return "Withdrawal"
        }
    }
}

/// Represents an immutable transaction entry in the portfolio ledger.
public struct PortfolioTransaction: Identifiable, Codable, Equatable, Hashable, Sendable {
    public let id: UUID
    public let date: Date
    public let symbol: String
    public let type: TransactionType
    public let quantity: Double
    public let price: Double
    public let amount: Double
    public let currency: String
    public let fee: Double?
    public let tax: Double?
    public let fxRate: Double?
    public let account: String?
    public let notes: String?

    public init(
        id: UUID = UUID(),
        date: Date,
        symbol: String,
        type: TransactionType,
        quantity: Double,
        price: Double,
        amount: Double? = nil,
        currency: String = "USD",
        fee: Double? = nil,
        tax: Double? = nil,
        fxRate: Double? = nil,
        account: String? = nil,
        notes: String? = nil
    ) {
        self.id = id
        self.date = date
        self.symbol = symbol.uppercased()
        self.type = type
        self.quantity = quantity
        self.price = price
        let scale = StockService.isJapaneseMutualFund(symbol) ? 10000.0 : 1.0
        self.amount = amount ?? ((abs(quantity) * price) / scale)
        if currency == "USD" {
            let detected = StockService.detectedCurrency(for: symbol)
            self.currency = detected
        } else {
            self.currency = currency
        }
        self.fee = fee
        self.tax = tax
        self.fxRate = fxRate
        self.account = account
        self.notes = notes
    }

    public var isJapaneseFund: Bool {
        StockService.isJapaneseMutualFund(symbol)
    }

    public var scale: Double {
        isJapaneseFund ? 10000.0 : 1.0
    }

    public var effectiveCurrency: String {
        let detected = StockService.detectedCurrency(for: symbol)
        if detected != "USD" {
            return detected
        }
        return currency.isEmpty ? "USD" : currency
    }

    public var effectiveAmount: Double {
        if isJapaneseFund {
            let unscaled = abs(quantity) * price
            if abs(amount - unscaled) <= max(1.0, unscaled * 0.01) {
                return unscaled / 10000.0
            }
        }
        return amount
    }

    /// Generates a deduplication signature for merging and broker import.
    public var signature: String {
        let dateKey = Int(date.timeIntervalSince1970 / 86400) // day resolution
        return "\(dateKey)|\(symbol)|\(type.rawValue)|\(String(format: "%.4f", quantity))|\(String(format: "%.4f", price))|\(account ?? "")"
    }
}

public typealias Transaction = PortfolioTransaction

/// Represents a consolidated view of multiple executions/fills of a transaction of the same symbol, type, account, and date.
public struct ConsolidatedTransaction: Identifiable, Sendable {
    public let id: String
    public let portfolioId: UUID
    public let portfolioName: String
    public let symbol: String
    public let type: TransactionType
    public let account: String?
    public let date: Date
    public let transactions: [Transaction]

    public init(
        portfolioId: UUID,
        portfolioName: String,
        symbol: String,
        type: TransactionType,
        account: String?,
        date: Date,
        transactions: [Transaction]
    ) {
        self.portfolioId = portfolioId
        self.portfolioName = portfolioName
        self.symbol = symbol
        self.type = type
        self.account = account
        self.date = date
        self.transactions = transactions

        let dateKey = TradeDateKey.compactString(from: date)
        self.id = "\(portfolioId.uuidString)_\(symbol)_\(type.rawValue)_\(account ?? "")_\(dateKey)"
    }

    public var isJapaneseFund: Bool {
        StockService.isJapaneseMutualFund(symbol)
    }

    public var scale: Double {
        isJapaneseFund ? 10000.0 : 1.0
    }

    public var quantity: Double {
        transactions.reduce(0) { $0 + $1.quantity }
    }

    public var effectiveAmount: Double {
        transactions.reduce(0) { $0 + $1.effectiveAmount }
    }

    public var price: Double {
        guard quantity > 0 else { return 0 }
        return (effectiveAmount * scale) / quantity
    }

    public var effectiveCurrency: String {
        transactions.first?.effectiveCurrency ?? "USD"
    }

    public static func consolidate(
        transactionsWithPortfolio: [(tx: Transaction, portfolioId: UUID, portfolioName: String)]
    ) -> [ConsolidatedTransaction] {
        var groups: [String: [(tx: Transaction, portfolioId: UUID, portfolioName: String)]] = [:]
        var orderKeys: [String] = []

        for item in transactionsWithPortfolio {
            let dateKey = TradeDateKey.ymdString(from: item.tx.date)
            let key = "\(item.portfolioId.uuidString)|\(item.tx.symbol.uppercased())|\(item.tx.type.rawValue)|\(item.tx.account ?? "")|\(dateKey)"
            if groups[key] == nil {
                orderKeys.append(key)
                groups[key] = []
            }
            groups[key]?.append(item)
        }

        return orderKeys.compactMap { key in
            guard let group = groups[key], let first = group.first else { return nil }
            return ConsolidatedTransaction(
                portfolioId: first.portfolioId,
                portfolioName: first.portfolioName,
                symbol: first.tx.symbol,
                type: first.tx.type,
                account: first.tx.account,
                date: first.tx.date,
                transactions: group.map(\.tx)
            )
        }
    }

    public static func consolidate(
        transactions: [Transaction],
        portfolioId: UUID = UUID(),
        portfolioName: String = ""
    ) -> [ConsolidatedTransaction] {
        consolidate(transactionsWithPortfolio: transactions.map { ($0, portfolioId, portfolioName) })
    }
}
