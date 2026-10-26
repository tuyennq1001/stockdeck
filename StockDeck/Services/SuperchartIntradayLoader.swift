import Foundation

/// On-demand intraday history, separate from the daily portfolio valuation data.
actor SuperchartIntradayLoader {
    static let shared = SuperchartIntradayLoader()
    private var cache: [String: (Date, [PricePoint])] = [:]
    private var tasks: [String: Task<[PricePoint], Error>] = [:]
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.httpAdditionalHeaders = ["User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)"]
        return URLSession(configuration: configuration)
    }()

    enum LoadError: LocalizedError {
        case unavailable, rateLimited
        var errorDescription: String? {
            switch self {
            case .unavailable: "Nguồn chưa cung cấp dữ liệu trong ngày cho mã này. Hãy chọn khung D, W hoặc M."
            case .rateLimited: "Nguồn dữ liệu đang giới hạn truy cập. Vui lòng thử lại sau."
            }
        }
    }

    func load(symbol: String) async throws -> [PricePoint] {
        let key = StockService.canonicalSymbol(for: symbol)
        if let (date, points) = cache[key], Date().timeIntervalSince(date) < 300 { return points }
        if let task = tasks[key] { return try await task.value }
        let task = Task { try await fetch(symbol: key) }
        tasks[key] = task
        defer { tasks[key] = nil }
        let points = try await task.value
        cache[key] = (Date(), points)
        if cache.count > 12, let oldest = cache.min(by: { $0.value.0 < $1.value.0 })?.key {
            cache[oldest] = nil
        }
        return points
    }

    private func fetch(symbol: String) async throws -> [PricePoint] {
        guard let symbol = Self.requestSymbol(for: symbol) else { throw LoadError.unavailable }
        for host in ["query1.finance.yahoo.com", "query2.finance.yahoo.com"] {
            var url = URLComponents()
            url.scheme = "https"
            url.host = host
            url.path = "/v8/finance/chart/\(symbol)"
            url.queryItems = [URLQueryItem(name: "interval", value: "5m"),
                              URLQueryItem(name: "range", value: "1mo"),
                              URLQueryItem(name: "includePrePost", value: "false")]
            guard let endpoint = url.url else { continue }
            do {
                let (data, response) = try await session.data(from: endpoint)
                guard let http = response as? HTTPURLResponse else { continue }
                if http.statusCode == 429 { throw LoadError.rateLimited }
                guard http.statusCode == 200 else { continue }
                let decoded = try JSONDecoder().decode(Response.self, from: data)
                guard let result = decoded.chart.result?.first,
                      result.meta.symbol.uppercased() == symbol.uppercased(),
                      let quote = result.indicators?.quote?.first else { continue }
                let points = PriceHistory.points(timestamps: result.timestamp ?? [], closes: quote.close ?? [],
                    opens: quote.open, highs: quote.high, lows: quote.low, volumes: quote.volume)
                if !points.isEmpty { return points }
            } catch LoadError.rateLimited { throw LoadError.rateLimited }
            catch is CancellationError { throw CancellationError() }
            catch { continue }
        }
        throw LoadError.unavailable
    }

    nonisolated static func requestSymbol(for symbol: String) -> String? {
        let symbol = StockService.canonicalSymbol(for: symbol)
        if StockService.isJapaneseMutualFund(symbol) { return nil }
        if StockService.isVietnameseStock(symbol) { return StockService.yahooSymbolForVietnameseStock(symbol) }
        if StockService.isJapaneseStock(symbol) {
            return symbol.hasSuffix(".T") ? symbol : symbol.replacingOccurrences(of: ".JP", with: "") + ".T"
        }
        if symbol.hasSuffix("-USD") { return symbol }
        if StorageService.isStandardCryptoSymbol(symbol) { return symbol + "-USD" }
        if StorageService.isBinanceNativePair(symbol) {
            for suffix in ["USDT", "USDC", "FDUSD", "BUSD", "USD"] where symbol.hasSuffix(suffix) {
                return String(symbol.dropLast(suffix.count)) + "-USD"
            }
        }
        return symbol
    }

    private struct Response: Decodable {
        let chart: Chart
        struct Chart: Decodable { let result: [Result]? }
        struct Result: Decodable {
            let meta: Meta
            let timestamp: [Int]?
            let indicators: Indicators?
        }
        struct Meta: Decodable { let symbol: String }
        struct Indicators: Decodable { let quote: [Quote]? }
        struct Quote: Decodable {
            let open, high, low, close, volume: [Double?]?
        }
    }
}
