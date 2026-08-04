import Foundation

extension Array {
    /// Splits the array into chunks of at most `size` elements.
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}

@MainActor
class StockService: ObservableObject {
    static let shared = StockService()

    @Published var quotes: [String: StockQuote] = [:]
    @Published var isLoading = false
    @Published var exchangeRates: [String: Double] = [:]  // e.g. "USDEUR" -> 0.92 (rate to preferred currency)
    @Published var historicalRates: [String: Double] = [:]  // e.g. "USDEUR:1704067200" -> 0.9045 (rate at date)
    @Published var lastFxFetchDate: Date? = nil
    @Published var news: [NewsArticle] = []
    @Published var isLoadingNews = false
    /// Daily close history per symbol (~2 years, full daily resolution) for the
    /// 7D/1M/1Y ranges. Cached ~1h.
    @Published var priceHistory: [String: [PricePoint]] = [:]
    /// Monthly close history over the full available range, for the "All" range.
    /// Cached ~6h. (Yahoo downsamples daily+max to coarse data, so "All" needs its
    /// own monthly series and the shorter ranges need the daily 2y series.)
    @Published var priceHistoryMax: [String: [PricePoint]] = [:]
    /// Intraday (5-minute) closes for the "24H" chart range. Cached ~5min.
    @Published var intradayHistory: [String: [PricePoint]] = [:]
    /// Hourly closes over ~7 days for the "7D" chart range. Cached ~15min.
    @Published var intradayWeek: [String: [PricePoint]] = [:]
    /// One year of daily closes loaded in one batched request for Watchlist
    /// sparklines and the 1M / 3M / YTD performance columns.
    @Published var watchlistHistory: [String: [PricePoint]] = [:]

    private let session: URLSession
    private var crumb: String?
    private var lastNewsFetch: Date?
    private var priceHistoryFetchedAt: [String: Date] = [:]
    private var priceHistoryMaxAt: [String: Date] = [:]
    private var intradayFetchedAt: [String: Date] = [:]
    private var intradayWeekAt: [String: Date] = [:]
    private var sparkFetchedAt: Date?

    private init() {
        let config = URLSessionConfiguration.default
        config.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)"
        ]
        config.httpCookieAcceptPolicy = .always
        config.httpCookieStorage = .shared
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: config)
    }

    static func collectSymbols(storageService: StorageService) -> Set<String> {
        var syms = Set<String>()
        for wl in storageService.watchlists {
            for s in wl.symbols {
                syms.insert(s)
                syms.insert(s.uppercased())
            }
        }
        for portfolio in storageService.portfolios {
            for holding in portfolio.holdings {
                syms.insert(holding.symbol)
                syms.insert(holding.symbol.uppercased())
            }
        }
        return syms
    }

    /// Full refresh: quotes (REST) + exchange rates. Use only at startup or when WSS is down.
    /// Phase 1: load only watchlist symbols so the menu bar shows immediately.
    /// Skips exchange rates (uses cached rates from the previous session).
    func refreshCritical(storageService: StorageService) async {
        let watchlistSymbols = storageService.watchlists.flatMap(\.symbols)
        guard !watchlistSymbols.isEmpty else { return }
        isLoading = true
        defer { isLoading = false }

        let symbols = Array(Set(watchlistSymbols))
        await fetchQuotes(symbols: symbols)
    }

    /// Phase 2: load all remaining symbols + exchange rates, after the menu bar
    /// is already visible.
    func refreshAll(storageService: StorageService) async {
        let allSymbols = Self.collectSymbols(storageService: storageService)
        guard !allSymbols.isEmpty else { return }
        isLoading = true
        defer { isLoading = false }

        // Evict quotes for symbols no longer tracked
        let staleKeys = Set(quotes.keys).subtracting(allSymbols)
        for key in staleKeys { quotes.removeValue(forKey: key) }

        await fetchQuotes(symbols: Array(allSymbols))
        await refreshExchangeRates(storageService: storageService)
    }

    private static let fallbackFxToUSD: [String: Double] = [
        "JPY": 1.0 / 155.0,
        "EUR": 1.08,
        "GBP": 1.28,
        "VND": 1.0 / 25400.0,
        "AUD": 0.65,
        "CAD": 0.73,
        "CHF": 1.12,
        "HKD": 0.128,
        "SGD": 0.74,
        "KRW": 1.0 / 1380.0
    ]

    /// Refresh exchange rates for tracked currencies once per calendar day or on app launch.
    func refreshExchangeRates(storageService: StorageService, force: Bool = false) async {
        let allSymbols = Self.collectSymbols(storageService: storageService)
        guard !allSymbols.isEmpty else { return }

        // Collect all pairs we need: (from, to)
        let preferredCurrency = storageService.preferredCurrency
        let priceCurrency = storageService.stockPriceCurrency

        var pairs = Set<String>() // "FROMTO" keys
        for symbol in allSymbols {
            let curr = detectedCurrency(for: symbol)
            if curr != preferredCurrency {
                pairs.insert("\(curr)|\(preferredCurrency)")
            }
            if !priceCurrency.isEmpty && curr != priceCurrency {
                pairs.insert("\(curr)|\(priceCurrency)")
            }
        }

        // Check if all needed exchange rates are present in cache
        let hasAllPairs: Bool = {
            for pair in pairs {
                let parts = pair.split(separator: "|")
                guard parts.count >= 2 else { continue }
                let from = String(parts[0])
                let to = String(parts[1])
                let direct = "\(from)\(to)"
                let inverse = "\(to)\(from)"
                if exchangeRates[direct] == nil && exchangeRates[inverse] == nil {
                    return false
                }
            }
            return true
        }()

        if !force && hasAllPairs && !exchangeRates.isEmpty, let lastDate = lastFxFetchDate, Calendar.current.isDateInToday(lastDate) {
            return
        }

        // Evict exchange rates no longer needed
        let neededRateKeys = Set(pairs.compactMap { pair -> String? in
            let parts = pair.split(separator: "|")
            guard parts.count >= 2 else { return nil }
            return "\(parts[0])\(parts[1])"
        })
        let staleRateKeys = Set(exchangeRates.keys).subtracting(neededRateKeys)
        for key in staleRateKeys { exchangeRates.removeValue(forKey: key) }

        await withTaskGroup(of: Void.self) { group in
            for pair in pairs {
                let parts = pair.split(separator: "|")
                guard parts.count >= 2 else { continue }
                let from = String(parts[0])
                let to = String(parts[1])
                group.addTask { [weak self] in
                    await self?.fetchExchangeRate(from: from, to: to)
                }
            }
        }

        // Fetch historical rates for holdings with purchase date — skip if already cached
        var neededHistoricalKeys = Set<String>()
        var historicalKeysToFetch = Set<String>()
        for portfolio in storageService.portfolios {
            for holding in portfolio.holdings {
                guard let purchaseDate = holding.purchaseDate,
                      let quote = quotes[holding.symbol],
                      quote.currency != preferredCurrency
                else { continue }
                let dayStart = Calendar.current.startOfDay(for: purchaseDate)
                let ts = Int(dayStart.timeIntervalSince1970)
                let cacheKey = "\(quote.currency)\(preferredCurrency):\(ts)"
                neededHistoricalKeys.insert(cacheKey)
                if historicalRates[cacheKey] == nil {
                    historicalKeysToFetch.insert("\(quote.currency)|\(preferredCurrency)|\(ts)")
                }
            }
        }

        // Evict historical rates no longer needed
        let staleHistKeys = Set(historicalRates.keys).subtracting(neededHistoricalKeys)
        for key in staleHistKeys { historicalRates.removeValue(forKey: key) }

        await withTaskGroup(of: Void.self) { group in
            for key in historicalKeysToFetch {
                let parts = key.split(separator: "|")
                guard parts.count == 3,
                      let ts = Int(parts[2])
                else { continue }
                let from = String(parts[0])
                let to = String(parts[1])
                group.addTask { [weak self] in
                    await self?.fetchHistoricalExchangeRate(from: from, to: to, dateTimestamp: ts)
                }
            }
        }
        lastFxFetchDate = Date()
    }

    func rate(from currency: String, for purchaseDate: Date? = nil) -> Double {
        let preferred = StorageService.shared.preferredCurrency
        let fromUpper = currency.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let prefUpper = preferred.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if fromUpper == prefUpper || fromUpper.isEmpty { return 1.0 }

        if let date = purchaseDate {
            let dayStart = Calendar.current.startOfDay(for: date)
            let ts = Int(dayStart.timeIntervalSince1970)
            let key = "\(fromUpper)\(prefUpper):\(ts)"
            if let historical = historicalRates[key], historical > 0 { return historical }
            let inverseKey = "\(prefUpper)\(fromUpper):\(ts)"
            if let inverseHist = historicalRates[inverseKey], inverseHist > 0 { return 1.0 / inverseHist }
        }

        if let live = exchangeRates["\(fromUpper)\(prefUpper)"], live > 0 { return live }
        if let inverseLive = exchangeRates["\(prefUpper)\(fromUpper)"], inverseLive > 0 { return 1.0 / inverseLive }

        // Fallback for cross-currency when live FX rate is not in exchangeRates cache yet
        if prefUpper == "USD", let rateUSD = Self.fallbackFxToUSD[fromUpper] {
            return rateUSD
        } else if fromUpper == "USD", let rateUSD = Self.fallbackFxToUSD[prefUpper], rateUSD > 0 {
            return 1.0 / rateUSD
        } else if let fromUSD = Self.fallbackFxToUSD[fromUpper], let toUSD = Self.fallbackFxToUSD[prefUpper], toUSD > 0 {
            return fromUSD / toUSD
        }

        return 1.0
    }

    func fetchQuotes(symbols: [String]) async {
        guard !symbols.isEmpty else { return }

        let fundSymbols = symbols.filter { self.isJapaneseMutualFund($0) }
        let regularSymbols = symbols.filter { !self.isJapaneseMutualFund($0) }

        if !fundSymbols.isEmpty {
            await withTaskGroup(of: (String, StockQuote?).self) { group in
                for symbol in fundSymbols {
                    group.addTask { [weak self] in
                        let q = await self?.fetchJapaneseFundQuote(symbol: symbol)
                        return (symbol, q)
                    }
                }
                for await (sym, q) in group {
                    if let quote = q, quote.price > 0 {
                        self.quotes[sym] = quote
                        self.quotes[sym.uppercased()] = quote
                        self.quotes[quote.symbol] = quote
                        self.quotes[quote.symbol.uppercased()] = quote
                        StorageService.shared.setType("MUTUALFUND", for: sym)
                        StorageService.shared.setType("MUTUALFUND", for: sym.uppercased())
                        StorageService.shared.setType("MUTUALFUND", for: quote.symbol)
                    }
                }
            }
        }

        let equitySymbols = regularSymbols.filter { Self.isBinanceEquitySymbol($0) }
        let cryptoSymbols = regularSymbols.filter { sym in
            let clean = sym.hasSuffix("-USD") ? String(sym.dropLast(4)) : sym
            return !equitySymbols.contains(sym)
                && (StorageService.isStandardCryptoSymbol(clean) || sym.hasSuffix("-USD") || StorageService.isBinanceNativePair(sym))
        }
        let stockSymbols = regularSymbols.filter { !cryptoSymbols.contains($0) && !equitySymbols.contains($0) }

        if !cryptoSymbols.isEmpty {
            await fetchBinanceCryptoQuotes(symbols: cryptoSymbols)
        }

        if !equitySymbols.isEmpty {
            await fetchBinanceEquityQuotes(symbols: equitySymbols)
        }

        guard !stockSymbols.isEmpty else { return }

        // Try v7 batch quote first for regular stock/ETF symbols
        if await fetchQuotesV7(symbols: stockSymbols) {
            return
        }

        // Fallback: fetch each stock symbol via v8 chart API
        await withTaskGroup(of: Void.self) { group in
            for symbol in stockSymbols {
                group.addTask { [weak self] in
                    await self?.fetchSingleQuote(symbol: symbol)
                }
            }
        }

        // Ensure stablecoins always have valid $1.00 USD quotes if Yahoo Finance returns nil/0
        let stablecoins: [String: String] = [
            "USDT-USD": "Tether USD",
            "USDC-USD": "USD Coin",
            "BUSD-USD": "Binance USD",
            "DAI-USD": "Dai",
            "TUSD-USD": "TrueUSD",
            "FDUSD-USD": "First Digital USD",
            "USDP-USD": "Pax Dollar",
            "PAXG-USD": "PAX Gold",
            "USD-USD": "US Dollar"
        ]
        for (sym, name) in stablecoins {
            if symbols.contains(sym) || symbols.contains(sym.lowercased()) {
                if self.quotes[sym] == nil || (self.quotes[sym]?.price ?? 0) <= 0 {
                    let fallbackQuote = StockQuote(
                        symbol: sym,
                        name: name,
                        price: 1.0,
                        change: 0.0,
                        changePercent: 0.0,
                        currency: "USD"
                    )
                    self.quotes[sym] = fallbackQuote
                    self.quotes[sym.uppercased()] = fallbackQuote
                }
            }
        }
    }

    private static func isBinanceEquitySymbol(_ symbol: String) -> Bool {
        let upper = symbol.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let base = upper.hasSuffix("-USD") ? String(upper.dropLast(4)) : upper
        return base.hasPrefix("EQ_") && base.count > 3
    }

    /// Fetch Binance US-equity quotes through Stocks Trading API. Binance
    /// exposes the balance as EQ_<ticker>, while the quote endpoint expects
    /// the underlying ticker (for example EQ_GOOGL -> GOOGL).
    private func fetchBinanceEquityQuotes(symbols: [String]) async {
        guard let credentials = StorageService.shared.firstBinanceCredentials() else { return }

        await withTaskGroup(of: (String, BinanceEquityQuote?).self) { group in
            for symbol in symbols {
                let upper = symbol.uppercased()
                let base = upper.hasSuffix("-USD") ? String(upper.dropLast(4)) : upper
                let underlying = String(base.dropFirst(3))
                group.addTask {
                    let quote = await BinanceAPIService.shared.fetchEquityQuote(
                        apiKey: credentials.apiKey,
                        symbol: underlying
                    )
                    return (symbol, quote)
                }
            }

            for await (symbol, equityQuote) in group {
                guard let equityQuote, let binanceMidpoint = equityQuote.midpoint else { continue }
                let upper = symbol.uppercased()
                let base = upper.hasSuffix("-USD") ? String(upper.dropLast(4)) : upper
                let underlying = String(base.dropFirst(3))

                // The Binance equity REST quote provides bid/ask but no prior
                // close. Use the underlying stock's regular-session quote for
                // price and daily change, keeping Binance midpoint as fallback.
                if !(await self.fetchQuotesV7(symbols: [underlying])) {
                    await self.fetchSingleQuote(symbol: underlying)
                }
                let regularQuote = self.quotes[underlying]
                let quote = StockQuote(
                    symbol: symbol,
                    name: regularQuote?.name ?? underlying,
                    price: regularQuote?.price ?? binanceMidpoint,
                    change: regularQuote?.change ?? 0,
                    changePercent: regularQuote?.changePercent ?? 0,
                    regularMarketPreviousClose: regularQuote?.regularMarketPreviousClose,
                    currency: regularQuote?.currency ?? "USD",
                    marketState: regularQuote?.marketState ?? "REGULAR",
                    dayHigh: regularQuote?.dayHigh,
                    dayLow: regularQuote?.dayLow,
                    fiftyTwoWeekHigh: regularQuote?.fiftyTwoWeekHigh,
                    fiftyTwoWeekLow: regularQuote?.fiftyTwoWeekLow,
                    preMarketPrice: regularQuote?.preMarketPrice,
                    preMarketChange: regularQuote?.preMarketChange,
                    preMarketChangePercent: regularQuote?.preMarketChangePercent,
                    postMarketPrice: regularQuote?.postMarketPrice,
                    postMarketChange: regularQuote?.postMarketChange,
                    postMarketChangePercent: regularQuote?.postMarketChangePercent
                )
                self.quotes[symbol] = quote
                self.quotes[upper] = quote
                self.quotes[base] = quote
                StorageService.shared.setType("STOCK", for: symbol)
            }
        }
    }

    // MARK: - v7 Quote API (batch, live extended hours)

    private func fetchCrumb() async -> Bool {
        // Step 1: GET fc.yahoo.com to collect cookies
        guard let cookieUrl = URL(string: "https://fc.yahoo.com") else { return false }
        _ = try? await session.data(from: cookieUrl)

        // Step 2: GET crumb using the cookies
        guard let crumbUrl = URL(string: "https://query2.finance.yahoo.com/v1/test/getcrumb") else { return false }
        do {
            let (data, response) = try await session.data(from: crumbUrl)
            guard let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 200 else { return false }
            guard let crumbValue = String(data: data, encoding: .utf8), !crumbValue.isEmpty else { return false }
            self.crumb = crumbValue
            return true
        } catch {
            return false
        }
    }

    private func fetchQuotesV7(symbols: [String], retried: Bool = false) async -> Bool {
        if crumb == nil {
            guard await fetchCrumb() else { return false }
        }

        guard let crumb = crumb else { return false }

        let joined = symbols.map { $0.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0 }.joined(separator: ",")
        let crumbEncoded = crumb.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? crumb
        guard let url = URL(string: "https://query2.finance.yahoo.com/v7/finance/quote?symbols=\(joined)&crumb=\(crumbEncoded)") else { return false }

        do {
            let (data, response) = try await session.data(from: url)
            guard let httpResp = response as? HTTPURLResponse else { return false }

            if httpResp.statusCode == 401 {
                guard !retried else { return false }
                self.crumb = nil
                guard await fetchCrumb() else { return false }
                return await fetchQuotesV7(symbols: symbols, retried: true)
            }

            guard httpResp.statusCode == 200 else { return false }

            let parsed: V7ParseResult
            do {
                parsed = try Self.parseV7Response(data)
            } catch {
                return false
            }
            guard !parsed.quotes.isEmpty else { return false }

            for quote in parsed.quotes {
                quotes[quote.symbol] = quote
                quotes[quote.symbol.uppercased()] = quote
            }
            for (symbol, type) in parsed.types {
                StorageService.shared.setType(type, for: symbol)
                StorageService.shared.setType(type, for: symbol.uppercased())
            }

            let stablecoins: [String: String] = [
                "USDT-USD": "Tether USD",
                "USDC-USD": "USD Coin",
                "BUSD-USD": "Binance USD",
                "DAI-USD": "Dai",
                "TUSD-USD": "TrueUSD",
                "FDUSD-USD": "First Digital USD",
                "USDP-USD": "Pax Dollar",
                "PAXG-USD": "PAX Gold",
                "USD-USD": "US Dollar"
            ]
            for (sym, name) in stablecoins {
                if symbols.contains(sym) || symbols.contains(sym.lowercased()) {
                    if quotes[sym] == nil || (quotes[sym]?.price ?? 0) <= 0 {
                        let fallbackQuote = StockQuote(
                            symbol: sym,
                            name: name,
                            price: 1.0,
                            change: 0.0,
                            changePercent: 0.0,
                            currency: "USD"
                        )
                        quotes[sym] = fallbackQuote
                        quotes[sym.uppercased()] = fallbackQuote
                    }
                }
            }

            return true
        } catch {
            return false
        }
    }

    struct BinanceTicker24hr: Decodable {
        let symbol: String
        let lastPrice: String
        let priceChange: String
        let priceChangePercent: String
    }

    /// Returns the inverted Binance pair for a cross pair that only exists the
    /// other way around. e.g. "BTCETH" → "ETHBTC" (Binance lists ETH/BTC, not
    /// BTC/ETH). Returns nil for quote assets that shouldn't be inverted (USDT,
    /// USDC — those always have a direct pair as <BASE>USDT).
    private static func invertedBinancePair(_ symbol: String) -> String? {
        let upper = symbol.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let quoteAssets: Set<String> = ["USDT", "USDC", "BUSD", "DAI", "TUSD", "FDUSD", "USD", "BTC", "ETH", "BNB"]
        for q in quoteAssets where upper.hasSuffix(q) && upper.count > q.count {
            let base = String(upper.dropLast(q.count))
            if base.count >= 2 && (StorageService.isStandardCryptoSymbol(base) || base.allSatisfy({ $0.isLetter })) {
                // Only invert crypto↔crypto cross pairs (e.g. BTCETH → ETHBTC).
                // USD-quoted pairs always exist directly as <BASE>USDT.
                if ["USDT", "USDC", "BUSD", "DAI", "TUSD", "FDUSD", "USD"].contains(q) {
                    return nil
                }
                return q + base
            }
        }
        return nil
    }

    /// Fetches live 24hr ticker quotes directly from Binance Public API
    /// (`https://api.binance.com/api/v3/ticker/24hr?symbols=[...]`) for crypto
    /// symbols, stablecoins, and liquid staking tokens (WBETH, BETH). Requests
    /// only the exact symbols the user holds instead of the full ~2,000-symbol
    /// market snapshot, so the API weight stays tiny (≈4 vs 40) and we avoid
    /// Binance's 2400 weight/min rate limit.
    func fetchBinanceCryptoQuotes(symbols: [String]) async {
        guard !symbols.isEmpty else { return }

        // Resolve each requested symbol to the concrete Binance pairs we need.
        // Symbols that are already native Binance pairs (BTCUSDT, BTCETH) are used
        // directly; Yahoo-style symbols (BTC-USD) map to <BASE>USDT.
        // Adding ETHUSDT + BETHETH (when BETH/WBETH is held) lets us derive a
        // USD price for the staking tokens even though no direct BETHUSDT exists.
        var pairSymbols: Set<String> = []
        for sym in symbols {
            var cleanBase = sym.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            if cleanBase.hasSuffix("-USD") {
                cleanBase = String(cleanBase.dropLast(4))
            }
            if BinanceStablecoin.isUSDPegged(cleanBase) {
                continue // handled locally with a 1.0 peg, no API call needed
            }
            if StorageService.isBinanceNativePair(cleanBase) {
                pairSymbols.insert(cleanBase)
                // Cross pairs like BTCETH only exist inverted on Binance (ETHBTC).
                // Fetch that too so we can derive the price by inverting.
                if let inverted = Self.invertedBinancePair(cleanBase) {
                    pairSymbols.insert(inverted)
                }
            } else {
                pairSymbols.insert("\(cleanBase)USDT")
            }
            if cleanBase == "BETH" || cleanBase == "WBETH" {
                pairSymbols.insert("ETHUSDT")
                pairSymbols.insert("BETHETH")
            }
        }

        // Binance accepts up to ~100 symbols per request; keep within that limit.
        let chunks = Array(pairSymbols).chunked(into: 90)
        var tickerMap: [String: BinanceTicker24hr] = [:]

        for chunk in chunks {
            let listed = chunk.joined(separator: "\",\"")
            let urlString = "https://api.binance.com/api/v3/ticker/24hr?symbols=[\"\(listed)\"]"
            guard let url = URL(string: urlString) else { continue }
            do {
                let (data, response) = try await session.data(from: url)
                guard let httpResp = response as? HTTPURLResponse else { continue }
                if httpResp.statusCode == 200 {
                    let tickers = try JSONDecoder().decode([BinanceTicker24hr].self, from: data)
                    for t in tickers {
                        tickerMap[t.symbol.uppercased()] = t
                    }
                    continue
                }

                // Binance returns HTTP 400 for the whole batch when any pair is
                // invalid (for example an unsupported tokenized-stock symbol).
                // Retry each pair independently so one bad asset cannot suppress
                // valid BTC/ETH/SOL quotes in the same request.
                print("[StockService] Binance ticker batch HTTP \(httpResp.statusCode); retrying symbols individually")
                for single in chunk {
                    let singleURL = URL(string: "https://api.binance.com/api/v3/ticker/24hr?symbol=\(single)")!
                    if let (sData, sResp) = try? await session.data(from: singleURL),
                       let sHttp = sResp as? HTTPURLResponse, sHttp.statusCode == 200,
                       let t = try? JSONDecoder().decode(BinanceTicker24hr.self, from: sData) {
                        tickerMap[t.symbol.uppercased()] = t
                    }
                }
            } catch {
                // A successful batch can still contain an unexpected response
                // shape; retrying individually keeps valid pairs available.
                print("[StockService] Failed to fetch Binance crypto tickers chunk: \(error); retrying symbols individually")
                for single in chunk {
                    let singleURL = URL(string: "https://api.binance.com/api/v3/ticker/24hr?symbol=\(single)")!
                    if let (sData, sResp) = try? await session.data(from: singleURL),
                       let sHttp = sResp as? HTTPURLResponse, sHttp.statusCode == 200,
                       let t = try? JSONDecoder().decode(BinanceTicker24hr.self, from: sData) {
                        tickerMap[t.symbol.uppercased()] = t
                    }
                }
            }
        }

        for sym in symbols {
            var cleanBase = sym.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            if cleanBase.hasSuffix("-USD") {
                cleanBase = String(cleanBase.dropLast(4))
            }

            // Handle Stablecoins & USD-pegged tokens locally at $1.00
            if BinanceStablecoin.isUSDPegged(cleanBase) {
                let quote = StockQuote(
                    symbol: sym,
                    name: cleanBase,
                    price: 1.0,
                    change: 0.0,
                    changePercent: 0.0,
                    currency: "USD"
                )
                self.quotes[sym] = quote
                self.quotes[sym.uppercased()] = quote
                self.quotes[cleanBase] = quote
                StorageService.shared.setType("CRYPTOCURRENCY", for: sym)
                continue
            }

            // Match pair on Binance. Native pairs (BTCUSDT, BTCETH) are looked up
            // directly; base symbols (ETH, WBETH) fall back to <BASE>USDT or <BASE>BTC.
            // If a native pair like BTCETH doesn't exist, fall back to the inverted
            // pair (ETHBTC) and invert the price.
            let isNative = StorageService.isBinanceNativePair(cleanBase)
            let inverted = isNative ? Self.invertedBinancePair(cleanBase) : nil
            let matchedTicker: BinanceTicker24hr? = isNative
                ? (tickerMap[cleanBase] ?? (inverted.flatMap { tickerMap[$0] }))
                : (tickerMap["\(cleanBase)USDT"] ?? tickerMap["\(cleanBase)BTC"])
            let isInvertedQuote = isNative && tickerMap[cleanBase] == nil && (inverted.flatMap { tickerMap[$0] }) != nil

            // Fallback for BETH / WBETH if BETHUSDT isn't direct
            if matchedTicker == nil && (cleanBase == "BETH" || cleanBase == "WBETH") {
                if let ethQuote = tickerMap["ETHUSDT"], let ethPrice = Double(ethQuote.lastPrice) {
                    let bEthMultiplier = Double(tickerMap["BETHETH"]?.lastPrice ?? "1.0") ?? 1.0
                    let derivedPrice = ethPrice * bEthMultiplier
                    let change = (Double(ethQuote.priceChange) ?? 0) * bEthMultiplier
                    let changePercent = Double(ethQuote.priceChangePercent) ?? 0
                    let quote = StockQuote(
                        symbol: sym,
                        name: cleanBase,
                        price: derivedPrice,
                        change: change,
                        changePercent: changePercent,
                        currency: "USD"
                    )
                    self.quotes[sym] = quote
                    self.quotes[sym.uppercased()] = quote
                    self.quotes[cleanBase] = quote
                    StorageService.shared.setType("CRYPTOCURRENCY", for: sym)
                    continue
                }
            }

            if let ticker = matchedTicker,
               let rawPrice = Double(ticker.lastPrice), rawPrice > 0 {
                // When the pair is inverted (e.g. BTCETH from ETHBTC),
                // 1 ETH = X BTC → 1 BTC = 1/X ETH.
                let price = isInvertedQuote ? (1.0 / rawPrice) : rawPrice
                let change: Double
                let changePct: Double
                if isInvertedQuote {
                    let rawChg = Double(ticker.priceChange) ?? 0
                    let previous = rawPrice - rawChg
                    let invertedPrev = previous > 0 ? (1.0 / previous) : 0
                    change = price - invertedPrev
                    changePct = invertedPrev > 0 ? (change / invertedPrev) * 100 : 0
                } else {
                    change = Double(ticker.priceChange) ?? 0
                    changePct = Double(ticker.priceChangePercent) ?? 0
                }

                let quote = StockQuote(
                    symbol: sym,
                    name: cleanBase,
                    price: price,
                    change: change,
                    changePercent: changePct,
                    currency: "USD"
                )
                self.quotes[sym] = quote
                self.quotes[sym.uppercased()] = quote
                self.quotes[cleanBase] = quote
                StorageService.shared.setType("CRYPTOCURRENCY", for: sym)
            }
        }
    }

    /// Parsed output of a Yahoo v7 batch-quote response.
    struct V7ParseResult {
        let quotes: [StockQuote]
        let types: [String: String]  // symbol -> Yahoo quoteType
    }

    /// Decode and map a Yahoo v7 `/finance/quote` batch response into `StockQuote`s.
    /// Entries without a `regularMarketPrice` (delisted/suspended tickers come back
    /// partial) are skipped rather than making the whole batch throw — so one bad
    /// symbol can no longer drop live quotes for every other symbol. Pure and
    /// `nonisolated` so it is unit-testable without running the service.
    nonisolated static func parseV7Response(_ data: Data) throws -> V7ParseResult {
        let decoded = try JSONDecoder().decode(YahooV7Response.self, from: data)
        guard let results = decoded.quoteResponse.result else {
            return V7ParseResult(quotes: [], types: [:])
        }

        var quotes: [StockQuote] = []
        var types: [String: String] = [:]

        for q in results {
            guard let price = q.regularMarketPrice else { continue }
            let previousClose = q.regularMarketPreviousClose ?? price
            let change = q.regularMarketChange ?? (price - previousClose)
            let changePercent = q.regularMarketChangePercent ?? (previousClose > 0 ? (change / previousClose) * 100 : 0)

            // Normalize marketState
            let rawState = q.marketState ?? "CLOSED"
            let marketState: String
            switch rawState {
            case "REGULAR": marketState = "REGULAR"
            case "PRE": marketState = "PRE"
            case "POST": marketState = "POST"
            default: marketState = "CLOSED" // PREPRE, POSTPOST, etc.
            }

            let preChg: Double? = if let pm = q.preMarketPrice { pm - price } else { nil }
            let prePct: Double? = if let ch = preChg, price > 0 { (ch / price) * 100 } else { nil }
            let postChg: Double? = if let pm = q.postMarketPrice { pm - price } else { nil }
            let postPct: Double? = if let ch = postChg, price > 0 { (ch / price) * 100 } else { nil }

            let quote = StockQuote(
                symbol: q.symbol,
                name: q.longName ?? q.shortName ?? q.symbol,
                price: price,
                change: change,
                changePercent: changePercent,
                regularMarketPreviousClose: previousClose,
                currency: (q.currency?.isEmpty == false) ? q.currency! : Self.detectedCurrency(for: q.symbol),
                marketState: marketState,
                dayHigh: q.regularMarketDayHigh,
                dayLow: q.regularMarketDayLow,
                fiftyTwoWeekHigh: q.fiftyTwoWeekHigh,
                fiftyTwoWeekLow: q.fiftyTwoWeekLow,
                marketCap: q.marketCap,
                preMarketPrice: q.preMarketPrice,
                preMarketChange: preChg,
                preMarketChangePercent: prePct,
                postMarketPrice: q.postMarketPrice,
                postMarketChange: postChg,
                postMarketChangePercent: postPct
            )

            quotes.append(quote)
            if let t = q.quoteType { types[q.symbol] = t }
        }

        return V7ParseResult(quotes: quotes, types: types)
    }

    private func fetchSingleQuote(symbol: String) async {
        let encoded = symbol.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? symbol

        // Two requests: daily for reliable price, intraday for extended hours
        guard let dailyUrl = URL(string: "https://query1.finance.yahoo.com/v8/finance/chart/\(encoded)?interval=1d&range=2d"),
              let intraUrl = URL(string: "https://query1.finance.yahoo.com/v8/finance/chart/\(encoded)?interval=1m&range=5d&includePrePost=true") else { return }

        do {
            // Fetch both in parallel
            async let dailyFetch = session.data(from: dailyUrl)
            async let intraFetch = session.data(from: intraUrl)

            let (dailyData, _) = try await dailyFetch
            let dailyResponse = try JSONDecoder().decode(YahooChartResponse.self, from: dailyData)
            guard let dailyResult = dailyResponse.chart.result?.first else { return }
            let meta = dailyResult.meta

            let price = meta.regularMarketPrice
            let previousClose = meta.chartPreviousClose ?? price
            let change = price - previousClose
            let changePercent = previousClose > 0 ? (change / previousClose) * 100 : 0

            // Determine market state from current trading period
            let now = Date().timeIntervalSince1970
            let ctp = meta.currentTradingPeriod
            let regEnd = ctp?.regular?.end ?? 0
            let regStart = ctp?.regular?.start ?? 0
            let preStart = ctp?.pre?.start ?? 0
            let postEnd = ctp?.post?.end ?? 0

            let marketState: String
            if now >= Double(regStart) && now < Double(regEnd) {
                marketState = "REGULAR"
            } else if now >= Double(preStart) && now < Double(regStart) {
                marketState = "PRE"
            } else if now >= Double(regEnd) && now < Double(postEnd) {
                marketState = "POST"
            } else {
                marketState = "CLOSED"
            }

            // Extract extended hours from intraday data
            var preMarketPrice: Double? = nil
            var postMarketPrice: Double? = nil

            if let (intraData, _) = try? await intraFetch,
               let intraResponse = try? JSONDecoder().decode(YahooChartResponse.self, from: intraData),
               let intraResult = intraResponse.chart.result?.first {

                let timestamps = intraResult.timestamp ?? []
                let closes = intraResult.indicators?.quote?.first?.close ?? []

                // Use regularMarketTime as the boundary for the last regular session
                let regTime = meta.regularMarketTime ?? 0

                // Find post-market: data after regularMarketTime on the last trading day
                for i in stride(from: timestamps.count - 1, through: 0, by: -1) {
                    if timestamps[i] > regTime, i < closes.count, let c = closes[i] {
                        postMarketPrice = c
                        break
                    }
                }

                // For pre-market: find data before regStart of today (only when market is PRE)
                if marketState == "PRE" {
                    for i in stride(from: timestamps.count - 1, through: 0, by: -1) {
                        if timestamps[i] >= preStart && timestamps[i] < regStart, i < closes.count, let c = closes[i] {
                            preMarketPrice = c
                            break
                        }
                    }
                }
            }

            let preChg: Double? = if let pm = preMarketPrice { pm - price } else { nil }
            let prePct: Double? = if let ch = preChg, price > 0 { (ch / price) * 100 } else { nil }
            let postChg: Double? = if let pm = postMarketPrice { pm - price } else { nil }
            let postPct: Double? = if let ch = postChg, price > 0 { (ch / price) * 100 } else { nil }

            let quote = StockQuote(
                symbol: meta.symbol,
                name: meta.longName ?? meta.shortName ?? meta.symbol,
                price: price,
                change: change,
                changePercent: changePercent,
                regularMarketPreviousClose: previousClose,
                currency: (meta.currency?.isEmpty == false) ? meta.currency! : detectedCurrency(for: meta.symbol),
                marketState: marketState,
                dayHigh: nil,
                dayLow: nil,
                fiftyTwoWeekHigh: meta.fiftyTwoWeekHigh,
                fiftyTwoWeekLow: meta.fiftyTwoWeekLow,
                preMarketPrice: preMarketPrice,
                preMarketChange: preChg,
                preMarketChangePercent: prePct,
                postMarketPrice: postMarketPrice,
                postMarketChange: postChg,
                postMarketChangePercent: postPct
            )

            quotes[meta.symbol] = quote
            quotes[meta.symbol.uppercased()] = quote
            quotes[symbol] = quote
            quotes[symbol.uppercased()] = quote
            if let t = meta.instrumentType { StorageService.shared.setType(t, for: meta.symbol) }
        } catch {
        }
    }



    func priceRate(from currency: String) -> Double {
        let target = StorageService.shared.stockPriceCurrency
        if target.isEmpty || currency == target { return 1.0 }
        if let live = exchangeRates["\(currency)\(target)"], live > 0 { return live }
        if let inverseLive = exchangeRates["\(target)\(currency)"], inverseLive > 0 { return 1.0 / inverseLive }
        return 1.0
    }

    private func fetchExchangeRate(from: String, to: String) async {
        if from == to || from.isEmpty || to.isEmpty { return }
        let directSymbol = "\(from)\(to)=X"
        let encodedDirect = directSymbol.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? directSymbol
        if let url = URL(string: "https://query1.finance.yahoo.com/v8/finance/chart/\(encodedDirect)?interval=1d&range=1d") {
            do {
                let (data, _) = try await session.data(from: url)
                let response = try JSONDecoder().decode(YahooChartResponse.self, from: data)
                if let result = response.chart.result?.first {
                    let p = result.meta.regularMarketPrice
                    if p > 0 {
                        exchangeRates["\(from)\(to)"] = p
                        return
                    }
                }
            } catch {}
        }

        // Inverse pair fallback (e.g. USDVND=X for VNDUSD=X)
        let inverseSymbol = "\(to)\(from)=X"
        let encodedInverse = inverseSymbol.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? inverseSymbol
        if let url = URL(string: "https://query1.finance.yahoo.com/v8/finance/chart/\(encodedInverse)?interval=1d&range=1d") {
            do {
                let (data, _) = try await session.data(from: url)
                let response = try JSONDecoder().decode(YahooChartResponse.self, from: data)
                if let result = response.chart.result?.first {
                    let p = result.meta.regularMarketPrice
                    if p > 0 {
                        exchangeRates["\(from)\(to)"] = 1.0 / p
                        exchangeRates["\(to)\(from)"] = p
                    }
                }
            } catch {}
        }
    }

    private func fetchHistoricalExchangeRate(from: String, to: String, dateTimestamp: Int) async {
        if from == to || from.isEmpty || to.isEmpty { return }
        let key = "\(from)\(to):\(dateTimestamp)"
        let inverseKey = "\(to)\(from):\(dateTimestamp)"
        let directSymbol = "\(from)\(to)=X"
        let encodedDirect = directSymbol.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? directSymbol
        let period1 = dateTimestamp
        let period2 = dateTimestamp + 86400

        if let url = URL(string: "https://query1.finance.yahoo.com/v8/finance/chart/\(encodedDirect)?interval=1d&period1=\(period1)&period2=\(period2)") {
            do {
                let (data, _) = try await session.data(from: url)
                let response = try JSONDecoder().decode(YahooChartResponse.self, from: data)
                if let result = response.chart.result?.first,
                   let closes = result.indicators?.quote?.first?.close,
                   let validCloses = closes.compactMap({ $0 }).first, validCloses > 0 {
                    historicalRates[key] = validCloses
                    return
                }
            } catch {}
        }

        // Inverse pair fallback
        let inverseSymbol = "\(to)\(from)=X"
        let encodedInverse = inverseSymbol.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? inverseSymbol
        if let url = URL(string: "https://query1.finance.yahoo.com/v8/finance/chart/\(encodedInverse)?interval=1d&period1=\(period1)&period2=\(period2)") {
            do {
                let (data, _) = try await session.data(from: url)
                let response = try JSONDecoder().decode(YahooChartResponse.self, from: data)
                if let result = response.chart.result?.first,
                   let closes = result.indicators?.quote?.first?.close,
                   let validCloses = closes.compactMap({ $0 }).first, validCloses > 0 {
                    historicalRates[key] = 1.0 / validCloses
                    historicalRates[inverseKey] = validCloses
                }
            } catch {}
        }
    }

    /// Loads (or refreshes after ~1h) one year of daily closes for the detail
    /// chart. Real Yahoo history — the portfolio value chart intentionally has no
    /// backfill, but a single symbol's price history is accurate data.
    func ensurePriceHistory(for symbol: String) async {
        if let at = priceHistoryFetchedAt[symbol],
           Date().timeIntervalSince(at) < 3600,
           priceHistory[symbol]?.isEmpty == false { return }
        let encoded = symbol.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? symbol
        // range=10y daily closes & OHLC for 1Y/3Y/5Y/10Y chart ranges
        guard let url = URL(string: "https://query1.finance.yahoo.com/v8/finance/chart/\(encoded)?interval=1d&range=10y") else { return }
        do {
            let (data, _) = try await session.data(from: url)
            let response = try JSONDecoder().decode(YahooChartResponse.self, from: data)
            guard let result = response.chart.result?.first else { return }
            let q = result.indicators?.quote?.first
            let points = PriceHistory.points(timestamps: result.timestamp ?? [],
                                             closes: q?.close ?? [],
                                             opens: q?.open,
                                             highs: q?.high,
                                             lows: q?.low)
            guard !points.isEmpty else { return }
            priceHistory[symbol] = points
            priceHistoryFetchedAt[symbol] = Date()
        } catch {
            // Non-fatal: the detail view keeps its placeholder band.
        }
    }

    /// Monthly closes over the full available history, for the "All" range. Cached ~6h.
    func ensurePriceHistoryMax(for symbol: String) async {
        if let at = priceHistoryMaxAt[symbol],
           Date().timeIntervalSince(at) < 21600,
           priceHistoryMax[symbol]?.isEmpty == false { return }
        let encoded = symbol.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? symbol
        guard let url = URL(string: "https://query1.finance.yahoo.com/v8/finance/chart/\(encoded)?interval=1mo&range=max") else { return }
        do {
            let (data, _) = try await session.data(from: url)
            let response = try JSONDecoder().decode(YahooChartResponse.self, from: data)
            guard let result = response.chart.result?.first else { return }
            let q = result.indicators?.quote?.first
            let points = PriceHistory.points(timestamps: result.timestamp ?? [],
                                             closes: q?.close ?? [],
                                             opens: q?.open,
                                             highs: q?.high,
                                             lows: q?.low)
            guard !points.isEmpty else { return }
            priceHistoryMax[symbol] = points
            priceHistoryMaxAt[symbol] = Date()
        } catch {
        }
    }

    /// Loads (or refreshes after ~5min) one trading day of 5-minute closes for
    /// the "1D" chart range.
    func ensureIntraday(for symbol: String) async {
        if let at = intradayFetchedAt[symbol],
           Date().timeIntervalSince(at) < 300,
           intradayHistory[symbol]?.isEmpty == false { return }
        let encoded = symbol.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? symbol
        guard let url = URL(string: "https://query1.finance.yahoo.com/v8/finance/chart/\(encoded)?interval=5m&range=1d") else { return }
        do {
            let (data, _) = try await session.data(from: url)
            let response = try JSONDecoder().decode(YahooChartResponse.self, from: data)
            guard let result = response.chart.result?.first else { return }
            let q = result.indicators?.quote?.first
            let points = PriceHistory.points(timestamps: result.timestamp ?? [],
                                             closes: q?.close ?? [],
                                             opens: q?.open,
                                             highs: q?.high,
                                             lows: q?.low)
            guard !points.isEmpty else { return }
            intradayHistory[symbol] = points
            intradayFetchedAt[symbol] = Date()
        } catch {
        }
    }

    /// Hourly closes over ~7 days for the "7D" range. Cached ~15min.
    func ensureIntradayWeek(for symbol: String) async {
        if let at = intradayWeekAt[symbol],
           Date().timeIntervalSince(at) < 900,
           intradayWeek[symbol]?.isEmpty == false { return }
        let encoded = symbol.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? symbol
        guard let url = URL(string: "https://query1.finance.yahoo.com/v8/finance/chart/\(encoded)?interval=60m&range=7d") else { return }
        do {
            let (data, _) = try await session.data(from: url)
            let response = try JSONDecoder().decode(YahooChartResponse.self, from: data)
            guard let result = response.chart.result?.first else { return }
            let q = result.indicators?.quote?.first
            let points = PriceHistory.points(timestamps: result.timestamp ?? [],
                                             closes: q?.close ?? [],
                                             opens: q?.open,
                                             highs: q?.high,
                                             lows: q?.low)
            guard !points.isEmpty else { return }
            intradayWeek[symbol] = points
            intradayWeekAt[symbol] = Date()
        } catch {
        }
    }

    /// Batched Watchlist history: one Yahoo `spark` request fills five years of
    /// daily closes for MANY symbols at once. This supports the configurable
    /// 1Y/2Y/3Y/5Y metrics without one request per table cell.
    func ensureSparklines(for symbols: [String]) async {
        if let at = sparkFetchedAt,
           Date().timeIntervalSince(at) < 600,
           symbols.allSatisfy({ watchlistHistory[$0]?.isEmpty == false }) { return }
        let missing = symbols.filter { (watchlistHistory[$0]?.isEmpty ?? true) }
        guard !missing.isEmpty else { sparkFetchedAt = Date(); return }
        let joined = missing.joined(separator: ",")
        let encoded = joined.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? joined
        guard let url = URL(string: "https://query1.finance.yahoo.com/v8/finance/spark?symbols=\(encoded)&range=5y&interval=1d") else { return }
        do {
            let (data, _) = try await session.data(from: url)
            let parsed = try YahooSparkParser.parse(data)
            for (symbol, points) in parsed where !points.isEmpty {
                watchlistHistory[symbol] = points
            }
            sparkFetchedAt = Date()
        } catch {
        }
    }

    /// Ensures historical rate is loaded for a holding (e.g. when opening edit view)
    func ensureHistoricalRate(for holding: Holding) async {
        guard let purchaseDate = holding.purchaseDate,
              let quote = quotes[holding.symbol],
              quote.currency != StorageService.shared.preferredCurrency
        else { return }
        let dayStart = Calendar.current.startOfDay(for: purchaseDate)
        let ts = Int(dayStart.timeIntervalSince1970)
        let key = "\(quote.currency)\(StorageService.shared.preferredCurrency):\(ts)"
        guard historicalRates[key] == nil else { return }
        await fetchHistoricalExchangeRate(from: quote.currency, to: StorageService.shared.preferredCurrency, dateTimestamp: ts)
    }

    /// Update quotes from a batch of WebSocket ticks. Applies batch updates in a single @Published mutation.
    @discardableResult
    func applyTicks(_ tickers: [Yaticker]) -> Bool {
        guard !tickers.isEmpty else { return false }
        var updated = quotes
        var changed = false

        for ticker in tickers {
            let symbol = ticker.id
            guard !symbol.isEmpty, ticker.price > 0 else { continue }

            let existing = updated[symbol]

            let marketState: String
            switch ticker.marketHours {
            case .preMarket: marketState = "PRE"
            case .postMarket, .extendedHoursMarket: marketState = "POST"
            case .regularMarket: marketState = "REGULAR"
            default: marketState = existing?.marketState ?? "CLOSED"
            }

            let tickPrice = Double(ticker.price)
            let tickChange = Double(ticker.change)
            let tickChangePercent = Double(ticker.changePercent)
            let tickPreviousClose = ticker.previousClose == 0 ? nil : Double(ticker.previousClose)

            let isRegular = (marketState == "REGULAR")
            let price = isRegular ? tickPrice : (existing?.price ?? (tickPreviousClose ?? tickPrice))
            let change = isRegular ? tickChange : (existing?.change ?? 0)
            let changePercent = isRegular ? tickChangePercent : (existing?.changePercent ?? 0)

            let curr = !ticker.currency.isEmpty ? ticker.currency : ((existing?.currency.isEmpty == false) ? existing!.currency : detectedCurrency(for: symbol))

            let quote = StockQuote(
                symbol: symbol,
                name: existing?.name ?? ticker.shortName,
                price: price,
                change: change,
                changePercent: changePercent,
                regularMarketPreviousClose: tickPreviousClose ?? existing?.previousClose,
                currency: curr,
                marketState: marketState,
                dayHigh: existing?.dayHigh,
                dayLow: existing?.dayLow,
                fiftyTwoWeekHigh: existing?.fiftyTwoWeekHigh,
                fiftyTwoWeekLow: existing?.fiftyTwoWeekLow,
                preMarketPrice: marketState == "PRE" ? tickPrice : existing?.preMarketPrice,
                preMarketChange: marketState == "PRE" ? tickChange : existing?.preMarketChange,
                preMarketChangePercent: marketState == "PRE" ? tickChangePercent : existing?.preMarketChangePercent,
                postMarketPrice: marketState == "POST" ? tickPrice : existing?.postMarketPrice,
                postMarketChange: marketState == "POST" ? tickChange : existing?.postMarketChange,
                postMarketChangePercent: marketState == "POST" ? tickChangePercent : existing?.postMarketChangePercent
            )

            updated[symbol] = quote
            changed = true
        }

        if changed {
            quotes = updated
        }
        return changed
    }

    /// Update a quote from a single WebSocket tick.
    @discardableResult
    func applyTick(_ ticker: Yaticker) -> Bool {
        return applyTicks([ticker])
    }

    // MARK: - Japanese Mutual Funds (投資信託)

    static let popularJapaneseFunds: [SearchResult] = [
        SearchResult(symbol: "9I31223A", name: "楽天・プラス・S&P500インデックス・ファンド", exchange: "JP_FUND", type: "MUTUALFUND"),
        SearchResult(symbol: "0331423B", name: "楽天・S&P500インデックス・ファンド", exchange: "JP_FUND", type: "MUTUALFUND"),
        SearchResult(symbol: "03311187", name: "eMAXIS Slim米国株式(S&P500)", exchange: "JP_FUND", type: "MUTUALFUND"),
        SearchResult(symbol: "0331317B", name: "iFreeNEXT NASDAQ100インデックス", exchange: "JP_FUND", type: "MUTUALFUND"),
        SearchResult(symbol: "0331119A", name: "auAM Nifty50インド株ファンド", exchange: "JP_FUND", type: "MUTUALFUND"),
        SearchResult(symbol: "03311181", name: "eMAXIS Slim 全世界株式(オール・カントリー)", exchange: "JP_FUND", type: "MUTUALFUND"),
        SearchResult(symbol: "9I31123A", name: "楽天・プラス・オールカントリー・インデックス・ファンド", exchange: "JP_FUND", type: "MUTUALFUND"),
        SearchResult(symbol: "0331418A", name: "楽天・全米株式インデックス・ファンド", exchange: "JP_FUND", type: "MUTUALFUND")
    ]

    static let popularJapaneseIndices: [SearchResult] = [
        SearchResult(symbol: "^N225", name: "Nikkei 225", exchange: "JPX", type: "INDEX"),
        SearchResult(symbol: "^TOPX", name: "TOPIX", exchange: "JPX", type: "INDEX")
    ]

    nonisolated static func containsJapaneseCharacters(_ str: String) -> Bool {
        for scalar in str.unicodeScalars {
            if (0x3040...0x309F).contains(scalar.value) ||
               (0x30A0...0x30FF).contains(scalar.value) ||
               (0x4E00...0x9FAF).contains(scalar.value) {
                return true
            }
        }
        return false
    }

    func containsJapaneseCharacters(_ str: String) -> Bool { Self.containsJapaneseCharacters(str) }
    func isVietnameseStock(_ symbol: String) -> Bool { Self.isVietnameseStock(symbol) }
    func isJapaneseStock(_ symbol: String) -> Bool { Self.isJapaneseStock(symbol) }
    func isJapaneseMutualFund(_ symbol: String) -> Bool { Self.isJapaneseMutualFund(symbol) }

    nonisolated static func isVietnameseStock(_ symbol: String) -> Bool {
        let upper = symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return upper.hasSuffix(".VN") || upper.hasSuffix(".HM") || upper.hasSuffix(".HN")
    }

    nonisolated static func isJapaneseStock(_ symbol: String) -> Bool {
        let upper = symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if upper.hasSuffix(".T") || upper.hasSuffix(".JP") { return true }
        let jpStockRegex = "^[0-9]{3}[0-9A-Z]$"
        return upper.range(of: jpStockRegex, options: .regularExpression) != nil
    }

    nonisolated static func isJapaneseMutualFund(_ symbol: String) -> Bool {
        let upper = symbol.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if upper.hasSuffix(".VN") || upper.hasSuffix(".US") || upper.hasSuffix(".HK") || upper.hasSuffix(".L") {
            return false
        }
        // Exclude Binance native pairs & known crypto (BTCETH, BTCUSDT, HYPEUSDT...)
        // — otherwise the 5-12 alphanumeric TOUSHIN heuristic misclassifies them
        // as Japanese mutual funds and they never get a real quote.
        if StorageService.isBinanceNativePair(upper) || StorageService.isStandardCryptoSymbol(upper) {
            return false
        }
        let jpSet = CharacterSet(charactersIn: "\u{3000}"..."\u{30FF}").union(CharacterSet(charactersIn: "\u{4E00}"..."\u{9FFF}"))
        if symbol.unicodeScalars.contains(where: { jpSet.contains($0) }) {
            return true
        }
        let clean = upper.replacingOccurrences(of: ".JP", with: "").replacingOccurrences(of: ".T", with: "")
        if codeToFundNameMap[clean] != nil || codeToFundNameMap[upper] != nil {
            return true
        }
        if clean.hasPrefix("0P") && clean.count >= 8 {
            return true
        }
        let toushinRegex = "^[0-9A-Z]{5,12}$"
        if clean.range(of: toushinRegex, options: .regularExpression) != nil {
            if !upper.hasSuffix(".T") && !upper.hasSuffix(".JP") {
                return true
            }
        }
        return false
    }

    nonisolated static func detectedCurrency(for symbol: String, quotes: [String: StockQuote] = [:]) -> String {
        if isVietnameseStock(symbol) {
            return "VND"
        }
        if isJapaneseMutualFund(symbol) || isJapaneseStock(symbol) || containsJapaneseCharacters(symbol) {
            return "JPY"
        }
        if let quote = quotes[symbol], !quote.currency.isEmpty {
            return quote.currency.uppercased()
        }
        return "USD"
    }

    func detectedCurrency(for symbol: String) -> String {
        Self.detectedCurrency(for: symbol, quotes: quotes)
    }

    nonisolated static let codeToFundNameMap: [String: String] = [
        "04317188": "iFreeNEXT NASDAQ100インデックス",
        "0331423B": "楽天・Ｓ＆Ｐ５００インデックス・ファンド",
        "AY311238": "auAM Nifty50インド株ファンド",
        "42311184": "iTrust インド株式",
        "9I31223A": "楽天・プラス・Ｓ＆Ｐ５００インデックス・ファンド",
        "9I314241": "楽天・プラス・ＮＡＳＤＡＱ－１００インデックス・ファンド",
        "0331623B": "楽天・ＮＡＳＤＡＱ－１００インデックス・ファンド",
        "03311187": "eMAXIS Slim 米国株式(S&P500)",
        "0331418A": "eMAXIS Slim 全世界株式(オール・カントリー)",
        "9I31123A": "楽天・プラス・オールカントリー・インデックス・ファンド",
        "9I312179": "楽天・全米株式インデックス・ファンド",
        "0331119A": "eMAXIS Slim 国内リートインデックス",
        "0331218A": "eMAXIS Slim 先進国株式インデックス",
        "0331318A": "eMAXIS Slim 新興国株式インデックス",
        "0331118A": "eMAXIS Slim 国内株式(TOPIX)",
        "03312187": "eMAXIS Slim 国内株式(日経平均)"
    ]

    func fetchJapaneseFundQuote(symbol: String) async -> StockQuote? {
        let cleanCode = symbol.replacingOccurrences(of: ".JP", with: "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        var targetCode = cleanCode
        if let foundCode = Self.codeToFundNameMap.first(where: {
            $0.key == cleanCode || $0.value.uppercased() == cleanCode ||
            $0.value.replacingOccurrences(of: " ", with: "").uppercased() == cleanCode.replacingOccurrences(of: " ", with: "").uppercased() ||
            (Self.containsJapaneseCharacters(cleanCode) && (cleanCode.contains($0.value) || $0.value.contains(cleanCode)))
        })?.key {
            targetCode = foundCode
        }

        guard let url = URL(string: "https://finance.yahoo.co.jp/quote/\(targetCode)") else { return nil }

        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 200,
                  let html = String(data: data, encoding: .utf8) else { return nil }

            let pattern = "\"code\":\"\(targetCode)\".*?\"changePriceRate\":\"([^\"]*)\""
            var price: Double = 0
            var change: Double = 0
            var percent: Double = 0
            var name = Self.codeToFundNameMap[targetCode] ?? cleanCode

            if let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
               let match = regex.firstMatch(in: html, options: [], range: NSRange(location: 0, length: html.utf16.count)) {
                let jsonSnippet = "{" + (html as NSString).substring(with: match.range) + "}"
                if let snippetData = jsonSnippet.data(using: .utf8),
                   let dict = try? JSONSerialization.jsonObject(with: snippetData) as? [String: Any] {

                    let parsedName = (dict["name"] as? String) ?? (dict["fundNickName"] as? String)
                    if let parsedName, !parsedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        name = parsedName
                    }
                    let priceStr = (dict["price"] as? String)?.replacingOccurrences(of: ",", with: "") ?? "0"
                    let changeStr = (dict["changePrice"] as? String)?.replacingOccurrences(of: ",", with: "") ?? "0"
                    let percentStr = (dict["changePriceRate"] as? String)?.replacingOccurrences(of: ",", with: "") ?? "0"

                    price = Double(priceStr) ?? 0.0
                    change = Double(changeStr) ?? 0.0
                    percent = Double(percentStr) ?? 0.0
                }
            }

            if price <= 0 {
                let pricePattern = "\"price\":\"([0-9,]+)\""
                if let pRegex = try? NSRegularExpression(pattern: pricePattern),
                   let pMatch = pRegex.firstMatch(in: html, range: NSRange(location: 0, length: html.utf16.count)) {
                    let priceStr = (html as NSString).substring(with: pMatch.range(at: 1)).replacingOccurrences(of: ",", with: "")
                    price = Double(priceStr) ?? 0.0
                }
            }

            guard price > 0 else { return nil }

            return StockQuote(
                symbol: symbol,
                name: name,
                price: price,
                change: change,
                changePercent: percent,
                regularMarketPreviousClose: price - change,
                currency: "JPY",
                marketState: "CLOSED",
                dayHigh: nil,
                dayLow: nil,
                fiftyTwoWeekHigh: nil,
                fiftyTwoWeekLow: nil,
                preMarketPrice: nil,
                preMarketChange: nil,
                preMarketChangePercent: nil,
                postMarketPrice: nil,
                postMarketChange: nil,
                postMarketChangePercent: nil
            )
        } catch {
            return nil
        }
    }

    // MARK: - Binance Exchange Info Cache

    private struct BinanceSymbolInfo: Decodable {
        let symbol: String
        let baseAsset: String
        let quoteAsset: String
        let status: String
    }

    private struct BinanceExchangeInfoResponse: Decodable {
        let symbols: [BinanceSymbolInfo]
    }

    private var cachedBinanceSymbols: [BinanceSymbolInfo]?
    private var binanceSymbolsFetchedAt: Date?

    /// Fetches Binance exchangeInfo (all trading pairs) and caches for 6 hours.
    /// Response is ~2MB so we call once and filter client-side on every search.
    private func fetchBinanceExchangeInfo() async -> [BinanceSymbolInfo] {
        if let cached = cachedBinanceSymbols, let at = binanceSymbolsFetchedAt,
           Date().timeIntervalSince(at) < 21600 {
            return cached
        }
        guard let url = URL(string: "https://api.binance.com/api/v3/exchangeInfo") else {
            return cachedBinanceSymbols ?? []
        }
        do {
            let (data, _) = try await session.data(from: url)
            let response = try JSONDecoder().decode(BinanceExchangeInfoResponse.self, from: data)
            let active = response.symbols.filter { $0.status == "TRADING" }
            cachedBinanceSymbols = active
            binanceSymbolsFetchedAt = Date()
            return active
        } catch {
            return cachedBinanceSymbols ?? []
        }
    }

    /// Searches Binance trading pairs. Matches both the base asset (e.g. "BTC",
    /// "HYPE" → returns BTC-USD / HYPE-USD) AND full native pair symbols
    /// (e.g. "BTCUSDT", "HYPEUSDT" → returns the native pair directly).
    private func fetchBinanceSearch(query: String) async -> [SearchResult] {
        let allSymbols = await fetchBinanceExchangeInfo()
        let upperQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard upperQuery.count >= 2 else { return [] }

        // Group by baseAsset, find matching base assets
        var baseMap: [String: [BinanceSymbolInfo]] = [:]
        for s in allSymbols {
            baseMap[s.baseAsset, default: []].append(s)
        }

        // Quote priority for picking the best pair per base asset
        let quotePriority: [String: Int] = ["USDT": 0, "USDC": 1, "FDUSD": 2, "BTC": 3, "ETH": 4]

        var results: [SearchResult] = []
        var seenBase = Set<String>()

        // Pass 1: match base asset (HYPE → HYPE-USD)
        for (base, pairs) in baseMap where base.contains(upperQuery) {
            let isStablecoin = ["USDT", "USDC", "BUSD", "DAI", "TUSD", "FDUSD", "USDP", "PAXG"].contains(base)
            let type = isStablecoin ? "CRYPTOCURRENCY" : "CRYPTOCURRENCY"

            // Pick best quote pair
            let bestPair = pairs.min { a, b in
                let pa = quotePriority[a.quoteAsset] ?? 9
                let pb = quotePriority[b.quoteAsset] ?? 9
                return pa < pb
            }

            let displaySymbol = bestPair.flatMap { _ in "\(base)-USD" } ?? base
            results.append(SearchResult(
                symbol: displaySymbol,
                name: base,
                exchange: "Binance",
                type: type
            ))
            seenBase.insert(base)
        }

        // Pass 2: match full pair symbols (BTCUSDT, HYPEUSDT) — return native pair.
        // Only show native pairs when the query look like a pair (≥4 chars), so
        // single-char queries like "B" don't dump all pairs.
        var nativeCount = 0
        let maxNativeResults = 20
        if upperQuery.count >= 4 {
            for s in allSymbols where s.symbol.contains(upperQuery) {
                // Skip if this base already surfaced via pass 1.
                if seenBase.contains(s.baseAsset) { continue }
                results.append(SearchResult(
                    symbol: s.symbol,
                    name: s.baseAsset,
                    exchange: "Binance",
                    type: "CRYPTOCURRENCY"
                ))
                nativeCount += 1
                if nativeCount >= maxNativeResults { break }
            }
        }

        // Pass 3: inverted cross pairs. Binance lists ETH/BTC (ETHBTC), not
        // BTC/ETH. If the query is a cross pair that only exists inverted
        // (e.g. BTCETH → ETHBTC), surface it so the user can still add it —
        // the quote engine inverts the price back automatically.
        if let inverted = Self.invertedBinancePair(upperQuery),
           allSymbols.contains(where: { $0.symbol == inverted }),
           !results.contains(where: { $0.symbol.uppercased() == upperQuery }) {
            results.append(SearchResult(
                symbol: upperQuery,
                name: upperQuery,
                exchange: "Binance",
                type: "CRYPTOCURRENCY"
            ))
        }

        return results
    }

    /// Returns a canonical key for deduplication: "CRYPTO:BTC", "STOCK:AAPL", etc.
    private static func canonicalKey(symbol: String, type: String) -> String {
        let clean = symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let base = clean.hasSuffix("-USD") ? String(clean.dropLast(4)) : clean
        if type.uppercased() == "CRYPTOCURRENCY" || base == clean && !clean.contains("-") {
            return "CRYPTO:\(base)"
        }
        return "STOCK:\(clean)"
    }

    func search(query: String) async -> [SearchResult] {
        guard !query.isEmpty else { return [] }

        var fundResults: [SearchResult] = []
        let cleanQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let upperQuery = cleanQuery.uppercased()

        for fund in Self.popularJapaneseFunds {
            if fund.symbol.contains(upperQuery) || fund.name.localizedCaseInsensitiveContains(cleanQuery) {
                fundResults.append(fund)
            }
        }

        for index in Self.popularJapaneseIndices {
            if index.symbol.contains(upperQuery) || index.name.localizedCaseInsensitiveContains(cleanQuery) {
                fundResults.append(index)
            }
        }

        // Only suggest as a mutual fund if the query genuinely looks like one
        // (code in our fund map or Japanese characters) — not for generic
        // 5-12 char alphanumeric strings like "BTCETH", "HYPEUSDT".
        if isJapaneseMutualFund(cleanQuery),
           !fundResults.contains(where: { $0.symbol == upperQuery }),
           (Self.codeToFundNameMap[upperQuery] != nil || Self.containsJapaneseCharacters(cleanQuery)) {
            fundResults.append(SearchResult(symbol: upperQuery, name: "投資信託 (\(upperQuery))", exchange: "JP_FUND", type: "MUTUALFUND"))
        }

        // Run Yahoo and Binance search in parallel
        async let yahooTask = fetchYahooSearch(query: query)
        async let binanceTask = fetchBinanceSearch(query: upperQuery)

        let (yahooResults, binanceResults) = await (yahooTask, binanceTask)

        // Merge: canonical key dedup. Yahoo wins for metadata (name/exchange),
        // but we record that Binance also has this asset so the UI can show both sources.
        var merged: [String: SearchResult] = [:]

        // Yahoo first (higher priority for name/exchange/type)
        for r in yahooResults {
            let key = Self.canonicalKey(symbol: r.symbol, type: r.type)
            merged[key] = r // Yahoo wins for metadata
        }

        // Binance: add only if canonical key not already present
        for r in binanceResults {
            let key = Self.canonicalKey(symbol: r.symbol, type: r.type)
            if merged[key] == nil {
                merged[key] = r
            }
            // If already present from Yahoo, we keep Yahoo's metadata (name, exchange).
            // The quote source (Binance vs Yahoo) is handled by fetchQuotes, not search.
        }

        // Sort: Yahoo results first, then Binance-unique
        var final: [SearchResult] = []
        for r in yahooResults {
            let key = Self.canonicalKey(symbol: r.symbol, type: r.type)
            if let m = merged.removeValue(forKey: key) {
                final.append(m)
            }
        }
        // Remaining are Binance-unique
        for r in binanceResults {
            let key = Self.canonicalKey(symbol: r.symbol, type: r.type)
            if let m = merged[key] {
                final.append(m)
            }
        }

        return fundResults + final
    }

    private func fetchYahooSearch(query: String) async -> [SearchResult] {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        guard let url = URL(string: "https://query2.finance.yahoo.com/v1/finance/search?q=\(encoded)&quotesCount=10&newsCount=0") else {
            return []
        }
        do {
            let (data, _) = try await session.data(from: url)
            let response = try JSONDecoder().decode(YahooSearchResponse.self, from: data)
            return response.quotes
        } catch {
            return []
        }
    }

    // MARK: - Finance News (Home tab)

    /// Refresh the Home news feed. Pulls stories related to the user's tracked
    /// symbols (or general market news when nothing is tracked), from the same
    /// Yahoo search endpoint used for quote lookup — no API key required.
    /// Throttled to at most once every 5 minutes unless `force` is set.
    func refreshNews(storageService: StorageService, force: Bool = false) async {
        if !force, !news.isEmpty, let last = lastNewsFetch,
           Date().timeIntervalSince(last) < 300 {
            return
        }
        isLoadingNews = true
        defer { isLoadingNews = false }

        let symbols = Self.collectSymbols(storageService: storageService).sorted()
        // Each query is (search term, reference ticker). For tracked symbols the
        // reference ticker is the symbol itself; the general-market fallback has none.
        let queries: [(term: String, symbol: String?)] = symbols.isEmpty
            ? [("stock market", nil)]
            : symbols.prefix(6).map { ($0, $0) }

        var seen = Set<String>()
        var collected: [NewsArticle] = []
        await withTaskGroup(of: [NewsArticle].self) { group in
            for query in queries {
                group.addTask { [weak self] in
                    await self?.fetchNewsChunk(query: query.term, sourceSymbol: query.symbol) ?? []
                }
            }
            for await chunk in group {
                for article in chunk where !article.link.isEmpty && seen.insert(article.id).inserted {
                    collected.append(article)
                }
            }
        }
        collected.sort { $0.publishTime > $1.publishTime }
        news = Array(collected.prefix(40))
        lastNewsFetch = Date()
    }

    private func fetchNewsChunk(query: String, sourceSymbol: String?) async -> [NewsArticle] {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        guard let url = URL(string: "https://query1.finance.yahoo.com/v1/finance/search?q=\(encoded)&quotesCount=0&newsCount=10") else { return [] }
        do {
            let (data, _) = try await session.data(from: url)
            let articles = try JSONDecoder().decode(YahooNewsResponse.self, from: data).news ?? []
            guard let sourceSymbol else { return articles }
            return articles.map { var a = $0; a.sourceSymbol = sourceSymbol; return a }
        } catch {
            return []
        }
    }
}

// MARK: - Yahoo Finance v8 Chart API Models

/// Yahoo `v8/finance/spark` returns a dictionary keyed by symbol:
/// `{ "AAPL": { "timestamp": [...], "close": [...] }, ... }`.
/// Keep this parser independent from the chart endpoint because their response
/// envelopes are different even though both ultimately contain daily closes.
enum YahooSparkParser {
    private struct Series: Decodable {
        let symbol: String?
        let timestamp: [Int]?
        let close: [Double?]?
    }

    static func parse(_ data: Data) throws -> [String: [PricePoint]] {
        let response = try JSONDecoder().decode([String: Series].self, from: data)
        var histories: [String: [PricePoint]] = [:]
        histories.reserveCapacity(response.count)

        for (key, series) in response {
            let symbol = (series.symbol?.isEmpty == false ? series.symbol : nil) ?? key
            let points = PriceHistory.points(
                timestamps: series.timestamp ?? [],
                closes: series.close ?? []
            )
            if !points.isEmpty {
                histories[symbol] = points
            }
        }
        return histories
    }
}

private struct YahooChartResponse: Codable {
    let chart: ChartData

    struct ChartData: Codable {
        let result: [ChartResult]?
        let error: ChartError?
    }

    struct ChartResult: Codable {
        let meta: ChartMeta
        let timestamp: [Int]?
        let indicators: Indicators?
    }

    struct Indicators: Codable {
        let quote: [QuoteData]?
    }

    struct QuoteData: Codable {
        let open: [Double?]?
        let high: [Double?]?
        let low: [Double?]?
        let close: [Double?]?
    }

    struct ChartMeta: Codable {
        let symbol: String
        let currency: String?
        let regularMarketPrice: Double
        let regularMarketTime: Int?
        let chartPreviousClose: Double?
        let fiftyTwoWeekHigh: Double?
        let fiftyTwoWeekLow: Double?
        let longName: String?
        let shortName: String?
        let instrumentType: String?
        let currentTradingPeriod: TradingPeriods?
    }

    struct TradingPeriods: Codable {
        let pre: PeriodInfo?
        let regular: PeriodInfo?
        let post: PeriodInfo?
    }

    struct PeriodInfo: Codable {
        let start: Int
        let end: Int
    }

    struct ChartError: Codable {
        let code: String?
        let description: String?
    }
}

// MARK: - Yahoo Finance v7 Quote API Models

private struct YahooV7Response: Codable {
    let quoteResponse: QuoteResponse

    struct QuoteResponse: Codable {
        let result: [V7Quote]?
        let error: V7Error?
    }

    struct V7Quote: Codable {
        let symbol: String
        let longName: String?
        let shortName: String?
        let currency: String?
        let regularMarketPrice: Double?
        let regularMarketChange: Double?
        let regularMarketChangePercent: Double?
        let regularMarketPreviousClose: Double?
        let marketState: String?
        let regularMarketDayHigh: Double?
        let regularMarketDayLow: Double?
        let fiftyTwoWeekHigh: Double?
        let fiftyTwoWeekLow: Double?
        let preMarketPrice: Double?
        let postMarketPrice: Double?
        let marketCap: Double?
        let quoteType: String?
    }

    struct V7Error: Codable {
        let code: String?
        let description: String?
    }
}

private struct YahooSearchResponse: Codable {
    let quotes: [SearchResult]
}

private struct YahooNewsResponse: Decodable {
    let news: [NewsArticle]?
}
