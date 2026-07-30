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

struct BinanceUserAsset: Decodable {
    let asset: String
    let free: String
    let locked: String?
    let freeze: String?
    let withdrawing: String?

    var totalQuantity: Double {
        let freeVal = Double(free) ?? 0
        let lockedVal = Double(locked ?? "0") ?? 0
        let freezeVal = Double(freeze ?? "0") ?? 0
        let withdrawingVal = Double(withdrawing ?? "0") ?? 0
        return freeVal + lockedVal + freezeVal + withdrawingVal
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

    private func cleanAssetName(_ name: String) -> String {
        var cleanAsset = name.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if cleanAsset.hasPrefix("LD") && cleanAsset.count > 2 {
            cleanAsset = String(cleanAsset.dropFirst(2))
        }
        return cleanAsset
    }

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

        // Fetch Spot, Funding (P2P), and UserAsset (All Wallets) in parallel
        let spotRequest = request
        async let spotTask = URLSession.shared.data(for: spotRequest)
        async let fundingTask = fetchFundingBalances(apiKey: apiKey, secretKey: secretKey)
        async let userAssetTask = fetchUserAssets(apiKey: apiKey, secretKey: secretKey)

        let (data, response) = try await spotTask
        let fundingAssets = await fundingTask
        let userAssets = await userAssetTask

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
            // If already present from spot, take the max or sum
            aggregatedBalances[clean] = max(aggregatedBalances[clean] ?? 0.0, qty)
        }

        // 3. Process getUserAsset balances (all user wallets)
        for asset in userAssets {
            let qty = asset.totalQuantity
            guard qty >= 1e-8 else { continue }
            let clean = cleanAssetName(asset.asset)
            aggregatedBalances[clean] = max(aggregatedBalances[clean] ?? 0.0, qty)
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
    func fetchUserAssets(apiKey: String, secretKey: String) async -> [BinanceUserAsset] {
        let endpoint = "/sapi/v3/asset/getUserAsset"
        let timestamp = Int64(Date().timeIntervalSince1970 * 1000)
        let recvWindow = 5000

        let bodyString = "recvWindow=\(recvWindow)&timestamp=\(timestamp)"
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
