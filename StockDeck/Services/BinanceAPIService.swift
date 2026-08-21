import Foundation
import CommonCrypto

enum BinanceAPIError: LocalizedError {
    case invalidCredentials
    case invalidURL
    case networkError(String)
    case apiError(code: Int, message: String)
    case decodingError

    var errorDescription: String? {
        switch self {
        case .invalidCredentials:
            return "Invalid Binance API Key or Secret Key."
        case .invalidURL:
            return "Invalid Binance API URL."
        case .networkError(let msg):
            return "Network error: \(msg)"
        case .apiError(let code, let msg):
            return "Binance API Error (\(code)): \(msg)"
        case .decodingError:
            return "Failed to parse response from Binance."
        }
    }
}

struct BinanceAssetBalance: Decodable {
    let asset: String
    let free: String?
    let locked: String?
    let freeze: String?
    let withdrawing: String?

    init(asset: String, free: String? = nil, locked: String? = nil, freeze: String? = nil, withdrawing: String? = nil) {
        self.asset = asset
        self.free = free
        self.locked = locked
        self.freeze = freeze
        self.withdrawing = withdrawing
    }

    var totalQuantity: Double {
        let freeVal = Double(free ?? "0") ?? 0
        let lockedVal = Double(locked ?? "0") ?? 0
        let freezeVal = Double(freeze ?? "0") ?? 0
        let withdrawingVal = Double(withdrawing ?? "0") ?? 0
        return freeVal + lockedVal + freezeVal + withdrawingVal
    }
}

struct BinanceFundingAsset: Decodable {
    let asset: String
    let free: String?
    let freeze: String?
    let withdrawing: String?

    var totalQuantity: Double {
        let freeVal = Double(free ?? "0") ?? 0
        let freezeVal = Double(freeze ?? "0") ?? 0
        let withdrawingVal = Double(withdrawing ?? "0") ?? 0
        return freeVal + freezeVal + withdrawingVal
    }
}

struct BinanceUserAsset: Decodable {
    let asset: String
    let free: String?
    let locked: String?
    let freeze: String?
    let withdrawing: String?

    var totalQuantity: Double {
        let freeVal = Double(free ?? "0") ?? 0
        let lockedVal = Double(locked ?? "0") ?? 0
        let freezeVal = Double(freeze ?? "0") ?? 0
        let withdrawingVal = Double(withdrawing ?? "0") ?? 0
        return freeVal + lockedVal + freezeVal + withdrawingVal
    }
}

struct BinanceEarnPosition: Decodable {
    let asset: String
    let totalAmount: String?
    let amount: String?

    var totalQuantity: Double {
        let tAmt = Double(totalAmount ?? "0") ?? 0
        let amt = Double(amount ?? "0") ?? 0
        return max(tAmt, amt)
    }
}

struct BinanceEarnResponse: Decodable {
    let rows: [BinanceEarnPosition]?
}

struct BinanceEthStakingAccountResponse: Decodable {
    let holdingBETH: String?
    let holdingWBETH: String?
}

struct BinanceFuturesAsset: Decodable {
    let asset: String
    let walletBalance: String?
    let unrealizedProfit: String?

    init(asset: String, walletBalance: String? = nil, unrealizedProfit: String? = nil) {
        self.asset = asset
        self.walletBalance = walletBalance
        self.unrealizedProfit = unrealizedProfit
    }

    /// Net equity = wallet balance (collateral) + unrealized P&L from open positions.
    var totalQuantity: Double {
        let walletVal = Double(walletBalance ?? "0") ?? 0
        let unrealizedVal = Double(unrealizedProfit ?? "0") ?? 0
        return walletVal + unrealizedVal
    }
}

struct BinanceFuturesAccountResponse: Decodable {
    let assets: [BinanceFuturesAsset]?
}

struct BinanceMarginAsset: Decodable {
    let asset: String
    let free: String?
    let locked: String?
    let borrowed: String?
    let interest: String?

    init(asset: String, free: String? = nil, locked: String? = nil, borrowed: String? = nil, interest: String? = nil) {
        self.asset = asset
        self.free = free
        self.locked = locked
        self.borrowed = borrowed
        self.interest = interest
    }

    /// Net equity = free + locked - borrowed - interest, so a leveraged margin
    /// position does not inflate the user's real net asset value.
    var totalQuantity: Double {
        let f = Double(free ?? "0") ?? 0
        let l = Double(locked ?? "0") ?? 0
        let b = Double(borrowed ?? "0") ?? 0
        let i = Double(interest ?? "0") ?? 0
        return f + l - b - i
    }
}

struct BinanceMarginAccountResponse: Decodable {
    let userAssets: [BinanceMarginAsset]?
}

struct BinanceAccountResponse: Decodable {
    let balances: [BinanceAssetBalance]
}

struct BinanceAPIErrorResponse: Decodable {
    let code: Int
    let msg: String
}

struct BinanceEquityQuote: Decodable {
    let symbol: String
    let bidPrice: String
    let askPrice: String

    var midpoint: Double? {
        guard let bid = Double(bidPrice), let ask = Double(askPrice), bid > 0, ask > 0 else { return nil }
        return (bid + ask) / 2
    }
}

private struct BinanceEquityOrder: Decodable {
    let symbol: String
    let side: String
    let filledQty: String
    let filledTotal: String
    let fee: String?
    let quote: String?
    let status: String
    let createdAt: Int64?
}

private struct BinanceEquityOrderHistoryResponse: Decodable {
    let rows: [BinanceEquityOrder]
}

struct BinanceEquityCostBasis {
    let averagePrice: Double
    let purchaseDate: Date?
    /// The quantity that the reconstructed ledger actually covers. When this is
    /// less than the current balance, the caller splits the holding so the
    /// covered portion gets a real average price and the rest stays "unknown cost".
    let coveredQuantity: Double
}

private struct BinanceSpotTrade: Decodable {
    let id: Int64?
    let price: String
    let qty: String
    let quoteQty: String
    let commission: String
    let commissionAsset: String
    let isBuyer: Bool
    let time: Int64
}

private struct BinanceDepositRecord: Decodable {
    let coin: String
    let status: Int
    let insertTime: Int64
}

private struct BinanceConvertTrade: Decodable {
    let toAsset: String
    let createTime: Int64
}

private struct BinanceConvertTradeResponse: Decodable {
    let list: [BinanceConvertTrade]?
}

/// Stablecoins pegged 1:1 to USD that Binance serves directly (or legacy delisted
/// tokens still redeemable at $1). Used for quote fallbacks and holding mapping.
enum BinanceStablecoin {
    static let usdPegged: Set<String> = [
        "USDT", "USD", "BUSD", "USDC", "DAI", "TUSD", "FDUSD", "USDP", "PAXG"
    ]

    static func isUSDPegged(_ asset: String) -> Bool {
        usdPegged.contains(asset.uppercased())
    }
}

class BinanceAPIService {
    static let shared = BinanceAPIService()
    private let baseURL = "https://api.binance.com"
    private var timeOffset: Int64 = 0

    private func cleanAssetName(_ name: String) -> String {
        var cleanAsset = name.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if cleanAsset.hasPrefix("LD") && cleanAsset.count > 3 {
            cleanAsset = String(cleanAsset.dropFirst(2))
        }
        return cleanAsset
    }

    /// Reconciles Spot and Simple Earn without counting legacy `LD...` wrapper
    /// balances twice. Binance exposes the same Earn position both as (for
    /// example) `LDBTC` in `/api/v3/account` and `BTC` in Simple Earn. Prefer
    /// the richer Earn value; retain the LD quantity only as an API-failure
    /// fallback when no matching Earn row was returned.
    static func mergeSpotAndEarnBalances(
        spot: [BinanceAssetBalance],
        earn: [BinanceEarnPosition]
    ) -> [String: Double] {
        var earnBalances: [String: Double] = [:]
        for asset in earn {
            let qty = asset.totalQuantity
            guard qty >= 1e-8 else { continue }
            var name = asset.asset.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            if name.hasPrefix("LD"), name.count > 3 {
                name = String(name.dropFirst(2))
            }
            earnBalances[name, default: 0] += qty
        }

        var balances: [String: Double] = [:]
        for asset in spot {
            let qty = asset.totalQuantity
            guard qty >= 1e-8 else { continue }
            let rawName = asset.asset.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            if rawName.hasPrefix("LD"), rawName.count > 3 {
                let baseName = String(rawName.dropFirst(2))
                guard earnBalances[baseName] == nil else { continue }
                balances[baseName, default: 0] += qty
            } else {
                balances[rawName, default: 0] += qty
            }
        }

        for (asset, qty) in earnBalances {
            balances[asset, default: 0] += qty
        }
        return balances
    }

    /// Binance Stocks Trading uses the underlying US equity symbol (for
    /// example GOOGL), while the account balance endpoint exposes it as
    /// EQ_GOOGL. Keep this mapping local to the equity API path.
    private func equitySymbol(from balanceAsset: String) -> String? {
        let upper = balanceAsset.uppercased()
        guard upper.hasPrefix("EQ_"), upper.count > 3 else { return nil }
        return String(upper.dropFirst(3))
    }

    func fetchEquityQuote(apiKey: String, symbol: String) async -> BinanceEquityQuote? {
        var components = URLComponents(string: "\(baseURL)/sapi/v1/equity/market/quote")
        components?.queryItems = [URLQueryItem(name: "symbol", value: symbol.uppercased())]
        guard let url = components?.url else { return nil }

        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "X-MBX-APIKEY")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(BinanceEquityQuote.self, from: data)
    }

    /// Returns weighted average cost from Binance Stocks Trading order history.
    /// Filled BUY orders add cost; SELL orders remove shares at the running
    /// average cost. Fees are included when Binance reports them in the quote
    /// currency, which is the format currently returned by this endpoint.
    private func fetchEquityCostBasis(
        apiKey: String,
        secretKey: String,
        symbol: String,
        timestamp: Int64
    ) async -> BinanceEquityCostBasis? {
        let recvWindow = 5000
        let queryString = "symbol=\(symbol)&startTime=0&endTime=\(timestamp)&page=1&size=100&recvWindow=\(recvWindow)&timestamp=\(timestamp)"
        guard let signature = hmacHMAC256(message: queryString, secret: secretKey),
              let url = URL(string: "\(baseURL)/sapi/v1/equity/order/history?\(queryString)&signature=\(signature)") else {
            return nil
        }

        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "X-MBX-APIKEY")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200,
              let history = try? JSONDecoder().decode(BinanceEquityOrderHistoryResponse.self, from: data) else {
            return nil
        }

        var quantity = 0.0
        var cost = 0.0
        var firstBuyDate: Date?

        for order in history.rows.sorted(by: { ($0.createdAt ?? 0) < ($1.createdAt ?? 0) }) {
            guard order.status.uppercased() == "FILLED",
                  let filledQty = Double(order.filledQty), filledQty > 0,
                  let filledTotal = Double(order.filledTotal), filledTotal >= 0 else { continue }

            if order.side.uppercased() == "BUY" {
                let fee = Double(order.fee ?? "0") ?? 0
                quantity += filledQty
                cost += filledTotal + fee
                if firstBuyDate == nil, let createdAt = order.createdAt {
                    firstBuyDate = Date(timeIntervalSince1970: TimeInterval(createdAt) / 1000)
                }
            } else if order.side.uppercased() == "SELL", quantity > 0 {
                let removed = min(quantity, filledQty)
                cost -= (cost / quantity) * removed
                quantity -= removed
            }
        }

        guard quantity > 0, cost > 0 else { return nil }
        return BinanceEquityCostBasis(averagePrice: cost / quantity, purchaseDate: firstBuyDate, coveredQuantity: quantity)
    }

    private func fetchEquityCostBases(
        apiKey: String,
        secretKey: String,
        assets: [(name: String, quantity: Double)],
        timestamp: Int64
    ) async -> [String: BinanceEquityCostBasis] {
        await withTaskGroup(of: (String, BinanceEquityCostBasis?).self, returning: [String: BinanceEquityCostBasis].self) { group in
            for asset in assets {
                guard let symbol = equitySymbol(from: asset.name) else { continue }
                group.addTask {
                    let basis = await self.fetchEquityCostBasis(
                        apiKey: apiKey,
                        secretKey: secretKey,
                        symbol: symbol,
                        timestamp: timestamp
                    )
                    return (asset.name, basis)
                }
            }

            var result: [String: BinanceEquityCostBasis] = [:]
            for await (assetName, basis) in group {
                if let basis { result[assetName] = basis }
            }
            return result
        }
    }

    /// USD-pegged quote assets used to reconstruct Spot cost basis. Any of
    /// these pairs whose trade history is reconstructed shares the same unit,
    /// so costs stay comparable across pairs without FX conversion.
    private static let spotUSDQuoteAssets = ["USDT", "USDC", "FDUSD", "TUSD", "BUSD", "USDP", "DAI", "USD"]

    private struct BinanceExchangeSymbol: Decodable {
        let symbol: String
    }
    private struct BinanceExchangeInfo: Decodable {
        let symbols: [BinanceExchangeSymbol]
    }

    /// Public exchangeInfo lists every tradable pair (including delisted ones,
    /// whose old fills may still matter for cost basis), so the reconstruction
    /// only calls myTrades for pairs that actually exist.
    private func fetchValidSpotPairs() async -> Set<String> {
        guard let url = URL(string: "\(baseURL)/api/v3/exchangeInfo") else { return [] }
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200,
              let info = try? JSONDecoder().decode(BinanceExchangeInfo.self, from: data) else { return [] }
        return Set(info.symbols.map(\.symbol))
    }

    private func fetchSpotTrades(
        apiKey: String,
        secretKey: String,
        pair: String,
        fromId: Int64,
        timestamp: Int64
    ) async -> [BinanceSpotTrade] {
        let queryString = "symbol=\(pair)&fromId=\(fromId)&limit=1000&recvWindow=5000&timestamp=\(timestamp)"
        guard let signature = hmacHMAC256(message: queryString, secret: secretKey),
              let url = URL(string: "\(baseURL)/api/v3/myTrades?\(queryString)&signature=\(signature)") else { return [] }

        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "X-MBX-APIKEY")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200,
              let trades = try? JSONDecoder().decode([BinanceSpotTrade].self, from: data) else { return [] }
        return trades
    }

    /// Derives a cost basis from Spot fills. When the trade ledger only covers
    /// part of the current balance (coins deposited or acquired outside Spot,
    /// e.g. Simple Earn subscriptions), it returns the basis for the covered
    /// portion and lets `fetchAccountBalances` split the holding — it never
    /// extrapolates the small known purchase over the untracked remainder.
    private func fetchSpotCostBasis(
        apiKey: String,
        secretKey: String,
        asset: String,
        currentQuantity: Double,
        timestamp: Int64,
        validPairs: Set<String>
    ) async -> BinanceEquityCostBasis? {
        var allTrades: [BinanceSpotTrade] = []

        for quoteAsset in Self.spotUSDQuoteAssets {
            let pair = "\(asset)\(quoteAsset)"
            guard validPairs.contains(pair) else { continue }
            var fromId: Int64 = 0
            var pageTrades: [BinanceSpotTrade] = []
            repeat {
                pageTrades = await fetchSpotTrades(apiKey: apiKey, secretKey: secretKey, pair: pair, fromId: fromId, timestamp: timestamp)
                guard !pageTrades.isEmpty else { break }
                allTrades.append(contentsOf: pageTrades)
                let lastId = pageTrades.compactMap(\.id).max() ?? (fromId - 1)
                fromId = lastId + 1
            } while pageTrades.count >= 1000
        }

        var quantity = 0.0
        var cost = 0.0
        var firstBuyDate: Date?
        let quoteAssets = Set(Self.spotUSDQuoteAssets)

        for trade in allTrades.sorted(by: { $0.time < $1.time }) {
            guard let qty = Double(trade.qty), qty > 0,
                  let quoteQty = Double(trade.quoteQty), quoteQty >= 0 else { continue }

            if trade.isBuyer {
                let baseCommission = trade.commissionAsset.uppercased() == asset
                    ? (Double(trade.commission) ?? 0)
                    : 0
                let quoteCommission = quoteAssets.contains(trade.commissionAsset.uppercased())
                    ? (Double(trade.commission) ?? 0)
                    : 0
                quantity += max(0, qty - baseCommission)
                cost += quoteQty + quoteCommission
                if firstBuyDate == nil {
                    firstBuyDate = Date(timeIntervalSince1970: TimeInterval(trade.time) / 1000)
                }
            } else if quantity > 0 {
                let removed = min(quantity, qty)
                cost -= (cost / quantity) * removed
                quantity -= removed
            }
        }

        guard quantity > 0, cost > 0, currentQuantity > 0 else { return nil }
        let coverage = quantity / currentQuantity
        guard coverage <= 1.05 else { return nil }
        return BinanceEquityCostBasis(averagePrice: cost / quantity, purchaseDate: firstBuyDate, coveredQuantity: quantity)
    }

    private func fetchSpotCostBases(
        apiKey: String,
        secretKey: String,
        assets: [(name: String, quantity: Double)],
        timestamp: Int64,
        validPairs: Set<String>
    ) async -> [String: BinanceEquityCostBasis] {
        await withTaskGroup(of: (String, BinanceEquityCostBasis?).self, returning: [String: BinanceEquityCostBasis].self) { group in
            for asset in assets {
                group.addTask {
                    let basis = await self.fetchSpotCostBasis(
                        apiKey: apiKey,
                        secretKey: secretKey,
                        asset: asset.name,
                        currentQuantity: asset.quantity,
                        timestamp: timestamp,
                        validPairs: validPairs
                    )
                    return (asset.name, basis)
                }
            }

            var result: [String: BinanceEquityCostBasis] = [:]
            for await (assetName, basis) in group {
                if let basis { result[assetName] = basis }
            }
            return result
        }
    }

    /// Fetches successful crypto deposit history over the past 2 years (chunked in 90-day windows)
    func fetchDepositDates(apiKey: String, secretKey: String, timestamp: Int64) async -> [String: Date] {
        let ninetyDaysMs: Int64 = 90 * 86400 * 1000
        let twoYearsAgo = timestamp - (730 * 86400 * 1000)
        var windows: [(start: Int64, end: Int64)] = []
        var curEnd = timestamp
        while curEnd > twoYearsAgo {
            let curStart = max(curEnd - ninetyDaysMs, twoYearsAgo)
            windows.append((start: curStart, end: curEnd))
            curEnd = curStart
        }

        return await withTaskGroup(of: [String: Date].self, returning: [String: Date].self) { group in
            for window in windows {
                group.addTask {
                    let queryString = "status=1&startTime=\(window.start)&endTime=\(window.end)&recvWindow=5000&timestamp=\(timestamp)"
                    guard let signature = self.hmacHMAC256(message: queryString, secret: secretKey),
                          let url = URL(string: "\(self.baseURL)/sapi/v1/capital/deposit/hisrec?\(queryString)&signature=\(signature)") else {
                        return [:]
                    }
                    var request = URLRequest(url: url)
                    request.setValue(apiKey, forHTTPHeaderField: "X-MBX-APIKEY")
                    guard let (data, response) = try? await URLSession.shared.data(for: request),
                          let httpResponse = response as? HTTPURLResponse,
                          httpResponse.statusCode == 200,
                          let records = try? JSONDecoder().decode([BinanceDepositRecord].self, from: data) else {
                        return [:]
                    }
                    var dates: [String: Date] = [:]
                    for r in records where r.status == 1 {
                        let asset = self.cleanAssetName(r.coin)
                        let date = Date(timeIntervalSince1970: TimeInterval(r.insertTime) / 1000)
                        if let existing = dates[asset] {
                            dates[asset] = min(existing, date)
                        } else {
                            dates[asset] = date
                        }
                    }
                    return dates
                }
            }

            var merged: [String: Date] = [:]
            for await dates in group {
                for (asset, date) in dates {
                    if let existing = merged[asset] {
                        merged[asset] = min(existing, date)
                    } else {
                        merged[asset] = date
                    }
                }
            }
            return merged
        }
    }

    /// Fetches Binance Convert trade history over the past year (chunked in 30-day windows)
    func fetchConvertDates(apiKey: String, secretKey: String, timestamp: Int64) async -> [String: Date] {
        let thirtyDaysMs: Int64 = 30 * 86400 * 1000
        let oneYearAgo = timestamp - (365 * 86400 * 1000)
        var windows: [(start: Int64, end: Int64)] = []
        var curEnd = timestamp
        while curEnd > oneYearAgo {
            let curStart = max(curEnd - thirtyDaysMs, oneYearAgo)
            windows.append((start: curStart, end: curEnd))
            curEnd = curStart
        }

        return await withTaskGroup(of: [String: Date].self, returning: [String: Date].self) { group in
            for window in windows {
                group.addTask {
                    let queryString = "startTime=\(window.start)&endTime=\(window.end)&limit=1000&recvWindow=5000&timestamp=\(timestamp)"
                    guard let signature = self.hmacHMAC256(message: queryString, secret: secretKey),
                          let url = URL(string: "\(self.baseURL)/sapi/v1/convert/tradeFlow?\(queryString)&signature=\(signature)") else {
                        return [:]
                    }
                    var request = URLRequest(url: url)
                    request.setValue(apiKey, forHTTPHeaderField: "X-MBX-APIKEY")
                    guard let (data, response) = try? await URLSession.shared.data(for: request),
                          let httpResponse = response as? HTTPURLResponse,
                          httpResponse.statusCode == 200,
                          let res = try? JSONDecoder().decode(BinanceConvertTradeResponse.self, from: data),
                          let list = res.list else {
                        return [:]
                    }
                    var dates: [String: Date] = [:]
                    for r in list {
                        let asset = self.cleanAssetName(r.toAsset)
                        let date = Date(timeIntervalSince1970: TimeInterval(r.createTime) / 1000)
                        if let existing = dates[asset] {
                            dates[asset] = min(existing, date)
                        } else {
                            dates[asset] = date
                        }
                    }
                    return dates
                }
            }

            var merged: [String: Date] = [:]
            for await dates in group {
                for (asset, date) in dates {
                    if let existing = merged[asset] {
                        merged[asset] = min(existing, date)
                    } else {
                        merged[asset] = date
                    }
                }
            }
            return merged
        }
    }

    /// Fetch Binance server time to calculate clock offset and prevent timestamp errors (-1021)
    func syncServerTime() async {
        guard let url = URL(string: "\(baseURL)/api/v3/time") else { return }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            if let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 200 {
                if let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let serverTime = dict["serverTime"] as? Int64 {
                    let localTime = Int64(Date().timeIntervalSince1970 * 1000)
                    self.timeOffset = serverTime - localTime
                }
            }
        } catch {
            print("[BinanceAPI] Failed to sync server time: \(error)")
        }
    }

    func fetchAccountBalances(apiKey: String, secretKey: String) async throws -> [Holding] {
        await syncServerTime()

        let endpoint = "/api/v3/account"
        let timestamp = Int64(Date().timeIntervalSince1970 * 1000) + timeOffset
        let recvWindow = 5000

        let queryString = "recvWindow=\(recvWindow)&timestamp=\(timestamp)"
        guard let signature = hmacHMAC256(message: queryString, secret: secretKey) else {
            throw BinanceAPIError.invalidCredentials
        }

        let fullURLString = "\(baseURL)\(endpoint)?\(queryString)&signature=\(signature)"
        guard let url = URL(string: fullURLString) else {
            throw BinanceAPIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(apiKey, forHTTPHeaderField: "X-MBX-APIKEY")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Fetch Spot, Funding (P2P), UserAsset, Earn, Futures, Margin, Deposits, and Convert in parallel
        let spotRequest = request
        async let spotTask = URLSession.shared.data(for: spotRequest)
        async let fundingTask = fetchFundingBalances(apiKey: apiKey, secretKey: secretKey, timestamp: timestamp)
        async let userAssetTask = fetchUserAssets(apiKey: apiKey, secretKey: secretKey, timestamp: timestamp)
        async let earnTask = fetchEarnBalances(apiKey: apiKey, secretKey: secretKey, timestamp: timestamp)
        async let futuresTask = fetchFuturesBalances(apiKey: apiKey, secretKey: secretKey, timestamp: timestamp)
        async let marginTask = fetchMarginBalances(apiKey: apiKey, secretKey: secretKey, timestamp: timestamp)
        async let depositTask = fetchDepositDates(apiKey: apiKey, secretKey: secretKey, timestamp: timestamp)
        async let convertTask = fetchConvertDates(apiKey: apiKey, secretKey: secretKey, timestamp: timestamp)

        let (data, response) = try await spotTask
        let fundingAssets = await fundingTask
        let userAssets = await userAssetTask
        let earnAssets = await earnTask
        let futuresAssets = await futuresTask
        let marginAssets = await marginTask
        let depositDates = await depositTask
        let convertDates = await convertTask

        var acquisitionDates: [String: Date] = depositDates
        for (asset, date) in convertDates {
            if let existing = acquisitionDates[asset] {
                acquisitionDates[asset] = min(existing, date)
            } else {
                acquisitionDates[asset] = date
            }
        }

        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
            if let apiErr = try? JSONDecoder().decode(BinanceAPIErrorResponse.self, from: data) {
                throw BinanceAPIError.apiError(code: apiErr.code, message: apiErr.msg)
            } else {
                throw BinanceAPIError.networkError("HTTP Status \(httpResponse.statusCode)")
            }
        }

        guard let account = try? JSONDecoder().decode(BinanceAccountResponse.self, from: data) else {
            throw BinanceAPIError.decodingError
        }

        // 1. Reconcile Spot and Simple Earn. Legacy LD-prefixed Spot wrappers
        // mirror Earn positions and must not be added a second time.
        var aggregatedBalances = Self.mergeSpotAndEarnBalances(
            spot: account.balances,
            earn: earnAssets
        )

        // 2. Process Funding Wallet balances (P2P purchases)
        for asset in fundingAssets {
            let qty = asset.totalQuantity
            guard qty >= 1e-8 else { continue }
            let clean = cleanAssetName(asset.asset)
            aggregatedBalances[clean, default: 0.0] += qty
        }

        // 3. Process USD-M Futures Balances (wallet balance + unrealized P&L)
        for asset in futuresAssets {
            let qty = asset.totalQuantity
            guard qty >= 1e-8 else { continue }
            let clean = cleanAssetName(asset.asset)
            aggregatedBalances[clean, default: 0.0] += qty
        }

        // 4. Process Margin Balances (net equity = free + locked - borrowed - interest)
        for asset in marginAssets {
            let qty = asset.totalQuantity
            guard qty >= 1e-8 else { continue }
            let clean = cleanAssetName(asset.asset)
            aggregatedBalances[clean, default: 0.0] += qty
        }

        // 5. ETH Staking is fetched separately so BETH/WBETH from the staking
        //    account can be de-duplicated against Flexible/Locked Earn entries.
        //    If the same wrapped token appears in both (e.g. WBETH staked in
        //    Simple Earn), taking the max avoids double-counting the same asset.
        let stakingPositions = await fetchEthStakingBalances(apiKey: apiKey, secretKey: secretKey, timestamp: timestamp)
        for position in stakingPositions {
            let qty = position.totalQuantity
            guard qty >= 1e-8 else { continue }
            let clean = cleanAssetName(position.asset)
            let current = aggregatedBalances[clean] ?? 0
            aggregatedBalances[clean] = max(current, qty)
        }

        // 6. getUserAsset is an aggregate endpoint covering all user wallets.
        //    Use it as the authoritative source: when it reports MORE of an asset
        //    than the detailed wallet fetches combined (because a partial failure
        //    returned incomplete spot/funding data), take the higher figure.
        for asset in userAssets {
            let qty = asset.totalQuantity
            guard qty >= 1e-8 else { continue }
            let clean = cleanAssetName(asset.asset)
            let current = aggregatedBalances[clean] ?? 0
            aggregatedBalances[clean] = max(current, qty)
        }

        let equityAssets = aggregatedBalances.compactMap { name, qty in
            name.hasPrefix("EQ_") ? (name: name, quantity: qty) : nil
        }
        let equityCosts = await fetchEquityCostBases(
            apiKey: apiKey,
            secretKey: secretKey,
            assets: equityAssets,
            timestamp: timestamp
        )
        let spotAssets: [(name: String, quantity: Double)] = aggregatedBalances.compactMap { name, qty in
            guard !name.hasPrefix("EQ_"), !BinanceStablecoin.isUSDPegged(name) else { return nil }
            return (name: name, quantity: qty)
        }
        let spotCosts = await fetchSpotCostBases(
            apiKey: apiKey,
            secretKey: secretKey,
            assets: spotAssets,
            timestamp: timestamp,
            validPairs: await fetchValidSpotPairs()
        )

        return aggregatedBalances.flatMap { (assetName, qty) -> [Holding] in
            buildHoldings(
                assetName: assetName,
                quantity: qty,
                equityCosts: equityCosts,
                spotCosts: spotCosts,
                acquisitionDates: acquisitionDates
            )
        }
    }

    /// Builds the display holdings for one Binance asset. When Spot only covers
    /// part of the balance, the holding is split so the reconstructed portion
    /// shows a real average price and the untracked remainder stays "unknown
    /// cost" (never fabricated). Equity and USD-pegged assets are never split.
    func buildHoldings(
        assetName: String,
        quantity: Double,
        equityCosts: [String: BinanceEquityCostBasis],
        spotCosts: [String: BinanceEquityCostBasis],
        acquisitionDates: [String: Date] = [:]
    ) -> [Holding] {
        guard quantity >= 1e-8 else { return [] }
        let rawSymbol: String
        if assetName.hasPrefix("EQ_") && assetName.count > 3 {
            let base = assetName.hasSuffix("-USD") ? String(assetName.dropLast(4)) : assetName
            rawSymbol = String(base.dropFirst(3))
        } else if BinanceStablecoin.isUSDPegged(assetName) {
            rawSymbol = "\(assetName)-USD"
        } else if assetName.contains("-") {
            rawSymbol = assetName
        } else {
            rawSymbol = "\(assetName)-USD"
        }
        let symbol = StockService.canonicalSymbol(for: rawSymbol)

        let isEquity = assetName.hasPrefix("EQ_")
        let basis = equityCosts[assetName] ?? spotCosts[assetName]
        let acquisitionDate = acquisitionDates[assetName]
        let effectivePurchaseDate: Date? = {
            if let bDate = basis?.purchaseDate, let aDate = acquisitionDate {
                return min(bDate, aDate)
            }
            return basis?.purchaseDate ?? acquisitionDate
        }()

        if let basis,
           !isEquity,
           !BinanceStablecoin.isUSDPegged(assetName),
           basis.coveredQuantity > 0 {
            let covered = min(basis.coveredQuantity, quantity)
            let remainder = quantity - covered
            // Skip dust remainders (≤1% of the balance) so they don't show up
            // as a separate zero-P&L row.
            if remainder > 0, remainder / quantity > 0.01 {
                return [
                    Holding(
                        id: UUID(),
                        symbol: symbol,
                        quantity: covered,
                        avgPrice: basis.averagePrice,
                        purchaseDate: effectivePurchaseDate
                    ),
                    Holding(
                        id: UUID(),
                        symbol: symbol,
                        quantity: remainder,
                        avgPrice: .nan,
                        purchaseDate: acquisitionDate
                    )
                ]
            }
        }

        return [Holding(
            id: UUID(),
            symbol: symbol,
            quantity: quantity,
            avgPrice: basis?.averagePrice
                ?? (BinanceStablecoin.isUSDPegged(assetName) ? 1.0 : .nan),
            purchaseDate: effectivePurchaseDate
        )]
    }

    /// Fetch balances from Binance Funding Wallet (P2P Wallet)
    func fetchFundingBalances(apiKey: String, secretKey: String, timestamp: Int64? = nil) async -> [BinanceFundingAsset] {
        let endpoint = "/sapi/v1/asset/get-funding-asset"
        let ts = timestamp ?? (Int64(Date().timeIntervalSince1970 * 1000) + timeOffset)
        let recvWindow = 5000

        let bodyString = "recvWindow=\(recvWindow)&timestamp=\(ts)"
        guard let signature = hmacHMAC256(message: bodyString, secret: secretKey) else {
            print("[BinanceAPI] Funding Wallet: HMAC signature failed")
            return []
        }

        let fullQuery = "\(bodyString)&signature=\(signature)"
        guard let url = URL(string: "\(baseURL)\(endpoint)?\(fullQuery)") else {
            print("[BinanceAPI] Funding Wallet: Invalid URL")
            return []
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "X-MBX-APIKEY")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = fullQuery.data(using: .utf8)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let httpResp = response as? HTTPURLResponse {
                if httpResp.statusCode == 200 {
                    if let decoded = try? JSONDecoder().decode([BinanceFundingAsset].self, from: data) {
                        print("[BinanceAPI] Funding Wallet: fetched \(decoded.count) assets")
                        return decoded
                    } else {
                        let rawJSON = String(data: data, encoding: .utf8) ?? ""
                        print("[BinanceAPI] Funding Wallet: decode failed, raw: \(rawJSON.prefix(500))")
                    }
                } else {
                    let errMsg = String(data: data, encoding: .utf8) ?? ""
                    print("[BinanceAPI] Funding Wallet HTTP \(httpResp.statusCode): \(errMsg)")
                }
            }
        } catch {
            print("[BinanceAPI] Funding wallet fetch error: \(error.localizedDescription)")
        }
        return []
    }

    /// Fetch balances from Binance User Asset API (covering all user wallets)
    func fetchUserAssets(apiKey: String, secretKey: String, timestamp: Int64? = nil) async -> [BinanceUserAsset] {
        let endpoint = "/sapi/v3/asset/getUserAsset"
        let ts = timestamp ?? (Int64(Date().timeIntervalSince1970 * 1000) + timeOffset)
        let recvWindow = 5000

        let bodyString = "recvWindow=\(recvWindow)&timestamp=\(ts)"
        guard let signature = hmacHMAC256(message: bodyString, secret: secretKey) else {
            return []
        }

        let fullQuery = "\(bodyString)&signature=\(signature)"
        guard let url = URL(string: "\(baseURL)\(endpoint)?\(fullQuery)") else {
            return []
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "X-MBX-APIKEY")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = fullQuery.data(using: .utf8)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let httpResp = response as? HTTPURLResponse {
                if httpResp.statusCode == 200 {
                    return (try? JSONDecoder().decode([BinanceUserAsset].self, from: data)) ?? []
                } else {
                    let errMsg = String(data: data, encoding: .utf8) ?? ""
                    print("[BinanceAPI] User Asset HTTP \(httpResp.statusCode): \(errMsg)")
                }
            }
        } catch {
            print("[BinanceAPI] User asset fetch error: \(error.localizedDescription)")
        }
        return []
    }

    /// Fetch Simple Earn Flexible & Locked Positions (excludes ETH Staking,
    /// which is fetched separately for de-duplication).
    func fetchEarnBalances(apiKey: String, secretKey: String, timestamp: Int64? = nil) async -> [BinanceEarnPosition] {
        let ts = timestamp ?? (Int64(Date().timeIntervalSince1970 * 1000) + timeOffset)
        let recvWindow = 5000
        let queryString = "recvWindow=\(recvWindow)&timestamp=\(ts)"
        guard let signature = hmacHMAC256(message: queryString, secret: secretKey) else {
            print("[BinanceAPI] Earn: HMAC signature failed")
            return []
        }

        var results: [BinanceEarnPosition] = []

        // Flexible Earn
        if let url = URL(string: "\(baseURL)/sapi/v1/simple-earn/flexible/position?\(queryString)&signature=\(signature)") {
            var req = URLRequest(url: url)
            req.setValue(apiKey, forHTTPHeaderField: "X-MBX-APIKEY")
            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                if let httpResp = resp as? HTTPURLResponse {
                    if httpResp.statusCode == 200 {
                        if let rows = decodeEarnPositions(from: data, label: "Flexible Earn") {
                            results.append(contentsOf: rows)
                        }
                    } else {
                        let errMsg = String(data: data, encoding: .utf8) ?? ""
                        print("[BinanceAPI] Flexible Earn HTTP \(httpResp.statusCode): \(errMsg)")
                    }
                }
            } catch {
                print("[BinanceAPI] Flexible Earn fetch error: \(error.localizedDescription)")
            }
        }

        // Locked Earn
        if let url = URL(string: "\(baseURL)/sapi/v1/simple-earn/locked/position?\(queryString)&signature=\(signature)") {
            var req = URLRequest(url: url)
            req.setValue(apiKey, forHTTPHeaderField: "X-MBX-APIKEY")
            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                if let httpResp = resp as? HTTPURLResponse {
                    if httpResp.statusCode == 200 {
                        if let rows = decodeEarnPositions(from: data, label: "Locked Earn") {
                            results.append(contentsOf: rows)
                        }
                    } else {
                        let errMsg = String(data: data, encoding: .utf8) ?? ""
                        print("[BinanceAPI] Locked Earn HTTP \(httpResp.statusCode): \(errMsg)")
                    }
                }
            } catch {
                print("[BinanceAPI] Locked Earn fetch error: \(error.localizedDescription)")
            }
        }

        // Locked Staking (legacy endpoint — covers older locked staking positions)
        if let url = URL(string: "\(baseURL)/sapi/v1/staking/position?\(queryString)&signature=\(signature)") {
            var req = URLRequest(url: url)
            req.setValue(apiKey, forHTTPHeaderField: "X-MBX-APIKEY")
            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                if let httpResp = resp as? HTTPURLResponse {
                    if httpResp.statusCode == 200 {
                        if let rows = decodeEarnPositions(from: data, label: "Staking") {
                            results.append(contentsOf: rows)
                        }
                    } else {
                        let errMsg = String(data: data, encoding: .utf8) ?? ""
                        print("[BinanceAPI] Staking HTTP \(httpResp.statusCode): \(errMsg)")
                    }
                }
            } catch {
                print("[BinanceAPI] Staking fetch error: \(error.localizedDescription)")
            }
        }

        // BNB Vault (part of Simple Earn ecosystem)
        if let url = URL(string: "\(baseURL)/sapi/v1/simple-earn/account?\(queryString)&signature=\(signature)") {
            var req = URLRequest(url: url)
            req.setValue(apiKey, forHTTPHeaderField: "X-MBX-APIKEY")
            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                if let httpResp = resp as? HTTPURLResponse {
                    if httpResp.statusCode == 200 {
                        if let rows = decodeEarnPositions(from: data, label: "BNB Vault") {
                            results.append(contentsOf: rows)
                        }
                    } else {
                        let errMsg = String(data: data, encoding: .utf8) ?? ""
                        print("[BinanceAPI] BNB Vault HTTP \(httpResp.statusCode): \(errMsg)")
                    }
                }
            } catch {
                print("[BinanceAPI] BNB Vault fetch error: \(error.localizedDescription)")
            }
        }

        print("[BinanceAPI] Earn total: \(results.count) positions across all earn products")
        return results
    }

    /// Decode earn positions from API response data, trying multiple response shapes.
    private func decodeEarnPositions(from data: Data, label: String) -> [BinanceEarnPosition]? {
        // Try standard BinanceEarnResponse with "rows" key
        if let earnResp = try? JSONDecoder().decode(BinanceEarnResponse.self, from: data), let rows = earnResp.rows {
            print("[BinanceAPI] \(label): decoded \(rows.count) rows via BinanceEarnResponse")
            return rows
        }
        // Try direct array of BinanceEarnPosition
        if let positions = try? JSONDecoder().decode([BinanceEarnPosition].self, from: data) {
            print("[BinanceAPI] \(label): decoded \(positions.count) positions via direct array")
            return positions
        }
        let rawJSON = String(data: data, encoding: .utf8) ?? "nil"
        print("[BinanceAPI] \(label): decode failed, response shape unexpected. Raw: \(rawJSON.prefix(500))")
        return nil
    }

    /// Fetch ETH Staking Account (BETH / WBETH) separately from Simple Earn so
    /// overlapping wrapped-token balances can be de-duplicated downstream.
    func fetchEthStakingBalances(apiKey: String, secretKey: String, timestamp: Int64? = nil) async -> [BinanceEarnPosition] {
        let ts = timestamp ?? (Int64(Date().timeIntervalSince1970 * 1000) + timeOffset)
        let recvWindow = 5000
        let queryString = "recvWindow=\(recvWindow)&timestamp=\(ts)"
        guard let signature = hmacHMAC256(message: queryString, secret: secretKey) else { return [] }

        var results: [BinanceEarnPosition] = []
        if let url = URL(string: "\(baseURL)/sapi/v1/eth-staking/account?\(queryString)&signature=\(signature)") {
            var req = URLRequest(url: url)
            req.setValue(apiKey, forHTTPHeaderField: "X-MBX-APIKEY")
            if let (data, resp) = try? await URLSession.shared.data(for: req),
               let httpResp = resp as? HTTPURLResponse, httpResp.statusCode == 200,
               let ethStakingResp = try? JSONDecoder().decode(BinanceEthStakingAccountResponse.self, from: data) {
                if let beth = ethStakingResp.holdingBETH, (Double(beth) ?? 0) > 0 {
                    results.append(BinanceEarnPosition(asset: "BETH", totalAmount: beth, amount: nil))
                }
                if let wbeth = ethStakingResp.holdingWBETH, (Double(wbeth) ?? 0) > 0 {
                    results.append(BinanceEarnPosition(asset: "WBETH", totalAmount: wbeth, amount: nil))
                }
            }
        }
        return results
    }

    /// Fetch USD-M Futures balances
    func fetchFuturesBalances(apiKey: String, secretKey: String, timestamp: Int64? = nil) async -> [BinanceFuturesAsset] {
        let ts = timestamp ?? (Int64(Date().timeIntervalSince1970 * 1000) + timeOffset)
        let recvWindow = 5000
        let queryString = "recvWindow=\(recvWindow)&timestamp=\(ts)"
        guard let signature = hmacHMAC256(message: queryString, secret: secretKey),
              let url = URL(string: "https://fapi.binance.com/fapi/v2/account?\(queryString)&signature=\(signature)") else { return [] }

        var req = URLRequest(url: url)
        req.setValue(apiKey, forHTTPHeaderField: "X-MBX-APIKEY")
        if let (data, resp) = try? await URLSession.shared.data(for: req),
           let httpResp = resp as? HTTPURLResponse, httpResp.statusCode == 200,
           let fResp = try? JSONDecoder().decode(BinanceFuturesAccountResponse.self, from: data),
           let assets = fResp.assets {
            return assets
        }
        return []
    }

    /// Fetch Cross Margin balances
    func fetchMarginBalances(apiKey: String, secretKey: String, timestamp: Int64? = nil) async -> [BinanceMarginAsset] {
        let ts = timestamp ?? (Int64(Date().timeIntervalSince1970 * 1000) + timeOffset)
        let recvWindow = 5000
        let queryString = "recvWindow=\(recvWindow)&timestamp=\(ts)"
        guard let signature = hmacHMAC256(message: queryString, secret: secretKey),
              let url = URL(string: "\(baseURL)/sapi/v1/margin/account?\(queryString)&signature=\(signature)") else { return [] }

        var req = URLRequest(url: url)
        req.setValue(apiKey, forHTTPHeaderField: "X-MBX-APIKEY")
        if let (data, resp) = try? await URLSession.shared.data(for: req),
           let httpResp = resp as? HTTPURLResponse, httpResp.statusCode == 200,
           let mResp = try? JSONDecoder().decode(BinanceMarginAccountResponse.self, from: data),
           let userAssets = mResp.userAssets {
            return userAssets
        }
        return []
    }

    /// Calculate HMAC-SHA256 signature for Binance API
    func hmacHMAC256(message: String, secret: String) -> String? {
        guard let secretData = secret.data(using: .utf8),
              let messageData = message.data(using: .utf8) else {
            return nil
        }

        var hmac = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        secretData.withUnsafeBytes { secretBytes in
            messageData.withUnsafeBytes { messageBytes in
                CCHmac(CCHmacAlgorithm(kCCHmacAlgSHA256),
                       secretBytes.baseAddress, secretData.count,
                       messageBytes.baseAddress, messageData.count,
                       &hmac)
            }
        }

        return hmac.map { String(format: "%02hhx", $0) }.joined()
    }
}
