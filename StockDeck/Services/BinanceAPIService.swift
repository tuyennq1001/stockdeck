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
    let free: String
    let locked: String

    var totalQuantity: Double {
        let freeVal = Double(free) ?? 0
        let lockedVal = Double(locked) ?? 0
        return freeVal + lockedVal
    }
}

struct BinanceFundingAsset: Decodable {
    let asset: String
    let free: String
    let freeze: String?
    let withdrawing: String?

    var totalQuantity: Double {
        let freeVal = Double(free) ?? 0
        let freezeVal = Double(freeze ?? "0") ?? 0
        let withdrawingVal = Double(withdrawing ?? "0") ?? 0
        return freeVal + freezeVal + withdrawingVal
    }
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

    func fetchAccountBalances(apiKey: String, secretKey: String) async throws -> [Holding] {
        let endpoint = "/api/v3/account"
        let timestamp = Int64(Date().timeIntervalSince1970 * 1000)
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

        // Fetch Spot balances and Funding balances in parallel
        async let spotTask = URLSession.shared.data(for: request)
        async let fundingTask = fetchFundingBalances(apiKey: apiKey, secretKey: secretKey)

        let (data, response) = try await spotTask
        let fundingAssets = await fundingTask

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

        // 1. Process Spot & Simple Earn balances
        for asset in account.balances {
            let qty = asset.totalQuantity
            guard qty >= 1e-8 else { continue }

            var cleanAsset = asset.asset.uppercased()
            // Strip Binance Flexible Earn / Lending Deposit prefix (e.g. LDBTC -> BTC, LDUSDC -> USDC)
            if cleanAsset.hasPrefix("LD") && cleanAsset.count > 2 {
                cleanAsset = String(cleanAsset.dropFirst(2))
            }

            aggregatedBalances[cleanAsset, default: 0.0] += qty
        }

        // 2. Process Funding Wallet balances (P2P purchases)
        for asset in fundingAssets {
            let qty = asset.totalQuantity
            guard qty >= 1e-8 else { continue }

            var cleanAsset = asset.asset.uppercased()
            if cleanAsset.hasPrefix("LD") && cleanAsset.count > 2 {
                cleanAsset = String(cleanAsset.dropFirst(2))
            }

            aggregatedBalances[cleanAsset, default: 0.0] += qty
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
    func fetchFundingBalances(apiKey: String, secretKey: String) async -> [BinanceFundingAsset] {
        let endpoint = "/sapi/v1/asset/get-funding-asset"
        let timestamp = Int64(Date().timeIntervalSince1970 * 1000)
        let recvWindow = 5000

        let bodyString = "recvWindow=\(recvWindow)&timestamp=\(timestamp)"
        guard let signature = hmacHMAC256(message: bodyString, secret: secretKey) else {
            return []
        }

        let fullBody = "\(bodyString)&signature=\(signature)"
        guard let url = URL(string: "\(baseURL)\(endpoint)") else {
            return []
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "X-MBX-APIKEY")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = fullBody.data(using: .utf8)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 200 {
                return (try? JSONDecoder().decode([BinanceFundingAsset].self, from: data)) ?? []
            }
        } catch {
            print("Funding wallet fetch error: \(error.localizedDescription)")
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
