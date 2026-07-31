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

    var totalQuantity: Double {
        let freeVal = Double(free ?? "0") ?? 0
        let lockedVal = Double(locked ?? "0") ?? 0
        return freeVal + lockedVal
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

    var totalQuantity: Double {
        return Double(walletBalance ?? "0") ?? 0
    }
}

struct BinanceFuturesAccountResponse: Decodable {
    let assets: [BinanceFuturesAsset]?
}

struct BinanceMarginAsset: Decodable {
    let asset: String
    let free: String?
    let locked: String?

    var totalQuantity: Double {
        let f = Double(free ?? "0") ?? 0
        let l = Double(locked ?? "0") ?? 0
        return f + l
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

class BinanceAPIService {
    static let shared = BinanceAPIService()
    private let baseURL = "https://api.binance.com"
    private var timeOffset: Int64 = 0

    private func cleanAssetName(_ name: String) -> String {
        var cleanAsset = name.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if cleanAsset.hasPrefix("LD") && cleanAsset.count > 2 {
            cleanAsset = String(cleanAsset.dropFirst(2))
        }
        return cleanAsset
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

        // Fetch Spot, Funding (P2P), UserAsset, Earn, Futures, and Margin in parallel
        let spotRequest = request
        async let spotTask = URLSession.shared.data(for: spotRequest)
        async let fundingTask = fetchFundingBalances(apiKey: apiKey, secretKey: secretKey, timestamp: timestamp)
        async let userAssetTask = fetchUserAssets(apiKey: apiKey, secretKey: secretKey, timestamp: timestamp)
        async let earnTask = fetchEarnBalances(apiKey: apiKey, secretKey: secretKey, timestamp: timestamp)
        async let futuresTask = fetchFuturesBalances(apiKey: apiKey, secretKey: secretKey, timestamp: timestamp)
        async let marginTask = fetchMarginBalances(apiKey: apiKey, secretKey: secretKey, timestamp: timestamp)

        let (data, response) = try await spotTask
        let fundingAssets = await fundingTask
        let userAssets = await userAssetTask
        let earnAssets = await earnTask
        let futuresAssets = await futuresTask
        let marginAssets = await marginTask

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

        var aggregatedBalances: [String: Double] = [:]

        // 1. Process Spot balances
        for asset in account.balances {
            let qty = asset.totalQuantity
            guard qty >= 1e-8 else { continue }
            let clean = cleanAssetName(asset.asset)
            aggregatedBalances[clean, default: 0.0] += qty
        }

        // 2. Process Funding Wallet balances (P2P purchases)
        for asset in fundingAssets {
            let qty = asset.totalQuantity
            guard qty >= 1e-8 else { continue }
            let clean = cleanAssetName(asset.asset)
            aggregatedBalances[clean, default: 0.0] += qty
        }

        // 3. Process Simple Earn Flexible & Locked Positions
        for asset in earnAssets {
            let qty = asset.totalQuantity
            guard qty >= 1e-8 else { continue }
            let clean = cleanAssetName(asset.asset)
            aggregatedBalances[clean, default: 0.0] += qty
        }

        // 4. Process USD-M Futures Balances
        for asset in futuresAssets {
            let qty = asset.totalQuantity
            guard qty >= 1e-8 else { continue }
            let clean = cleanAssetName(asset.asset)
            aggregatedBalances[clean, default: 0.0] += qty
        }

        // 5. Process Margin Balances
        for asset in marginAssets {
            let qty = asset.totalQuantity
            guard qty >= 1e-8 else { continue }
            let clean = cleanAssetName(asset.asset)
            aggregatedBalances[clean, default: 0.0] += qty
        }

        // 6. Process getUserAsset balances (fallback for any remaining user wallets)
        for asset in userAssets {
            let qty = asset.totalQuantity
            guard qty >= 1e-8 else { continue }
            let clean = cleanAssetName(asset.asset)
            if aggregatedBalances[clean] == nil {
                aggregatedBalances[clean] = qty
            }
        }

        return aggregatedBalances.compactMap { (assetName, qty) -> Holding? in
            let symbol: String
            if assetName == "USDT" || assetName == "USD" || assetName == "BUSD" || assetName == "USDC" {
                symbol = "\(assetName)-USD"
            } else if assetName.contains("-") {
                symbol = assetName
            } else {
                symbol = "\(assetName)-USD"
            }

            return Holding(
                id: UUID(),
                symbol: symbol,
                quantity: qty,
                avgPrice: 0.0
            )
        }
    }

    /// Fetch balances from Binance Funding Wallet (P2P Wallet)
    func fetchFundingBalances(apiKey: String, secretKey: String, timestamp: Int64? = nil) async -> [BinanceFundingAsset] {
        let endpoint = "/sapi/v1/asset/get-funding-asset"
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
                    return (try? JSONDecoder().decode([BinanceFundingAsset].self, from: data)) ?? []
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

    /// Fetch Simple Earn Flexible & Locked Positions
    func fetchEarnBalances(apiKey: String, secretKey: String, timestamp: Int64? = nil) async -> [BinanceEarnPosition] {
        let ts = timestamp ?? (Int64(Date().timeIntervalSince1970 * 1000) + timeOffset)
        let recvWindow = 5000
        let queryString = "recvWindow=\(recvWindow)&timestamp=\(ts)"
        guard let signature = hmacHMAC256(message: queryString, secret: secretKey) else { return [] }

        var results: [BinanceEarnPosition] = []

        // Flexible Earn
        if let url = URL(string: "\(baseURL)/sapi/v1/simple-earn/flexible/position?\(queryString)&signature=\(signature)") {
            var req = URLRequest(url: url)
            req.setValue(apiKey, forHTTPHeaderField: "X-MBX-APIKEY")
            if let (data, resp) = try? await URLSession.shared.data(for: req),
               let httpResp = resp as? HTTPURLResponse, httpResp.statusCode == 200,
               let earnResp = try? JSONDecoder().decode(BinanceEarnResponse.self, from: data),
               let rows = earnResp.rows {
                results.append(contentsOf: rows)
            }
        }

        // Locked Earn
        if let url = URL(string: "\(baseURL)/sapi/v1/simple-earn/locked/position?\(queryString)&signature=\(signature)") {
            var req = URLRequest(url: url)
            req.setValue(apiKey, forHTTPHeaderField: "X-MBX-APIKEY")
            if let (data, resp) = try? await URLSession.shared.data(for: req),
               let httpResp = resp as? HTTPURLResponse, httpResp.statusCode == 200,
               let earnResp = try? JSONDecoder().decode(BinanceEarnResponse.self, from: data),
               let rows = earnResp.rows {
                results.append(contentsOf: rows)
            }
        }

        // ETH Staking Account (BETH / WBETH)
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
