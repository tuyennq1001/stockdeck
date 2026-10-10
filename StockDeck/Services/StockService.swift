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
    /// Per-symbol news cache used by the symbol detail page. Each key is the
    /// canonical (uppercased) symbol; throttled separately from the Home feed.
    @Published var newsBySymbol: [String: [NewsArticle]] = [:]
    var isLoadingSymbolNews: Set<String> = []
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

    // MARK: - Fear & Greed Index
    @Published var stockFearGreed: FearGreedData?
    @Published var cryptoFearGreed: FearGreedData?
    private var fearGreedFetchedAt: Date?

    private let session: URLSession
    private var crumb: String?
    private var lastNewsFetch: Date?
    private var lastSymbolNewsFetch: [String: Date] = [:]
    private var priceHistoryFetchedAt: [String: Date] = [:]
    private var priceHistoryMaxAt: [String: Date] = [:]
    private var intradayFetchedAt: [String: Date] = [:]
    private var intradayWeekAt: [String: Date] = [:]
    private var sparkFetchedAt: Date?
    /// Single-flight: coalesces concurrent `ensurePriceHistory` calls for the
    /// same symbol so the window-open task and the range-change task never issue
    /// two identical daily-history requests.
    private var dailyHistoryTasks: [String: Task<Void, Never>] = [:]

    /// Caps how many Yahoo history requests are in flight at once and staggers
    /// them, so the per-symbol burst on the Portfolio window never trips Yahoo's
    /// rate limiter.
    private let historyGate = AsyncSemaphore(count: 3)
    /// Global cool-down: when Yahoo answers 429 we stop issuing chart requests
    /// for this long so the burst unwinds instead of re-hammering the endpoint.
    private let rateLimitLock = NSLock()
    private var yahooRateLimitUntil = Date.distantPast

    /// On-disk mirror of the (immutable) price history so relaunching the app
    /// within the TTL window needs zero network requests.
    private static let historyCacheFileName = "historyCache.json"
    private var historyCacheURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return appSupport.appendingPathComponent("StockDeck/\(Self.historyCacheFileName)")
    }
    private var historyCacheLoaded = false
    private var historyCacheSaveTask: Task<Void, Never>?

    /// Shared NAV history for Japanese mutual funds, keyed by fund code, so the
    /// daily and max-history paths never fetch the Yahoo Japan pages twice.
    private static var jpFundHistoryCache: [String: (points: [PricePoint], fetchedAt: Date)] = [:]
    private static let jpFundHistoryLock = NSLock()

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

        loadHistoryCache()
        Task {
            _ = await self.fetchCrumb()
        }
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

    static func collectWebSocketSymbols(storageService: StorageService) -> Set<String> {
        let all = collectSymbols(storageService: storageService)
        return all.filter { s in
            let clean = s.hasSuffix("-USD") ? String(s.dropLast(4)) : s
            return !StorageService.isStandardCryptoSymbol(clean)
                && !StorageService.isBinanceNativePair(s)
                && !StorageService.isStandardCryptoSymbol(s)
        }
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
        Task {
            await self.ensureSparklines(for: symbols)
        }
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
        let allWatchlistSymbols = Array(Set(storageService.watchlists.flatMap(\.symbols)))
        await ensureSparklines(for: allWatchlistSymbols, force: true)
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
        let secondaryCurrency = storageService.secondaryCurrency

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
        if !secondaryCurrency.isEmpty && secondaryCurrency != preferredCurrency {
            pairs.insert("\(preferredCurrency)|\(secondaryCurrency)")
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

    func rate(from fromCurrency: String, to toCurrency: String) -> Double {
        let fromUpper = fromCurrency.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let toUpper = toCurrency.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if fromUpper == toUpper || fromUpper.isEmpty || toUpper.isEmpty { return 1.0 }

        if let live = exchangeRates["\(fromUpper)\(toUpper)"], live > 0 { return live }
        if let inverseLive = exchangeRates["\(toUpper)\(fromUpper)"], inverseLive > 0 { return 1.0 / inverseLive }

        // Fallback for cross-currency when live FX rate is not in exchangeRates cache yet
        if toUpper == "USD", let rateUSD = Self.fallbackFxToUSD[fromUpper] {
            return rateUSD
        } else if fromUpper == "USD", let rateUSD = Self.fallbackFxToUSD[toUpper], rateUSD > 0 {
            return 1.0 / rateUSD
        } else if let fromUSD = Self.fallbackFxToUSD[fromUpper], let toUSD = Self.fallbackFxToUSD[toUpper], toUSD > 0 {
            return fromUSD / toUSD
        }

        return 1.0
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

        return rate(from: currency, to: preferred)
    }

    func fetchQuotes(symbols: [String]) async {
        guard !symbols.isEmpty else { return }

        // Resolve legacy/alternate tickers to the Yahoo-canonical symbol.
        // "^VNINDEX" was the first version we shipped; Yahoo actually serves
        // VN-Index as "^VNINDEX.VN". Mapping here keeps existing watchlist
        // entries working without requiring the user to remove & re-add.
        let canonicalAliases: [String: String] = [
            "^VNINDEX": "^VNINDEX.VN",
            "ALPHABET": "GOOGL",
            "FB": "META"
        ]
        let symbols = symbols.map { canonicalAliases[$0.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)] ?? $0 }

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
                    var quote = q
                    if quote == nil || (quote?.price ?? 0) <= 0 {
                        quote = self.japaneseFundFallbackQuote(symbol: sym)
                    }
                    if let quote, quote.price > 0 {
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
                && (StorageService.isStandardCryptoSymbol(clean) || StorageService.isStandardCryptoSymbol(sym) || StorageService.isBinanceNativePair(sym) || BinanceStablecoin.isUSDPegged(clean))
        }
        let stockSymbols = regularSymbols.filter { !cryptoSymbols.contains($0) && !equitySymbols.contains($0) }

        if !cryptoSymbols.isEmpty {
            await fetchBinanceCryptoQuotes(symbols: cryptoSymbols)
        }

        if !equitySymbols.isEmpty {
            await fetchBinanceEquityQuotes(symbols: equitySymbols)
        }

        let vnSymbols = stockSymbols.filter { self.isVietnameseStock($0) }
        let remainingStockSymbols = stockSymbols.filter { !vnSymbols.contains($0) }

        if !vnSymbols.isEmpty {
            await fetchVietnameseQuotes(symbols: vnSymbols)
        }

        guard !remainingStockSymbols.isEmpty else { return }

        // Try v7 batch quote first for regular stock/ETF symbols
        if await fetchQuotesV7(symbols: remainingStockSymbols) {
            return
        }

        // Fallback: fetch each stock symbol via v8 chart API
        await withTaskGroup(of: Void.self) { group in
            for symbol in remainingStockSymbols {
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

        // Also index quotes under legacy alias keys so existing watchlist
        // entries (e.g. "^VNINDEX") resolve to the canonical quote.
        for (alias, canonical) in canonicalAliases {
            if let quote = self.quotes[canonical], self.quotes[alias] == nil {
                self.quotes[alias] = quote
                self.quotes[alias.uppercased()] = quote
            }
        }
    }

    nonisolated private static let symbolAliases: [String: String] = [
        "ALPHABET": "GOOGL",
        "FB": "META"
    ]

    nonisolated static func canonicalSymbol(for symbol: String) -> String {
        let upper = symbol.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
        var base = upper
        let hasUSDSuffix = base.hasSuffix("-USD")
        if hasUSDSuffix {
            base = String(base.dropLast(4))
        }
        let hasEQPrefix = base.hasPrefix("EQ_")
        if hasEQPrefix && base.count > 3 {
            base = String(base.dropFirst(3))
        }

        if let aliased = symbolAliases[base] {
            return aliased
        }

        if hasEQPrefix {
            return base
        }

        if hasUSDSuffix && !StorageService.isStandardCryptoSymbol(base) {
            return base
        }

        return upper
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
                    marketState: regularQuote?.marketState ?? "CLOSED",
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

    private func fetchVietnameseQuotes(symbols: [String]) async {
        let now = Int64(Date().timeIntervalSince1970)
        let fourteenDaysAgo = now - (14 * 86400)

        await withTaskGroup(of: (String, StockQuote?).self) { group in
            for symbol in symbols {
                group.addTask { [weak self] in
                    guard let self = self else { return (symbol, nil) }
                    let clean = symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                    let ticker = clean
                        .replacingOccurrences(of: ".HM", with: "")
                        .replacingOccurrences(of: ".HN", with: "")
                        .replacingOccurrences(of: ".VN", with: "")
                        .replacingOccurrences(of: "^", with: "")
                    let isIndex = ticker == "VNINDEX" || ticker == "HNXINDEX" || ticker == "UPINDEX" || clean.contains("VNINDEX")
                    let scale = isIndex ? 1.0 : 1000.0
                    let urlString = "\(VNMarketConfig.apiBaseURL)?resolution=D&symbol=\(ticker)&from=\(fourteenDaysAgo)&to=\(now)"
                    guard let url = URL(string: urlString) else { return (symbol, nil) }
                    do {
                        let (data, _) = try await self.session.data(from: url)
                        let response = try JSONDecoder().decode(VNDirectHistoryResponse.self, from: data)
                        guard let closes = response.c, let lastClose = closes.last else { return (symbol, nil) }
                        let prevClose = closes.count > 1 ? closes[closes.count - 2] : lastClose
                        let change = (lastClose - prevClose) * scale
                        let changePercent = prevClose > 0 ? ((lastClose - prevClose) / prevClose) * 100.0 : 0.0
                        let currentPrice = lastClose * scale
                        
                        let high = response.h?.max().map { $0 * scale }
                        let low = response.l?.min().map { $0 * scale }

                        let companyName = isIndex ? "VN-Index" : (Self.popularVietnameseStocks.first(where: { $0.symbol.uppercased() == ticker })?.name ?? ticker)
                        let currency = isIndex ? "PTS" : "VND"

                        let lastTimestamp = response.t?.last
                        let lastTradeDate = lastTimestamp.map { Date(timeIntervalSince1970: TimeInterval($0)) }
                        let schedule = MarketCategory.marketSchedule(for: symbol, isCrypto: false)
                        var calendar = Calendar(identifier: .gregorian)
                        calendar.timeZone = schedule.timeZone
                        let currentDate = Date()
                        let comps = calendar.dateComponents([.weekday, .hour, .minute], from: currentDate)
                        let weekday = comps.weekday ?? 1
                        let currentMinutes = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
                        let isWeekday = (weekday >= 2 && weekday <= 6)
                        let isWithinTradingHours = currentMinutes >= schedule.mondayOpenMinutes && currentMinutes <= schedule.regularCloseMinutes

                        let hasTradedToday = lastTradeDate.map { calendar.isDate($0, inSameDayAs: currentDate) } ?? false
                        let marketState: String
                        if isWeekday && isWithinTradingHours && hasTradedToday {
                            marketState = "REGULAR"
                        } else {
                            marketState = "CLOSED"
                        }

                        let quote = StockQuote(
                            symbol: symbol,
                            name: companyName,
                            price: currentPrice,
                            change: change,
                            changePercent: changePercent,
                            regularMarketPreviousClose: prevClose * scale,
                            currency: currency,
                            marketState: marketState,
                            regularMarketTime: lastTradeDate,
                            fiftyTwoWeekHigh: high,
                            fiftyTwoWeekLow: low
                        )
                        return (symbol, quote)
                    } catch {
                        return (symbol, nil)
                    }
                }
            }
            var collectedQuotes: [(String, StockQuote)] = []
            for await (originalSymbol, quote) in group {
                if let quote = quote {
                    collectedQuotes.append((originalSymbol, quote))
                }
            }

            // Market umbrella check: if any Vietnamese symbol (or VN-Index) has active trades today
            // and we are currently within trading hours on a weekday, propagate REGULAR state
            // to any other Vietnamese symbols in the batch that might be thinly traded.
            let schedule = MarketCategory.marketSchedule(for: "VNINDEX", isCrypto: false)
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = schedule.timeZone
            let now = Date()
            let comps = calendar.dateComponents([.weekday, .hour, .minute], from: now)
            let weekday = comps.weekday ?? 1
            let currentMinutes = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
            let isWeekday = (weekday >= 2 && weekday <= 6)
            let isWithinTradingHours = currentMinutes >= schedule.mondayOpenMinutes && currentMinutes <= schedule.regularCloseMinutes

            let anySymbolTradedToday = collectedQuotes.contains { (_, q) in
                guard let rmt = q.regularMarketTime else { return false }
                return calendar.isDate(rmt, inSameDayAs: now)
            }
            let isMarketWideOpen = isWeekday && isWithinTradingHours && (anySymbolTradedToday || self.quotes["^VNINDEX.VN"]?.marketState == "REGULAR" || self.quotes["^VNINDEX"]?.marketState == "REGULAR")

            for (originalSymbol, quote) in collectedQuotes {
                var finalQuote = quote
                if isMarketWideOpen && finalQuote.marketState != "REGULAR" {
                    finalQuote = StockQuote(
                        symbol: quote.symbol,
                        name: quote.name,
                        price: quote.price,
                        change: quote.change,
                        changePercent: quote.changePercent,
                        regularMarketPreviousClose: quote.regularMarketPreviousClose,
                        currency: quote.currency,
                        marketState: "REGULAR",
                        regularMarketTime: quote.regularMarketTime ?? now,
                        dayHigh: quote.dayHigh,
                        dayLow: quote.dayLow,
                        fiftyTwoWeekHigh: quote.fiftyTwoWeekHigh,
                        fiftyTwoWeekLow: quote.fiftyTwoWeekLow,
                        marketCap: quote.marketCap
                    )
                }
                let upperOriginal = originalSymbol.uppercased()
                let upperQuoteSym = finalQuote.symbol.uppercased()
                self.quotes[upperOriginal] = finalQuote
                self.quotes[upperQuoteSym] = finalQuote
                if upperOriginal.contains("VNINDEX") || upperQuoteSym.contains("VNINDEX") {
                    self.quotes["^VNINDEX"] = finalQuote
                    self.quotes["^VNINDEX.VN"] = finalQuote
                    self.quotes["VNINDEX"] = finalQuote
                }
            }
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

    /// Parses raw Binance Kline 2D JSON array `[[openTime, open, high, low, close, volume...]]`
    /// into sorted PricePoints. When `invert` is true (for cross pairs like BTCETH derived from ETHBTC),
    /// reciprocals are calculated for OHLC.
    nonisolated static func parseBinanceKlines(data: Data, invert: Bool = false) -> [PricePoint] {
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [[Any]] else { return [] }
        var points: [PricePoint] = []
        let parseDouble: (Any) -> Double? = { val in
            if let str = val as? String { return Double(str) }
            if let num = val as? NSNumber { return num.doubleValue }
            return nil
        }
        for item in raw {
            guard item.count >= 5 else { continue }
            let openTimeMs: Double
            if let num = item[0] as? NSNumber {
                openTimeMs = num.doubleValue
            } else if let str = item[0] as? String, let num = Double(str) {
                openTimeMs = num
            } else { continue }

            guard let rawClose = parseDouble(item[4]), rawClose > 0 else { continue }
            let rawOpen = parseDouble(item[1]) ?? rawClose
            let rawHigh = parseDouble(item[2]) ?? rawClose
            let rawLow = parseDouble(item[3]) ?? rawClose

            let date = Date(timeIntervalSince1970: openTimeMs / 1000.0)
            if invert {
                let close = 1.0 / rawClose
                let open = rawOpen > 0 ? (1.0 / rawOpen) : close
                let high = rawLow > 0 ? (1.0 / rawLow) : close
                let low = rawHigh > 0 ? (1.0 / rawHigh) : close
                points.append(PricePoint(date: date, close: close, open: open, high: high, low: low))
            } else {
                points.append(PricePoint(date: date, close: rawClose, open: rawOpen, high: rawHigh, low: rawLow))
            }
        }
        return points.sorted { $0.date < $1.date }
    }

    /// Fetches 1D daily candles directly from Binance API for crypto symbols.
    /// Supports Spot, USD-M Futures, cross pairs (via inverted reciprocal), and stablecoins.
    func fetchBinanceKlines(for symbol: String) async -> [PricePoint] {
        let upper = symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        var clean = upper
        if clean.hasSuffix("-USD") {
            clean = String(clean.dropLast(4))
        }

        if BinanceStablecoin.isUSDPegged(clean) {
            let now = Date()
            let points = (0..<365).compactMap { dayOffset -> PricePoint? in
                guard let d = Calendar.current.date(byAdding: .day, value: -dayOffset, to: now) else { return nil }
                return PricePoint(date: Calendar.current.startOfDay(for: d), close: 1.0, open: 1.0, high: 1.0, low: 1.0)
            }.reversed()
            return Array(points)
        }

        let isNative = StorageService.isBinanceNativePair(clean)
        let inverted = isNative ? Self.invertedBinancePair(clean) : nil

        var candidates: [(pair: String, invert: Bool)] = []
        if let inverted {
            candidates.append((inverted, true))
        }
        if isNative {
            candidates.append((clean, false))
        } else {
            candidates.append(("\(clean)USDT", false))
            candidates.append(("\(clean)BTC", false))
        }

        for candidate in candidates {
            // 1. Try Binance Spot klines
            if let url = URL(string: "https://api.binance.com/api/v3/klines?symbol=\(candidate.pair)&interval=1d&limit=1000") {
                if let (data, resp) = try? await session.data(from: url),
                   let http = resp as? HTTPURLResponse, http.statusCode == 200 {
                    let points = Self.parseBinanceKlines(data: data, invert: candidate.invert)
                    if !points.isEmpty { return points }
                }
            }
            // 2. Try Binance USD-M Futures klines (e.g. HYPEUSDT)
            if let fapiUrl = URL(string: "https://fapi.binance.com/fapi/v1/klines?symbol=\(candidate.pair)&interval=1d&limit=1000") {
                if let (data, resp) = try? await session.data(from: fapiUrl),
                   let http = resp as? HTTPURLResponse, http.statusCode == 200 {
                    let points = Self.parseBinanceKlines(data: data, invert: candidate.invert)
                    if !points.isEmpty { return points }
                }
            }
        }
        return []
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
            let urlString = "https://api.binance.com/api/v3/ticker/tradingDay?symbols=[\"\(listed)\"]"
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
                // invalid (for example an unsupported tokenized-stock symbol or Futures-only pair).
                // Retry each pair independently so one bad asset cannot suppress
                // valid BTC/ETH/SOL quotes in the same request.
                print("[StockService] Binance ticker batch HTTP \(httpResp.statusCode); retrying symbols individually")
                for single in chunk {
                    let singleURL = URL(string: "https://api.binance.com/api/v3/ticker/tradingDay?symbol=\(single)")!
                    if let (sData, sResp) = try? await session.data(from: singleURL),
                       let sHttp = sResp as? HTTPURLResponse, sHttp.statusCode == 200,
                       let t = try? JSONDecoder().decode(BinanceTicker24hr.self, from: sData) {
                        tickerMap[t.symbol.uppercased()] = t
                    } else {
                        // Fallback to Binance Futures (e.g. HYPEUSDT)
                        let fapiURL = URL(string: "https://fapi.binance.com/fapi/v1/ticker/24hr?symbol=\(single)")!
                        if let (fData, fResp) = try? await session.data(from: fapiURL),
                           let fHttp = fResp as? HTTPURLResponse, fHttp.statusCode == 200,
                           let t = try? JSONDecoder().decode(BinanceTicker24hr.self, from: fData) {
                            tickerMap[t.symbol.uppercased()] = t
                        }
                    }
                }
            } catch {
                // A successful batch can still contain an unexpected response
                // shape; retrying individually keeps valid pairs available.
                print("[StockService] Failed to fetch Binance crypto tickers chunk: \(error); retrying symbols individually")
                for single in chunk {
                    let singleURL = URL(string: "https://api.binance.com/api/v3/ticker/tradingDay?symbol=\(single)")!
                    if let (sData, sResp) = try? await session.data(from: singleURL),
                       let sHttp = sResp as? HTTPURLResponse, sHttp.statusCode == 200,
                       let t = try? JSONDecoder().decode(BinanceTicker24hr.self, from: sData) {
                        tickerMap[t.symbol.uppercased()] = t
                    } else {
                        // Fallback to Binance Futures (e.g. HYPEUSDT)
                        let fapiURL = URL(string: "https://fapi.binance.com/fapi/v1/ticker/24hr?symbol=\(single)")!
                        if let (fData, fResp) = try? await session.data(from: fapiURL),
                           let fHttp = fResp as? HTTPURLResponse, fHttp.statusCode == 200,
                           let t = try? JSONDecoder().decode(BinanceTicker24hr.self, from: fData) {
                            tickerMap[t.symbol.uppercased()] = t
                        }
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
                self.quotes["\(cleanBase)-USD"] = quote
                self.quotes["\(cleanBase)USDT"] = quote
                StorageService.shared.setType("CRYPTOCURRENCY", for: sym)
                StorageService.shared.setType("CRYPTOCURRENCY", for: sym.uppercased())
                StorageService.shared.setType("CRYPTOCURRENCY", for: cleanBase)
                StorageService.shared.setType("CRYPTOCURRENCY", for: "\(cleanBase)-USD")
                StorageService.shared.setType("CRYPTOCURRENCY", for: "\(cleanBase)USDT")
                continue
            }

            // Match pair on Binance. Native pairs (BTCUSDT, BTCETH) are looked up
            // directly; base symbols (ETH, WBETH) fall back to <BASE>USDT or <BASE>BTC.
            // If a native pair like BTCETH doesn't exist, fall back to the inverted
            // pair (ETHBTC) and invert the price.
            let isNative = StorageService.isBinanceNativePair(cleanBase)
            let inverted = isNative ? Self.invertedBinancePair(cleanBase) : nil
            var matchedTicker: BinanceTicker24hr? = isNative
                ? (tickerMap[cleanBase] ?? (inverted.flatMap { tickerMap[$0] }))
                : (tickerMap["\(cleanBase)USDT"] ?? tickerMap["\(cleanBase)BTC"])
            let isInvertedQuote = isNative && tickerMap[cleanBase] == nil && (inverted.flatMap { tickerMap[$0] }) != nil

            // Fallback: Check Binance Futures directly for tokens listed on Futures only (e.g. HYPE, HYPEUSDT)
            if matchedTicker == nil {
                for candidate in ["\(cleanBase)USDT", cleanBase] {
                    if let cached = tickerMap[candidate] {
                        matchedTicker = cached
                        break
                    }
                    if let fapiURL = URL(string: "https://fapi.binance.com/fapi/v1/ticker/24hr?symbol=\(candidate)"),
                       let (fData, fResp) = try? await session.data(from: fapiURL),
                       let fHttp = fResp as? HTTPURLResponse, fHttp.statusCode == 200,
                       let t = try? JSONDecoder().decode(BinanceTicker24hr.self, from: fData) {
                        tickerMap[t.symbol.uppercased()] = t
                        matchedTicker = t
                        break
                    }
                }
            }

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
                    self.quotes["\(cleanBase)-USD"] = quote
                    self.quotes["\(cleanBase)USDT"] = quote
                    StorageService.shared.setType("CRYPTOCURRENCY", for: sym)
                    StorageService.shared.setType("CRYPTOCURRENCY", for: sym.uppercased())
                    StorageService.shared.setType("CRYPTOCURRENCY", for: cleanBase)
                    StorageService.shared.setType("CRYPTOCURRENCY", for: "\(cleanBase)-USD")
                    StorageService.shared.setType("CRYPTOCURRENCY", for: "\(cleanBase)USDT")
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
                self.quotes["\(cleanBase)-USD"] = quote
                self.quotes["\(cleanBase)USDT"] = quote
                let quoteAssets = ["USDT", "USDC", "BUSD", "DAI", "TUSD", "FDUSD", "USD"]
                for q in quoteAssets where cleanBase.hasSuffix(q) && cleanBase.count > q.count {
                    let base = String(cleanBase.dropLast(q.count))
                    self.quotes[base] = quote
                    self.quotes["\(base)-USD"] = quote
                    self.quotes["\(base)\(q)"] = quote
                    StorageService.shared.setType("CRYPTOCURRENCY", for: base)
                    StorageService.shared.setType("CRYPTOCURRENCY", for: "\(base)-USD")
                    StorageService.shared.setType("CRYPTOCURRENCY", for: "\(base)\(q)")
                }
                StorageService.shared.setType("CRYPTOCURRENCY", for: sym)
                StorageService.shared.setType("CRYPTOCURRENCY", for: sym.uppercased())
                StorageService.shared.setType("CRYPTOCURRENCY", for: cleanBase)
                StorageService.shared.setType("CRYPTOCURRENCY", for: "\(cleanBase)-USD")
                StorageService.shared.setType("CRYPTOCURRENCY", for: "\(cleanBase)USDT")
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
                regularMarketTime: q.regularMarketTime.map { Date(timeIntervalSince1970: TimeInterval($0)) },
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
                regularMarketTime: meta.regularMarketTime.map { Date(timeIntervalSince1970: TimeInterval($0)) },
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

    // MARK: - Yahoo chart request throttling & disk cache

    /// Runs a Yahoo `v8/finance/chart` GET under a concurrency cap with
    /// inter-request spacing, a global cool-down after a 429, and an automatic
    /// `query2` host fallback. Returns the raw body on success or nil when every
    /// host failed or was rate-limited.
    private func fetchYahooChart(url primary: URL, fallback secondary: URL) async -> Data? {
        // Global cool-down: wait out the current rate-limit window (capped at
        // 30s per sleep) before issuing anything new.
        while true {
            if Task.isCancelled { return nil }
            var remaining: TimeInterval = 0
            rateLimitLock.lock()
            remaining = yahooRateLimitUntil.timeIntervalSinceNow
            rateLimitLock.unlock()
            guard remaining > 0 else { break }
            try? await Task.sleep(nanoseconds: UInt64(min(remaining, 30.0) * 1_000_000_000))
        }

        await historyGate.wait()
        defer { historyGate.signal() }

        // Stagger requests so the per-symbol burst does not trip the threshold.
        try? await Task.sleep(nanoseconds: 150_000_000)

        for url in [primary, secondary] {
            do {
                let (data, response) = try await session.data(from: url)
                if let http = response as? HTTPURLResponse {
                    if http.statusCode == 429 {
                        rateLimitLock.lock()
                        yahooRateLimitUntil = Date().addingTimeInterval(45)
                        rateLimitLock.unlock()
                        continue
                    }
                    guard http.statusCode == 200 else { continue }
                }
                return data
            } catch {
                continue
            }
        }
        return nil
    }

    private struct HistoryCacheEntry: Codable {
        var points: [PricePoint]
        var fetchedAt: Date
    }

    /// Loads the on-disk history cache into memory. Entries are reused for as
    /// long as their fetch timestamp is still inside the corresponding TTL, so
    /// relaunching the app shortly after a fetch issues no network requests.
    private func loadHistoryCache() {
        guard !historyCacheLoaded,
              let data = try? Data(contentsOf: historyCacheURL),
              let decoded = try? JSONDecoder().decode([String: HistoryCacheEntry].self, from: data) else { return }
        historyCacheLoaded = true
        let now = Date()
        for (key, entry) in decoded where !entry.points.isEmpty && entry.fetchedAt <= now {
            if key.hasPrefix("daily:"), priceHistoryFetchedAt[String(key.dropFirst(6))] == nil {
                let symbol = String(key.dropFirst(6))
                priceHistory[symbol] = entry.points
                priceHistoryFetchedAt[symbol] = entry.fetchedAt
            } else if key.hasPrefix("max:"), priceHistoryMaxAt[String(key.dropFirst(4))] == nil {
                let symbol = String(key.dropFirst(4))
                priceHistoryMax[symbol] = entry.points
                priceHistoryMaxAt[symbol] = entry.fetchedAt
            } else if key.hasPrefix("spark:"), watchlistHistory[String(key.dropFirst(6))] == nil {
                let symbol = String(key.dropFirst(6))
                watchlistHistory[symbol] = entry.points
            }
        }

        // Self-heal: ensure watchlistHistory and priceHistory are in sync with the freshest available series
        var didHeal = false
        for (symbol, daily) in priceHistory where !daily.isEmpty {
            let spark = watchlistHistory[symbol] ?? []
            let dailyLast = daily.last?.date ?? .distantPast
            let sparkLast = spark.last?.date ?? .distantPast
            if spark.isEmpty || dailyLast > sparkLast || (dailyLast == sparkLast && daily.count > spark.count) {
                watchlistHistory[symbol] = daily
                didHeal = true
            }
        }
        for (symbol, spark) in watchlistHistory where !spark.isEmpty {
            if priceHistory[symbol] == nil || (priceHistory[symbol]?.isEmpty ?? true) {
                priceHistory[symbol] = spark
                priceHistoryFetchedAt[symbol] = sparkFetchedAt ?? Date()
                didHeal = true
            }
        }
        if didHeal {
            scheduleHistoryCacheSave()
        }
    }

    /// Coalesces writes to the on-disk cache: several symbols can finish around
    /// the same time, but the file is only rewritten once shortly after.
    private func scheduleHistoryCacheSave() {
        historyCacheSaveTask?.cancel()
        historyCacheSaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled, let self else { return }
            self.saveHistoryCache()
        }
    }

    private func saveHistoryCache() {
        var entries: [String: HistoryCacheEntry] = [:]
        for (symbol, points) in priceHistory where !points.isEmpty {
            if let at = priceHistoryFetchedAt[symbol] {
                entries["daily:\(symbol)"] = HistoryCacheEntry(points: points, fetchedAt: at)
            }
        }
        for (symbol, points) in priceHistoryMax where !points.isEmpty {
            if let at = priceHistoryMaxAt[symbol] {
                entries["max:\(symbol)"] = HistoryCacheEntry(points: points, fetchedAt: at)
            }
        }
        for (symbol, points) in watchlistHistory where !points.isEmpty {
            entries["spark:\(symbol)"] = HistoryCacheEntry(points: points, fetchedAt: priceHistoryFetchedAt[symbol] ?? sparkFetchedAt ?? Date())
        }
        guard !entries.isEmpty, let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: historyCacheURL, options: .atomic)
    }

    /// Loads (or refreshes after ~6h) ten years of daily closes for the detail
    /// chart. Real Yahoo history — the portfolio value chart intentionally has no
    /// backfill, but a single symbol's price history is accurate data. Concurrent
    /// calls for the same symbol share one network request.
    func ensurePriceHistory(for symbol: String) async {
        if let at = priceHistoryFetchedAt[symbol],
           Date().timeIntervalSince(at) < 21600,
           let points = priceHistory[symbol], !points.isEmpty {
            // Self-healing: if cached Vietnamese stock history only has ~1 year (from previous version <= 300 points),
            // bypass cache to upgrade to the full 10-year history
            if isVietnameseStock(symbol) && points.count <= 300 {
                // proceed to re-fetch
            } else {
                return
            }
        }

        if let existing = dailyHistoryTasks[symbol] {
            await existing.value
            return
        }

        let task: Task<Void, Never> = Task { [weak self] in
            _ = await self?.loadPriceHistory(symbol)
        }
        dailyHistoryTasks[symbol] = task
        await task.value
        dailyHistoryTasks[symbol] = nil
    }


    private func yahooSymbol(for symbol: String) -> String {
        let upper = symbol.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if upper.hasSuffix("-USD") {
            let base = String(upper.dropLast(4))
            if StorageService.isStandardCryptoSymbol(base) || BinanceStablecoin.isUSDPegged(base) {
                return upper
            } else {
                return base
            }
        }
        if StorageService.isStandardCryptoSymbol(upper) { return "\(upper)-USD" }
        if StorageService.isBinanceNativePair(upper) {
            let quoteAssets = ["USDT", "USDC", "BUSD", "DAI", "TUSD", "FDUSD", "USD"]
            for q in quoteAssets where upper.hasSuffix(q) && upper.count > q.count {
                let base = String(upper.dropLast(q.count))
                return "\(base)-USD"
            }
        }
        return symbol
    }

    private func loadPriceHistory(_ symbol: String) async {
        if isJapaneseMutualFund(symbol) {
            let points = await fetchJapaneseFundHistory(symbol: symbol)
            guard !points.isEmpty, points.count >= (priceHistory[symbol]?.count ?? 0) else { return }
            priceHistory[symbol] = points
            watchlistHistory[symbol] = points
            priceHistoryFetchedAt[symbol] = Date()
            scheduleHistoryCacheSave()
            return
        }

        if isVietnameseStock(symbol) {
            let clean = symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                .replacingOccurrences(of: ".HM", with: "").replacingOccurrences(of: ".HN", with: "").replacingOccurrences(of: ".VN", with: "")
                .replacingOccurrences(of: "^", with: "")
            let isIndex = clean == "VNINDEX" || clean == "HNXINDEX" || clean == "UPINDEX"
            let scale = isIndex ? 1.0 : 1000.0
            let now = Int64(Date().timeIntervalSince1970)
            let tenYearsAgo = now - (10 * 365 * 86400)
            let urlString = "\(VNMarketConfig.apiBaseURL)?resolution=D&symbol=\(clean)&from=\(tenYearsAgo)&to=\(now)"
            guard let url = URL(string: urlString) else { return }
            do {
                let (data, _) = try await session.data(from: url)
                let response = try JSONDecoder().decode(VNDirectHistoryResponse.self, from: data)
                guard let closes = response.c, let timestamps = response.t, !closes.isEmpty else { return }
                let scaledCloses = closes.map { $0 * scale }
                let scaledOpens = response.o?.map { $0 * scale }
                let scaledHighs = response.h?.map { $0 * scale }
                let scaledLows = response.l?.map { $0 * scale }
                let points = PriceHistory.points(timestamps: timestamps.map { Int($0) }, closes: scaledCloses, opens: scaledOpens, highs: scaledHighs, lows: scaledLows)
                guard !points.isEmpty else { return }
                priceHistory[symbol] = points
                priceHistory[symbol.uppercased()] = points
                watchlistHistory[symbol] = points
                watchlistHistory[symbol.uppercased()] = points
                if clean == "VNINDEX" {
                    priceHistory["^VNINDEX"] = points
                    priceHistory["^VNINDEX.VN"] = points
                    priceHistory["VNINDEX"] = points
                    watchlistHistory["^VNINDEX"] = points
                    watchlistHistory["^VNINDEX.VN"] = points
                    watchlistHistory["VNINDEX"] = points
                }
                priceHistoryFetchedAt[symbol] = Date()
                if priceHistoryMax[symbol] == nil || (priceHistoryMax[symbol]?.isEmpty ?? true) {
                    let monthly = PriceHistory.deriveMonthly(from: points)
                    if !monthly.isEmpty {
                        priceHistoryMax[symbol] = monthly
                        priceHistoryMaxAt[symbol] = Date()
                    }
                }
                scheduleHistoryCacheSave()
            } catch { return }
            return
        }

        let isCrypto = StorageService.isBinanceNativePair(symbol) || StorageService.isStandardCryptoSymbol(symbol) || (symbol.hasSuffix("-USD") && StorageService.isStandardCryptoSymbol(String(symbol.dropLast(4))))
        if isCrypto {
            let points = await fetchBinanceKlines(for: symbol)
            if !points.isEmpty {
                priceHistory[symbol] = points
                priceHistory[symbol.uppercased()] = points
                watchlistHistory[symbol] = points
                watchlistHistory[symbol.uppercased()] = points
                priceHistoryFetchedAt[symbol] = Date()
                if priceHistoryMax[symbol] == nil || (priceHistoryMax[symbol]?.isEmpty ?? true) {
                    let monthly = PriceHistory.deriveMonthly(from: points)
                    if !monthly.isEmpty {
                        priceHistoryMax[symbol] = monthly
                        priceHistoryMaxAt[symbol] = Date()
                    }
                }
                scheduleHistoryCacheSave()
                return
            }
        }

        let fetchSymbol = yahooSymbol(for: symbol)
        let encoded = fetchSymbol.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? fetchSymbol
        // range=10y daily closes & OHLC for 1Y/3Y/5Y/10Y chart ranges
        guard let primary = URL(string: "https://query1.finance.yahoo.com/v8/finance/chart/\(encoded)?interval=1d&range=10y"),
              let fallback = URL(string: "https://query2.finance.yahoo.com/v8/finance/chart/\(encoded)?interval=1d&range=10y") else { return }
        guard let data = await fetchYahooChart(url: primary, fallback: fallback) else { return }
        do {
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
            watchlistHistory[symbol] = points
            priceHistoryFetchedAt[symbol] = Date()
            scheduleHistoryCacheSave()
        } catch {
            // Non-fatal: the detail view keeps its placeholder band.
        }
    }

    /// Monthly closes over the full available history, for the "All" range. Cached ~6h.
    func ensurePriceHistoryMax(for symbol: String) async {
        if let at = priceHistoryMaxAt[symbol],
           Date().timeIntervalSince(at) < 21600,
           priceHistoryMax[symbol]?.isEmpty == false { return }

        if isJapaneseMutualFund(symbol) {
            let points = await fetchJapaneseFundHistory(symbol: symbol)
            guard !points.isEmpty, points.count >= (priceHistoryMax[symbol]?.count ?? 0) else { return }
            priceHistoryMax[symbol] = points
            priceHistoryMaxAt[symbol] = Date()
            scheduleHistoryCacheSave()
            return
        }

        if isVietnameseStock(symbol) {
            let clean = symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                .replacingOccurrences(of: ".HM", with: "").replacingOccurrences(of: ".HN", with: "").replacingOccurrences(of: ".VN", with: "")
                .replacingOccurrences(of: "^", with: "")
            let isIndex = clean == "VNINDEX" || clean == "HNXINDEX" || clean == "UPINDEX"
            let scale = isIndex ? 1.0 : 1000.0
            let now = Int64(Date().timeIntervalSince1970)
            let maxAgo = now - (20 * 365 * 86400)
            let urlString = "\(VNMarketConfig.apiBaseURL)?resolution=D&symbol=\(clean)&from=\(maxAgo)&to=\(now)"
            guard let url = URL(string: urlString) else { return }
            do {
                let (data, _) = try await session.data(from: url)
                let response = try JSONDecoder().decode(VNDirectHistoryResponse.self, from: data)
                guard let closes = response.c, let timestamps = response.t, !closes.isEmpty else { return }
                let scaledCloses = closes.map { $0 * scale }
                let scaledOpens = response.o?.map { $0 * scale }
                let scaledHighs = response.h?.map { $0 * scale }
                let scaledLows = response.l?.map { $0 * scale }
                let points = PriceHistory.points(timestamps: timestamps.map { Int($0) }, closes: scaledCloses, opens: scaledOpens, highs: scaledHighs, lows: scaledLows)
                guard !points.isEmpty else { return }
                priceHistoryMax[symbol] = points
                priceHistoryMaxAt[symbol] = Date()
                scheduleHistoryCacheSave()
            } catch { return }
            return
        }

        // Preferred: derive the monthly series locally from the 10-year daily
        // closes (no second network request). Only falls back to a real
        // interval=1mo&range=max request when the daily series is missing.
        await ensurePriceHistory(for: symbol)
        if let daily = priceHistory[symbol], !daily.isEmpty {
            let monthly = PriceHistory.deriveMonthly(from: daily)
            if !monthly.isEmpty {
                priceHistoryMax[symbol] = monthly
                priceHistoryMaxAt[symbol] = Date()
                return
            }
        }

        if StorageService.isBinanceNativePair(symbol) || StorageService.isStandardCryptoSymbol(symbol) {
            return
        }

        let fetchSymbol = yahooSymbol(for: symbol)
        let encoded = fetchSymbol.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? fetchSymbol
        guard let primary = URL(string: "https://query1.finance.yahoo.com/v8/finance/chart/\(encoded)?interval=1mo&range=max"),
              let fallback = URL(string: "https://query2.finance.yahoo.com/v8/finance/chart/\(encoded)?interval=1mo&range=max") else { return }
        guard let data = await fetchYahooChart(url: primary, fallback: fallback) else { return }
        do {
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
            scheduleHistoryCacheSave()
        } catch {
        }
    }

    /// Full monthly history for the "All" chart range. Derives from the daily
    /// 10y series locally first (no network); for symbols listed longer than
    /// ~10 years it also fetches Yahoo's `interval=1mo&range=max` so the "All"
    /// curve keeps its pre-10y depth. Fetched lazily — only when the user
    /// selects the "All" range.
    func ensureFullHistoryMax(for symbol: String) async {
        if let at = priceHistoryMaxAt[symbol],
           Date().timeIntervalSince(at) < 21600,
           priceHistoryMax[symbol]?.isEmpty == false { return }

        if isJapaneseMutualFund(symbol) {
            let points = await fetchJapaneseFundHistory(symbol: symbol)
            guard !points.isEmpty, points.count >= (priceHistoryMax[symbol]?.count ?? 0) else { return }
            priceHistoryMax[symbol] = points
            priceHistoryMaxAt[symbol] = Date()
            scheduleHistoryCacheSave()
            return
        }

        if isVietnameseStock(symbol) {
            await ensurePriceHistoryMax(for: symbol)
            return
        }

        await ensurePriceHistory(for: symbol)

        // Base: a monthly series derived from the daily 10y closes — always
        // available without a network request.
        var monthly: [PricePoint] = []
        if let daily = priceHistory[symbol], !daily.isEmpty {
            monthly = PriceHistory.deriveMonthly(from: daily)
            if !monthly.isEmpty {
                priceHistoryMax[symbol] = monthly
            }
        }

        var needsFullFetch = monthly.isEmpty
        if let daily = priceHistory[symbol], let first = daily.first {
            let spanYears = Date().timeIntervalSince(first.date) / (365.25 * 86400)
            needsFullFetch = needsFullFetch || spanYears >= 9.5
        }

        guard needsFullFetch else {
            priceHistoryMaxAt[symbol] = Date()
            scheduleHistoryCacheSave()
            return
        }

        // Best-effort full history for long-listed symbols. On failure the
        // derived 10y series stays in place and the TTL is left unstamped so a
        // later "All" selection retries instead of being locked out for 6h.
        let encoded = symbol.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? symbol
        guard let primary = URL(string: "https://query1.finance.yahoo.com/v8/finance/chart/\(encoded)?interval=1mo&range=max"),
              let fallback = URL(string: "https://query2.finance.yahoo.com/v8/finance/chart/\(encoded)?interval=1mo&range=max"),
              let data = await fetchYahooChart(url: primary, fallback: fallback) else {
            scheduleHistoryCacheSave()
            return
        }
        do {
            let response = try JSONDecoder().decode(YahooChartResponse.self, from: data)
            guard let result = response.chart.result?.first else {
                scheduleHistoryCacheSave()
                return
            }
            let q = result.indicators?.quote?.first
            let points = PriceHistory.points(timestamps: result.timestamp ?? [],
                                             closes: q?.close ?? [],
                                             opens: q?.open,
                                             highs: q?.high,
                                             lows: q?.low)
            guard !points.isEmpty else {
                scheduleHistoryCacheSave()
                return
            }
            priceHistoryMax[symbol] = points
            priceHistoryMaxAt[symbol] = Date()
            scheduleHistoryCacheSave()
        } catch {
            scheduleHistoryCacheSave()
        }
    }

    /// Loads (or refreshes after ~5min) one trading day of 5-minute closes for
    /// the "1D" chart range.
    func ensureIntraday(for symbol: String) async {
        if let at = intradayFetchedAt[symbol],
           Date().timeIntervalSince(at) < 300,
           intradayHistory[symbol]?.isEmpty == false { return }
        let encoded = symbol.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? symbol
        guard let primary = URL(string: "https://query1.finance.yahoo.com/v8/finance/chart/\(encoded)?interval=5m&range=1d"),
              let fallback = URL(string: "https://query2.finance.yahoo.com/v8/finance/chart/\(encoded)?interval=5m&range=1d"),
              let data = await fetchYahooChart(url: primary, fallback: fallback) else { return }
        do {
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
        let fetchSymbol = yahooSymbol(for: symbol)
        let encoded = fetchSymbol.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? fetchSymbol
        guard let primary = URL(string: "https://query1.finance.yahoo.com/v8/finance/chart/\(encoded)?interval=60m&range=7d"),
              let fallback = URL(string: "https://query2.finance.yahoo.com/v8/finance/chart/\(encoded)?interval=60m&range=7d"),
              let data = await fetchYahooChart(url: primary, fallback: fallback) else { return }
        do {
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
    func ensureSparklines(for symbols: [String], force: Bool = false) async {
        let isExpired = sparkFetchedAt.map { Date().timeIntervalSince($0) >= 1800 } ?? true
        let hasStaleSymbols = symbols.contains { sym in
            guard let last = watchlistHistory[sym]?.last?.date else { return true }
            return Date().timeIntervalSince(last) >= 86400 * 4
        }
        if !force && !isExpired && !hasStaleSymbols && symbols.allSatisfy({ watchlistHistory[$0]?.isEmpty == false }) {
            return
        }

        let targetSymbols: [String]
        if force || isExpired || hasStaleSymbols {
            targetSymbols = symbols
        } else {
            targetSymbols = symbols.filter { (watchlistHistory[$0]?.isEmpty ?? true) }
        }
        guard !targetSymbols.isEmpty else { sparkFetchedAt = Date(); return }

        let vnTargets = targetSymbols.filter { self.isVietnameseStock($0) }
        let cryptoTargets = targetSymbols.filter { sym in
            !vnTargets.contains(sym) &&
            (StorageService.isBinanceNativePair(sym) || StorageService.isStandardCryptoSymbol(sym) || sym.hasSuffix("-USD"))
        }
        let regularTargets = targetSymbols.filter { !vnTargets.contains($0) && !cryptoTargets.contains($0) }

        if !vnTargets.isEmpty {
            let now = Int64(Date().timeIntervalSince1970)
            let tenYearsAgo = now - (10 * 365 * 86400)
            await withTaskGroup(of: (String, [PricePoint]).self) { group in
                for sym in vnTargets {
                    group.addTask { [weak self] in
                        guard let self = self else { return (sym, []) }
                        let clean = sym.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                            .replacingOccurrences(of: ".HM", with: "").replacingOccurrences(of: ".HN", with: "").replacingOccurrences(of: ".VN", with: "")
                            .replacingOccurrences(of: "^", with: "")
                        let isIndex = clean == "VNINDEX" || clean == "HNXINDEX" || clean == "UPINDEX"
                        let scale = isIndex ? 1.0 : 1000.0
                        let urlString = "\(VNMarketConfig.apiBaseURL)?resolution=D&symbol=\(clean)&from=\(tenYearsAgo)&to=\(now)"
                        guard let url = URL(string: urlString) else { return (sym, []) }
                        do {
                            let (data, _) = try await self.session.data(from: url)
                            let response = try JSONDecoder().decode(VNDirectHistoryResponse.self, from: data)
                            guard let closes = response.c, let timestamps = response.t, !closes.isEmpty else { return (sym, []) }
                            let scaledCloses = closes.map { $0 * scale }
                            let scaledOpens = response.o?.map { $0 * scale }
                            let scaledHighs = response.h?.map { $0 * scale }
                            let scaledLows = response.l?.map { $0 * scale }
                            let points = PriceHistory.points(timestamps: timestamps.map { Int($0) }, closes: scaledCloses, opens: scaledOpens, highs: scaledHighs, lows: scaledLows)
                            return (sym, points)
                        } catch {
                            return (sym, [])
                        }
                    }
                }
                for await (sym, points) in group where !points.isEmpty {
                    self.watchlistHistory[sym] = points
                    self.watchlistHistory[sym.uppercased()] = points
                    self.priceHistory[sym] = points
                    self.priceHistory[sym.uppercased()] = points
                    self.priceHistoryFetchedAt[sym] = Date()
                    self.priceHistoryFetchedAt[sym.uppercased()] = Date()
                    if sym.contains("VNINDEX") {
                        self.watchlistHistory["^VNINDEX"] = points
                        self.watchlistHistory["^VNINDEX.VN"] = points
                        self.watchlistHistory["VNINDEX"] = points
                        self.priceHistory["^VNINDEX"] = points
                        self.priceHistory["^VNINDEX.VN"] = points
                        self.priceHistory["VNINDEX"] = points
                        self.priceHistoryFetchedAt["^VNINDEX"] = Date()
                        self.priceHistoryFetchedAt["^VNINDEX.VN"] = Date()
                        self.priceHistoryFetchedAt["VNINDEX"] = Date()
                    }
                    if self.priceHistoryMax[sym] == nil || (self.priceHistoryMax[sym]?.isEmpty ?? true) {
                        let monthly = PriceHistory.deriveMonthly(from: points)
                        if !monthly.isEmpty {
                            self.priceHistoryMax[sym] = monthly
                            self.priceHistoryMaxAt[sym] = Date()
                        }
                    }
                }
                scheduleHistoryCacheSave()
            }
        }

        if !cryptoTargets.isEmpty {
            await withTaskGroup(of: (String, [PricePoint]).self) { group in
                for sym in cryptoTargets {
                    group.addTask { [weak self] in
                        guard let self = self else { return (sym, []) }
                        let points = await self.fetchBinanceKlines(for: sym)
                        return (sym, points)
                    }
                }
                for await (sym, points) in group where !points.isEmpty {
                    self.watchlistHistory[sym] = points
                    self.watchlistHistory[sym.uppercased()] = points
                    if self.priceHistory[sym] == nil || (self.priceHistory[sym]?.isEmpty ?? true) {
                        self.priceHistory[sym] = points
                        self.priceHistoryFetchedAt[sym] = Date()
                    }
                    if self.priceHistoryMax[sym] == nil || (self.priceHistoryMax[sym]?.isEmpty ?? true) {
                        let monthly = PriceHistory.deriveMonthly(from: points)
                        if !monthly.isEmpty {
                            self.priceHistoryMax[sym] = monthly
                            self.priceHistoryMaxAt[sym] = Date()
                        }
                    }
                }
                scheduleHistoryCacheSave()
            }
        }

        if !regularTargets.isEmpty {
            let joined = regularTargets.joined(separator: ",")
            let encoded = joined.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? joined
            if let url = URL(string: "https://query1.finance.yahoo.com/v8/finance/spark?symbols=\(encoded)&range=5y&interval=1d") {
                do {
                    let (data, _) = try await session.data(from: url)
                    let parsed = try YahooSparkParser.parse(data)
                    for (symbol, points) in parsed where !points.isEmpty {
                        watchlistHistory[symbol] = points
                        if priceHistory[symbol] == nil || (priceHistory[symbol]?.isEmpty ?? true) {
                            priceHistory[symbol] = points
                            priceHistoryFetchedAt[symbol] = Date()
                        }
                        if priceHistoryMax[symbol] == nil || (priceHistoryMax[symbol]?.isEmpty ?? true) {
                            let monthly = PriceHistory.deriveMonthly(from: points)
                            if !monthly.isEmpty {
                                priceHistoryMax[symbol] = monthly
                                priceHistoryMaxAt[symbol] = Date()
                            }
                        }
                    }
                    scheduleHistoryCacheSave()
                } catch {
                }
            }
        }
        sparkFetchedAt = Date()
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

            // Chặn Yahoo WebSocket ghi đè các mã Crypto (do Binance quản lý 100%)
            let clean = symbol.hasSuffix("-USD") ? String(symbol.dropLast(4)) : symbol
            if StorageService.isStandardCryptoSymbol(clean) || StorageService.isBinanceNativePair(symbol) || StorageService.isStandardCryptoSymbol(symbol) {
                continue
            }

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

            // Precompute extended-hours values to reduce type-checker complexity
            let prePrice = marketState == "PRE" ? tickPrice : existing?.preMarketPrice
            let preChg = marketState == "PRE" ? tickChange : existing?.preMarketChange
            let prePct = marketState == "PRE" ? tickChangePercent : existing?.preMarketChangePercent
            let postPrice = marketState == "POST" ? tickPrice : existing?.postMarketPrice
            let postChg = marketState == "POST" ? tickChange : existing?.postMarketChange
            let postPct = marketState == "POST" ? tickChangePercent : existing?.postMarketChangePercent

            let marketCap = existing?.marketCap

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
                marketCap: marketCap,
                preMarketPrice: prePrice,
                preMarketChange: preChg,
                preMarketChangePercent: prePct,
                postMarketPrice: postPrice,
                postMarketChange: postChg,
                postMarketChangePercent: postPct
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

    nonisolated static let popularJapaneseFunds: [SearchResult] = [
        SearchResult(symbol: "9I31223A", name: "楽天・プラス・S&P500インデックス・ファンド", exchange: "JP_FUND", type: "MUTUALFUND"),
        SearchResult(symbol: "0331423B", name: "楽天・S&P500インデックス・ファンド", exchange: "JP_FUND", type: "MUTUALFUND"),
        SearchResult(symbol: "03311187", name: "eMAXIS Slim米国株式(S&P500)", exchange: "JP_FUND", type: "MUTUALFUND"),
        SearchResult(symbol: "0331317B", name: "iFreeNEXT NASDAQ100インデックス", exchange: "JP_FUND", type: "MUTUALFUND"),
        SearchResult(symbol: "0331119A", name: "auAM Nifty50インド株ファンド", exchange: "JP_FUND", type: "MUTUALFUND"),
        SearchResult(symbol: "03311181", name: "eMAXIS Slim 全世界株式(オール・カントリー)", exchange: "JP_FUND", type: "MUTUALFUND"),
        SearchResult(symbol: "9I31123A", name: "楽天・プラス・オールカントリー・インデックス・ファンド", exchange: "JP_FUND", type: "MUTUALFUND"),
        SearchResult(symbol: "0331418A", name: "楽天・全米株式インデックス・ファンド", exchange: "JP_FUND", type: "MUTUALFUND")
    ]

    nonisolated static let popularJapaneseIndices: [SearchResult] = [
        SearchResult(symbol: "^N225", name: "Nikkei 225", exchange: "JPX", type: "INDEX"),
        SearchResult(symbol: "^TOPX", name: "TOPIX", exchange: "JPX", type: "INDEX")
    ]

    nonisolated static let popularGlobalIndices: [SearchResult] = [
        SearchResult(symbol: "^KS11", name: "KOSPI Composite Index", exchange: "KSE", type: "INDEX"),
        SearchResult(symbol: "^VNINDEX.VN", name: "VN-Index", exchange: "HOSE", type: "INDEX"),
        SearchResult(symbol: "^HSI", name: "Hang Seng Index", exchange: "HKG", type: "INDEX"),
        SearchResult(symbol: "^STI", name: "Straits Times Index", exchange: "SGX", type: "INDEX"),
        SearchResult(symbol: "^AXJO", name: "S&P/ASX 200", exchange: "ASX", type: "INDEX"),
        SearchResult(symbol: "^NSEI", name: "Nifty 50", exchange: "NSE", type: "INDEX"),
        SearchResult(symbol: "^BSESN", name: "S&P BSE Sensex", exchange: "BSE", type: "INDEX"),
        SearchResult(symbol: "^GSPC", name: "S&P 500", exchange: "SNP", type: "INDEX"),
        SearchResult(symbol: "^DJI", name: "Dow Jones Industrial Average", exchange: "DJI", type: "INDEX"),
        SearchResult(symbol: "^IXIC", name: "NASDAQ Composite", exchange: "NMS", type: "INDEX"),
        SearchResult(symbol: "^FTSE", name: "FTSE 100", exchange: "LSE", type: "INDEX"),
        SearchResult(symbol: "^GDAXI", name: "DAX PERFORMANCE-INDEX", exchange: "GER", type: "INDEX"),
        SearchResult(symbol: "^FCHI", name: "CAC 40", exchange: "PAR", type: "INDEX"),
        SearchResult(symbol: "^TWII", name: "TSEC weighted index", exchange: "TAI", type: "INDEX"),
        SearchResult(symbol: "^KOSDAQ", name: "KOSDAQ Composite Index", exchange: "KOSDAQ", type: "INDEX")
    ]

    /// Common aliases users type that don't substring-match Yahoo tickers:
    /// index abbreviations (SPX), futures (ES=F), and commodities (XAUUSD).
    nonisolated static let popularIndexAliases: [String: SearchResult] = [
        // Index abbreviations
        "SPX": SearchResult(symbol: "^GSPC", name: "S&P 500", exchange: "SNP", type: "INDEX"),
        "SP500": SearchResult(symbol: "^GSPC", name: "S&P 500", exchange: "SNP", type: "INDEX"),
        "DOW": SearchResult(symbol: "^DJI", name: "Dow Jones Industrial Average", exchange: "DJI", type: "INDEX"),
        "DJIA": SearchResult(symbol: "^DJI", name: "Dow Jones Industrial Average", exchange: "DJI", type: "INDEX"),
        "NASDAQ": SearchResult(symbol: "^IXIC", name: "NASDAQ Composite", exchange: "NMS", type: "INDEX"),
        "NDX": SearchResult(symbol: "^IXIC", name: "NASDAQ Composite", exchange: "NMS", type: "INDEX"),
        "KOSDAQ": SearchResult(symbol: "^KOSDAQ", name: "KOSDAQ Composite Index", exchange: "KOSDAQ", type: "INDEX"),
        "N225": SearchResult(symbol: "^N225", name: "Nikkei 225", exchange: "JPX", type: "INDEX"),
        "NIKKEI": SearchResult(symbol: "^N225", name: "Nikkei 225", exchange: "JPX", type: "INDEX"),
        "NIKKEI225": SearchResult(symbol: "^N225", name: "Nikkei 225", exchange: "JPX", type: "INDEX"),
        "TOPIX": SearchResult(symbol: "^TOPX", name: "TOPIX", exchange: "JPX", type: "INDEX"),
        "KOSPI": SearchResult(symbol: "^KS11", name: "KOSPI Composite Index", exchange: "KSE", type: "INDEX"),
        "NIFTY": SearchResult(symbol: "^NSEI", name: "Nifty 50", exchange: "NSE", type: "INDEX"),
        "NIFTY50": SearchResult(symbol: "^NSEI", name: "Nifty 50", exchange: "NSE", type: "INDEX"),
        "SENSEX": SearchResult(symbol: "^BSESN", name: "S&P BSE Sensex", exchange: "BSE", type: "INDEX"),
        "HANGSENG": SearchResult(symbol: "^HSI", name: "Hang Seng Index", exchange: "HKG", type: "INDEX"),
        "HSI": SearchResult(symbol: "^HSI", name: "Hang Seng Index", exchange: "HKG", type: "INDEX"),
        "ASX200": SearchResult(symbol: "^AXJO", name: "S&P/ASX 200", exchange: "ASX", type: "INDEX"),
        "ASX": SearchResult(symbol: "^AXJO", name: "S&P/ASX 200", exchange: "ASX", type: "INDEX"),
        "DAX": SearchResult(symbol: "^GDAXI", name: "DAX", exchange: "GER", type: "INDEX"),
        "CAC": SearchResult(symbol: "^FCHI", name: "CAC 40", exchange: "PAR", type: "INDEX"),
        "CAC40": SearchResult(symbol: "^FCHI", name: "CAC 40", exchange: "PAR", type: "INDEX"),
        "FTSE": SearchResult(symbol: "^FTSE", name: "FTSE 100", exchange: "LSE", type: "INDEX"),
        "FTSE100": SearchResult(symbol: "^FTSE", name: "FTSE 100", exchange: "LSE", type: "INDEX"),
        "TAIEX": SearchResult(symbol: "^TWII", name: "TSEC weighted index", exchange: "TAI", type: "INDEX"),
        "TWII": SearchResult(symbol: "^TWII", name: "TSEC weighted index", exchange: "TAI", type: "INDEX"),
        "VNINDEX": SearchResult(symbol: "^VNINDEX.VN", name: "VN-Index", exchange: "HOSE", type: "INDEX"),
        "VN": SearchResult(symbol: "^VNINDEX.VN", name: "VN-Index", exchange: "HOSE", type: "INDEX"),
        "STI": SearchResult(symbol: "^STI", name: "Straits Times Index", exchange: "SGX", type: "INDEX"),
        // Index futures
        "ES": SearchResult(symbol: "ES=F", name: "E-mini S&P 500 Futures", exchange: "CME", type: "FUTURE"),
        "ES=F": SearchResult(symbol: "ES=F", name: "E-mini S&P 500 Futures", exchange: "CME", type: "FUTURE"),
        "SPX FUTURES": SearchResult(symbol: "ES=F", name: "E-mini S&P 500 Futures", exchange: "CME", type: "FUTURE"),
        "S&P 500 FUTURES": SearchResult(symbol: "ES=F", name: "E-mini S&P 500 Futures", exchange: "CME", type: "FUTURE"),
        "E-MINI": SearchResult(symbol: "ES=F", name: "E-mini S&P 500 Futures", exchange: "CME", type: "FUTURE"),
        "EMINI": SearchResult(symbol: "ES=F", name: "E-mini S&P 500 Futures", exchange: "CME", type: "FUTURE"),
        "E-MINI S&P 500": SearchResult(symbol: "ES=F", name: "E-mini S&P 500 Futures", exchange: "CME", type: "FUTURE"),
        "E-MINI S&P 500 FUTURES": SearchResult(symbol: "ES=F", name: "E-mini S&P 500 Futures", exchange: "CME", type: "FUTURE"),
        "EMINI S&P 500": SearchResult(symbol: "ES=F", name: "E-mini S&P 500 Futures", exchange: "CME", type: "FUTURE"),
        "EMINI S&P 500 FUTURES": SearchResult(symbol: "ES=F", name: "E-mini S&P 500 Futures", exchange: "CME", type: "FUTURE"),
        "MES": SearchResult(symbol: "MES=F", name: "Micro E-mini S&P 500 Futures", exchange: "CME", type: "FUTURE"),
        "MES=F": SearchResult(symbol: "MES=F", name: "Micro E-mini S&P 500 Futures", exchange: "CME", type: "FUTURE"),
        "MICRO E-MINI S&P 500": SearchResult(symbol: "MES=F", name: "Micro E-mini S&P 500 Futures", exchange: "CME", type: "FUTURE"),
        "MICRO S&P 500": SearchResult(symbol: "MES=F", name: "Micro E-mini S&P 500 Futures", exchange: "CME", type: "FUTURE"),
        "NQ": SearchResult(symbol: "NQ=F", name: "E-mini NASDAQ-100 Futures", exchange: "CME", type: "FUTURE"),
        "NQ=F": SearchResult(symbol: "NQ=F", name: "E-mini NASDAQ-100 Futures", exchange: "CME", type: "FUTURE"),
        "NASDAQ FUTURES": SearchResult(symbol: "NQ=F", name: "E-mini NASDAQ-100 Futures", exchange: "CME", type: "FUTURE"),
        "E-MINI NASDAQ": SearchResult(symbol: "NQ=F", name: "E-mini NASDAQ-100 Futures", exchange: "CME", type: "FUTURE"),
        "MNQ": SearchResult(symbol: "MNQ=F", name: "Micro E-mini NASDAQ-100 Futures", exchange: "CME", type: "FUTURE"),
        "MNQ=F": SearchResult(symbol: "MNQ=F", name: "Micro E-mini NASDAQ-100 Futures", exchange: "CME", type: "FUTURE"),
        "YM": SearchResult(symbol: "YM=F", name: "Mini Dow Jones Futures", exchange: "CBOT", type: "FUTURE"),
        "YM=F": SearchResult(symbol: "YM=F", name: "Mini Dow Jones Futures", exchange: "CBOT", type: "FUTURE"),
        "DOW FUTURES": SearchResult(symbol: "YM=F", name: "Mini Dow Jones Futures", exchange: "CBOT", type: "FUTURE"),
        "MYM": SearchResult(symbol: "MYM=F", name: "Micro E-mini Dow Jones Futures", exchange: "CBOT", type: "FUTURE"),
        "MYM=F": SearchResult(symbol: "MYM=F", name: "Micro E-mini Dow Jones Futures", exchange: "CBOT", type: "FUTURE"),
        "RTY": SearchResult(symbol: "RTY=F", name: "E-mini Russell 2000 Futures", exchange: "CME", type: "FUTURE"),
        "RTY=F": SearchResult(symbol: "RTY=F", name: "E-mini Russell 2000 Futures", exchange: "CME", type: "FUTURE"),
        "RUSSELL": SearchResult(symbol: "RTY=F", name: "E-mini Russell 2000 Futures", exchange: "CME", type: "FUTURE"),
        "RUSSELL FUTURES": SearchResult(symbol: "RTY=F", name: "E-mini Russell 2000 Futures", exchange: "CME", type: "FUTURE"),
        "M2K": SearchResult(symbol: "M2K=F", name: "Micro E-mini Russell 2000 Futures", exchange: "CME", type: "FUTURE"),
        "M2K=F": SearchResult(symbol: "M2K=F", name: "Micro E-mini Russell 2000 Futures", exchange: "CME", type: "FUTURE"),
        // Commodities
        "GC": SearchResult(symbol: "GC=F", name: "Gold Futures", exchange: "NYMEX", type: "FUTURE"),
        "GC=F": SearchResult(symbol: "GC=F", name: "Gold Futures", exchange: "NYMEX", type: "FUTURE"),
        "XAUUSD": SearchResult(symbol: "GC=F", name: "Gold Futures", exchange: "NYMEX", type: "FUTURE"),
        "GOLD": SearchResult(symbol: "GC=F", name: "Gold Futures", exchange: "NYMEX", type: "FUTURE"),
        "SI": SearchResult(symbol: "SI=F", name: "Silver Futures", exchange: "NYMEX", type: "FUTURE"),
        "SI=F": SearchResult(symbol: "SI=F", name: "Silver Futures", exchange: "NYMEX", type: "FUTURE"),
        "XAGUSD": SearchResult(symbol: "SI=F", name: "Silver Futures", exchange: "NYMEX", type: "FUTURE"),
        "SILVER": SearchResult(symbol: "SI=F", name: "Silver Futures", exchange: "NYMEX", type: "FUTURE"),
        "CL": SearchResult(symbol: "CL=F", name: "Crude Oil WTI Futures", exchange: "NYMEX", type: "FUTURE"),
        "CL=F": SearchResult(symbol: "CL=F", name: "Crude Oil WTI Futures", exchange: "NYMEX", type: "FUTURE"),
        "OIL": SearchResult(symbol: "CL=F", name: "Crude Oil WTI Futures", exchange: "NYMEX", type: "FUTURE"),
        "WTI": SearchResult(symbol: "CL=F", name: "Crude Oil WTI Futures", exchange: "NYMEX", type: "FUTURE"),
        "CRUDE": SearchResult(symbol: "CL=F", name: "Crude Oil WTI Futures", exchange: "NYMEX", type: "FUTURE"),
        "BZ": SearchResult(symbol: "BZ=F", name: "Brent Crude Oil Futures", exchange: "ICE", type: "FUTURE"),
        "BZ=F": SearchResult(symbol: "BZ=F", name: "Brent Crude Oil Futures", exchange: "ICE", type: "FUTURE"),
        "BRENT": SearchResult(symbol: "BZ=F", name: "Brent Crude Oil Futures", exchange: "ICE", type: "FUTURE"),
        "HG": SearchResult(symbol: "HG=F", name: "Copper Futures", exchange: "NYMEX", type: "FUTURE"),
        "HG=F": SearchResult(symbol: "HG=F", name: "Copper Futures", exchange: "NYMEX", type: "FUTURE"),
        "COPPER": SearchResult(symbol: "HG=F", name: "Copper Futures", exchange: "NYMEX", type: "FUTURE"),
        "NG": SearchResult(symbol: "NG=F", name: "Natural Gas Futures", exchange: "NYMEX", type: "FUTURE"),
        "NG=F": SearchResult(symbol: "NG=F", name: "Natural Gas Futures", exchange: "NYMEX", type: "FUTURE"),
        "NATGAS": SearchResult(symbol: "NG=F", name: "Natural Gas Futures", exchange: "NYMEX", type: "FUTURE"),
        "GAS": SearchResult(symbol: "NG=F", name: "Natural Gas Futures", exchange: "NYMEX", type: "FUTURE")
    ]

    nonisolated static let popularVietnameseStocks: [SearchResult] = [
        SearchResult(symbol: "VND", name: "Công ty Cổ phần Chứng khoán VNDIRECT", exchange: "HOSE", type: "EQUITY"),
        SearchResult(symbol: "FPT", name: "Công ty Cổ phần FPT", exchange: "HOSE", type: "EQUITY"),
        SearchResult(symbol: "HPG", name: "Tập đoàn Hòa Phát", exchange: "HOSE", type: "EQUITY"),
        SearchResult(symbol: "VNM", name: "Công ty Cổ phần Sữa Việt Nam (Vinamilk)", exchange: "HOSE", type: "EQUITY"),
        SearchResult(symbol: "VIC", name: "Tập đoàn Vingroup", exchange: "HOSE", type: "EQUITY"),
        SearchResult(symbol: "VHM", name: "Công ty Cổ phần Vinhomes", exchange: "HOSE", type: "EQUITY"),
        SearchResult(symbol: "VRE", name: "Công ty Cổ phần Vincom Retail", exchange: "HOSE", type: "EQUITY"),
        SearchResult(symbol: "SSI", name: "Công ty Cổ phần Chứng khoán SSI", exchange: "HOSE", type: "EQUITY"),
        SearchResult(symbol: "VCI", name: "Công ty Cổ phần Chứng khoán Vietcap", exchange: "HOSE", type: "EQUITY"),
        SearchResult(symbol: "HCM", name: "Công ty Cổ phần Chứng khoán TP.HCM (HSC)", exchange: "HOSE", type: "EQUITY"),
        SearchResult(symbol: "TCB", name: "Ngân hàng Kỹ thương Việt Nam (Techcombank)", exchange: "HOSE", type: "EQUITY"),
        SearchResult(symbol: "MWG", name: "Công ty Cổ phần Đầu tư Thế Giới Di Động", exchange: "HOSE", type: "EQUITY"),
        SearchResult(symbol: "VCB", name: "Ngân hàng Ngoại thương Việt Nam (Vietcombank)", exchange: "HOSE", type: "EQUITY"),
        SearchResult(symbol: "MBB", name: "Ngân hàng Quân đội (MBBank)", exchange: "HOSE", type: "EQUITY"),
        SearchResult(symbol: "STB", name: "Ngân hàng Sài Gòn Thương Tín (Sacombank)", exchange: "HOSE", type: "EQUITY"),
        SearchResult(symbol: "ACB", name: "Ngân hàng Á Châu (ACB)", exchange: "HOSE", type: "EQUITY"),
        SearchResult(symbol: "BID", name: "Ngân hàng Đầu tư và Phát triển Việt Nam (BIDV)", exchange: "HOSE", type: "EQUITY"),
        SearchResult(symbol: "CTG", name: "Ngân hàng Công thương Việt Nam (VietinBank)", exchange: "HOSE", type: "EQUITY"),
        SearchResult(symbol: "HDB", name: "Ngân hàng Phát triển TP.HCM (HDBank)", exchange: "HOSE", type: "EQUITY"),
        SearchResult(symbol: "LPB", name: "Ngân hàng Lộc Phát Việt Nam (LPBank)", exchange: "HOSE", type: "EQUITY"),
        SearchResult(symbol: "SHB", name: "Ngân hàng Sài Gòn - Hà Nội (SHB)", exchange: "HOSE", type: "EQUITY"),
        SearchResult(symbol: "TPB", name: "Ngân hàng Tiên Phong (TPBank)", exchange: "HOSE", type: "EQUITY"),
        SearchResult(symbol: "VPB", name: "Ngân hàng Việt Nam Thịnh Vượng (VPBank)", exchange: "HOSE", type: "EQUITY"),
        SearchResult(symbol: "EIB", name: "Ngân hàng Xuất Nhập khẩu Việt Nam (Eximbank)", exchange: "HOSE", type: "EQUITY"),
        SearchResult(symbol: "MSN", name: "Tập đoàn Masan", exchange: "HOSE", type: "EQUITY"),
        SearchResult(symbol: "GAS", name: "Tổng Công ty Khí Việt Nam (PV GAS)", exchange: "HOSE", type: "EQUITY"),
        SearchResult(symbol: "PLX", name: "Tập đoàn Xăng dầu Việt Nam (Petrolimex)", exchange: "HOSE", type: "EQUITY"),
        SearchResult(symbol: "POW", name: "Tổng Công ty Điện lực Dầu khí Việt Nam (PV Power)", exchange: "HOSE", type: "EQUITY"),
        SearchResult(symbol: "PVD", name: "Tổng Công ty Cổ phần Khoan và Dịch vụ Khoan Dầu khí", exchange: "HOSE", type: "EQUITY"),
        SearchResult(symbol: "PVS", name: "Tổng Công ty Cổ phần Dịch vụ Kỹ thuật Dầu khí Việt Nam", exchange: "HNX", type: "EQUITY"),
        SearchResult(symbol: "SAB", name: "Tổng Công ty Cổ phần Bia - Rượu - Nước giải khát Sài Gòn", exchange: "HOSE", type: "EQUITY"),
        SearchResult(symbol: "VJC", name: "Công ty Cổ phần Hàng không Vietjet", exchange: "HOSE", type: "EQUITY"),
        SearchResult(symbol: "DGC", name: "Tập đoàn Hóa chất Đức Giang", exchange: "HOSE", type: "EQUITY"),
        SearchResult(symbol: "REE", name: "Công ty Cổ phần Cơ Điện Lạnh", exchange: "HOSE", type: "EQUITY"),
        SearchResult(symbol: "NVL", name: "Tập đoàn Đầu tư Địa ốc No Va (Novaland)", exchange: "HOSE", type: "EQUITY"),
        SearchResult(symbol: "PDR", name: "Bất động sản Phát Đạt", exchange: "HOSE", type: "EQUITY"),
        SearchResult(symbol: "DIG", name: "Tổng Công ty Cổ phần Đầu tư Phát triển Xây dựng (DIC Corp)", exchange: "HOSE", type: "EQUITY"),
        SearchResult(symbol: "DXG", name: "Tập đoàn Đất Xanh", exchange: "HOSE", type: "EQUITY"),
        SearchResult(symbol: "KBC", name: "Tổng Công ty Phát triển Đô thị Kinh Bắc", exchange: "HOSE", type: "EQUITY"),
        SearchResult(symbol: "GEX", name: "Tập đoàn GELEX", exchange: "HOSE", type: "EQUITY"),
        SearchResult(symbol: "VHC", name: "Công ty Cổ phần Vĩnh Hoàn", exchange: "HOSE", type: "EQUITY"),
        
        // HNX
        SearchResult(symbol: "SHS", name: "Công ty Cổ phần Chứng khoán Sài Gòn - Hà Nội", exchange: "HNX", type: "EQUITY"),
        SearchResult(symbol: "CEO", name: "Công ty Cổ phần Tập đoàn C.E.O", exchange: "HNX", type: "EQUITY"),
        SearchResult(symbol: "MBS", name: "Công ty Cổ phần Chứng khoán MB", exchange: "HNX", type: "EQUITY"),
        SearchResult(symbol: "IDC", name: "Tổng công ty IDICO - CTCP", exchange: "HNX", type: "EQUITY"),
        SearchResult(symbol: "VCS", name: "Công ty Cổ phần Vicostone", exchange: "HNX", type: "EQUITY"),
        SearchResult(symbol: "HUT", name: "Công ty Cổ phần Tasco", exchange: "HNX", type: "EQUITY"),
        
        // UPCOM
        SearchResult(symbol: "BSR", name: "Công ty Cổ phần Lọc hóa dầu Bình Sơn", exchange: "UPCOM", type: "EQUITY"),
        SearchResult(symbol: "VEA", name: "Tổng Công ty Máy động lực và Máy nông nghiệp Việt Nam", exchange: "UPCOM", type: "EQUITY"),
        SearchResult(symbol: "ACV", name: "Tổng công ty Cảng hàng không Việt Nam", exchange: "UPCOM", type: "EQUITY"),
        SearchResult(symbol: "QNS", name: "Công ty Cổ phần Đường Quảng Ngãi", exchange: "UPCOM", type: "EQUITY")
    ]

    // MARK: - Display names (indices, FX, futures)

    /// Maps Yahoo index tickers (e.g. "^GSPC") to their conventional display
    /// names (e.g. "S&P 500"). Built once from the popular index lists above.
    nonisolated static var indexDisplayNameMap: [String: String] {
        var map: [String: String] = [:]
        for index in popularJapaneseIndices + popularGlobalIndices {
            map[index.symbol.uppercased()] = index.name
        }
        return map
    }

    /// True when the symbol is a Yahoo market index ticker (prefix "^").
    nonisolated static func isIndexSymbol(_ symbol: String) -> Bool {
        symbol.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("^")
    }

    /// True when the symbol should use the "beautified" display-name path
    /// instead of the raw ticker: indices ("^N225"), FX pairs ("USDJPY=X"),
    /// and futures/commodities ("GC=F"). Single stocks, ETFs, funds, and
    /// crypto keep their raw ticker as the primary label.
    nonisolated static func isDisplayNameAsset(_ symbol: String) -> Bool {
        let upper = symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if isIndexSymbol(symbol) { return true }
        return upper.hasSuffix("=X") || upper.hasSuffix("=F")
    }

    /// Best-effort human-friendly display name for any symbol:
    /// - Index tickers ("^N225") → their conventional name ("Nikkei 225")
    /// - Unknown index tickers → the "^" prefix stripped ("^FOO" → "FOO")
    /// - FX pairs ("EURUSD=X") → "EUR/USD"
    /// - Futures & commodities ("GC=F") → the conventional name ("Gold Futures")
    /// - Everything else (stocks, ETFs, funds, crypto) → the raw symbol
    nonisolated static func beautifiedSymbol(_ symbol: String) -> String {
        let trimmed = symbol.trimmingCharacters(in: .whitespacesAndNewlines)
        let upper = trimmed.uppercased()

        // Market indices: preferred name, fallback strips the "^".
        if isIndexSymbol(trimmed) {
            if let name = indexDisplayNameMap[upper] { return name }
            return String(trimmed.dropFirst())
        }

        // FX pairs: "EURUSD=X" → "EUR/USD".
        if upper.hasSuffix("=X") {
            let base = String(upper.dropLast(2))
            if base.count == 6 {
                let from = String(base.prefix(3))
                let to = String(base.dropFirst(3))
                return "\(from)/\(to)"
            }
            return base
        }

        // Futures & commodities: look up the conventional name from the alias
        // table ("GC=F" → "Gold Futures"), fallback strips the "=F".
        if upper.hasSuffix("=F") {
            for (_, result) in popularIndexAliases
            where result.type.uppercased() == "FUTURE" && result.symbol.uppercased() == upper {
                return result.name
            }
            return String(upper.dropLast(2))
        }

        return symbol
    }

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
    func isVietnameseStock(_ symbol: String) -> Bool {
        let storedExchange = StorageService.shared.exchange(for: symbol)
        return Self.isVietnameseStock(symbol, exchange: storedExchange)
    }
    func isJapaneseStock(_ symbol: String) -> Bool { Self.isJapaneseStock(symbol) }
    func isJapaneseMutualFund(_ symbol: String) -> Bool { Self.isJapaneseMutualFund(symbol) }

    nonisolated static func isVietnameseStock(_ symbol: String, exchange: String = "") -> Bool {
        let upper = symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if upper.hasSuffix(".VN") || upper.hasSuffix(".HM") || upper.hasSuffix(".HN") {
            return true
        }
        let upperExchange = exchange.uppercased()
        if upperExchange == "HOSE" || upperExchange == "HNX" || upperExchange == "UPCOM" {
            return true
        }
        let clean = upper.replacingOccurrences(of: ".HM", with: "").replacingOccurrences(of: ".HN", with: "").replacingOccurrences(of: ".VN", with: "")
        return popularVietnameseStocks.contains(where: { $0.symbol.uppercased() == clean })
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
        let hasDigits = clean.rangeOfCharacter(from: .decimalDigits) != nil
        let toushinRegex = "^[0-9A-Z]{5,12}$"
        if hasDigits && clean.range(of: toushinRegex, options: .regularExpression) != nil {
            if !upper.hasSuffix(".T") && !upper.hasSuffix(".JP") {
                return true
            }
        }
        return false
    }

    nonisolated static func detectedCurrency(for symbol: String, quotes: [String: StockQuote] = [:]) -> String {
        if Self.isVietnameseStock(symbol) {
            return "VND"
        }
        if Self.isJapaneseMutualFund(symbol) || Self.isJapaneseStock(symbol) || Self.containsJapaneseCharacters(symbol) {
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
        "9C311125": "ひふみプラス",
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
        let targetCode = japaneseFundTargetCode(for: symbol)

        guard let url = URL(string: "https://finance.yahoo.co.jp/quote/\(targetCode)") else { return nil }

        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 200,
                  let html = String(data: data, encoding: .utf8) else { return nil }

            return Self.parseJapaneseFundQuote(html: html, symbol: symbol, targetCode: targetCode)
        } catch {
            return nil
        }
    }

    /// Parses the Yahoo Japan mutual fund quote page into a StockQuote.
    /// Handles both the modern Yahoo Finance Japan DOM structure (_BasePriceBoard with _StyledNumber__value)
    /// and the Next.js preloaded state script JSON stream.
    nonisolated static func parseJapaneseFundQuote(html: String, symbol: String, targetCode: String) -> StockQuote? {
        var price: Double = 0
        var change: Double = 0
        var percent: Double = 0

        func cleanNumber(_ str: String) -> Double? {
            let sanitized = str
                .replacingOccurrences(of: ",", with: "")
                .replacingOccurrences(of: "+", with: "")
                .replacingOccurrences(of: "−", with: "-") // Unicode minus U+2212
                .replacingOccurrences(of: "%", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return Double(sanitized)
        }

        let nsHtml = html as NSString
        let numPattern = "<span class=\"[^\"]*_StyledNumber__value[^\"]*\">([^<]+)</span>"

        // Strategy 1: DOM parsing inside <section class="..._BasePriceBoard...">
        if let numRegex = try? NSRegularExpression(pattern: numPattern) {
            var searchRange = NSRange(location: 0, length: html.utf16.count)
            let secPattern = "<section class=\"[^\"]*_BasePriceBoard[^\"]*\">(.*?)</section>"
            if let secRegex = try? NSRegularExpression(pattern: secPattern, options: [.dotMatchesLineSeparators]),
               let secMatch = secRegex.firstMatch(in: html, range: NSRange(location: 0, length: html.utf16.count)) {
                searchRange = secMatch.range
            }

            let matches = numRegex.matches(in: html, options: [], range: searchRange)
            if matches.count >= 3 {
                let pStr = nsHtml.substring(with: matches[0].range(at: 1))
                let cStr = nsHtml.substring(with: matches[1].range(at: 1))
                let pctStr = nsHtml.substring(with: matches[2].range(at: 1))
                if let p = cleanNumber(pStr), p > 0 {
                    price = p
                    change = cleanNumber(cStr) ?? 0
                    percent = cleanNumber(pctStr) ?? 0
                }
            }
        }

        // Strategy 2: Preloaded Next.js JSON stream in script tag
        // Matches "value":"19,952","changePrice":"389","changePriceRate":"1.99" (with or without escaping)
        if price <= 0 {
            let jsonPattern = "value[\\\\\"\\s:]+([0-9,]+)[\\\\\",\\s]+changePrice[\\\\\"\\s:]+([+−\\-]?[0-9,]+)[\\\\\",\\s]+changePriceRate[\\\\\"\\s:]+([+−\\-]?[0-9,.]+)"
            if let jRegex = try? NSRegularExpression(pattern: jsonPattern),
               let jMatch = jRegex.firstMatch(in: html, range: NSRange(location: 0, length: html.utf16.count)) {
                let pStr = nsHtml.substring(with: jMatch.range(at: 1))
                let cStr = nsHtml.substring(with: jMatch.range(at: 2))
                let pctStr = nsHtml.substring(with: jMatch.range(at: 3))
                if let p = cleanNumber(pStr), p > 0 {
                    price = p
                    change = cleanNumber(cStr) ?? 0
                    percent = cleanNumber(pctStr) ?? 0
                }
            }
        }

        // Strategy 3: Legacy flat JSON or fallback price pattern
        if price <= 0 {
            let legacyPattern = "\"price\":\"([0-9,]+)\""
            if let pRegex = try? NSRegularExpression(pattern: legacyPattern),
               let pMatch = pRegex.firstMatch(in: html, range: NSRange(location: 0, length: html.utf16.count)) {
                let pStr = nsHtml.substring(with: pMatch.range(at: 1))
                price = cleanNumber(pStr) ?? 0
            }
        }

        guard price > 0 else { return nil }

        // Determine name
        var name = Self.codeToFundNameMap[targetCode] ?? symbol
        if name == symbol || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let titlePattern = "<title>(.*?)【([0-9A-Za-z]+)】"
            if let tRegex = try? NSRegularExpression(pattern: titlePattern),
               let tMatch = tRegex.firstMatch(in: html, range: NSRange(location: 0, length: html.utf16.count)) {
                let rawName = nsHtml.substring(with: tMatch.range(at: 1))
                let cleaned = rawName
                    .replacingOccurrences(of: "&amp;", with: "&")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleaned.isEmpty {
                    name = cleaned
                }
            }
        }

        var tokyoCal = Calendar(identifier: .gregorian)
        tokyoCal.timeZone = TimeZone(identifier: "Asia/Tokyo") ?? .current
        let isWeekend = tokyoCal.isDateInWeekend(Date())
        let marketState = isWeekend ? "CLOSED" : "REGULAR"

        return StockQuote(
            symbol: symbol,
            name: name,
            price: price,
            change: change,
            changePercent: percent,
            regularMarketPreviousClose: price - change,
            currency: "JPY",
            marketState: marketState,
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
    }

    /// Fallback NAV when the Yahoo Japan quote page is unreachable (rate-limited
    /// or offline): reuse the last cached daily close. The history series stores
    /// the NAV per 10,000 口 un-scaled — exactly the unit the live quote uses —
    /// so this is a faithful last-known value, not a made-up number.
    private func japaneseFundFallbackQuote(symbol: String) -> StockQuote? {
        let series = priceHistory[symbol] ?? priceHistoryMax[symbol]
        guard let last = series?.last, last.close.isFinite, last.close > 0 else { return nil }
        let prev: Double = series?.dropLast().last?.close ?? last.close
        let change = prev.isFinite ? last.close - prev : 0
        let percent = (prev.isFinite && prev > 0) ? change / prev * 100 : 0
        let targetCode = japaneseFundTargetCode(for: symbol)
        var tokyoCal = Calendar(identifier: .gregorian)
        tokyoCal.timeZone = TimeZone(identifier: "Asia/Tokyo") ?? .current
        let isWeekend = tokyoCal.isDateInWeekend(Date())
        let marketState = isWeekend ? "CLOSED" : "REGULAR"

        return StockQuote(
            symbol: symbol,
            name: Self.codeToFundNameMap[targetCode] ?? symbol,
            price: last.close,
            change: change,
            changePercent: percent,
            regularMarketPreviousClose: prev.isFinite ? prev : last.close,
            currency: "JPY",
            marketState: marketState,
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
    }

    /// Resolves a Japanese mutual fund symbol (fund code or fund name) to the
    /// canonical fund code used on the Yahoo Japan quote pages.
    private func japaneseFundTargetCode(for symbol: String) -> String {
        let cleanCode = symbol.replacingOccurrences(of: ".JP", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if let foundCode = Self.codeToFundNameMap.first(where: {
            $0.key == cleanCode || $0.value.uppercased() == cleanCode ||
            $0.value.replacingOccurrences(of: " ", with: "").uppercased() == cleanCode.replacingOccurrences(of: " ", with: "").uppercased() ||
            (Self.containsJapaneseCharacters(cleanCode) && (cleanCode.contains($0.value) || $0.value.contains(cleanCode)))
        })?.key {
            return foundCode
        }
        return cleanCode
    }

    /// Number of paginated history pages to fetch. Each page holds ~20 trading
    /// days, so 20 pages comfortably covers the endpoint's full reach (~1 year
    /// of NAV for Japanese funds).
    private static let jpFundHistoryMaxPages = 20

    /// Attempts per history page before giving up; a transient network error
    /// must not silently truncate the series.
    private static let jpFundHistoryRetries = 3

    /// Fetches the daily NAV (基準価額) history for a Japanese mutual fund from
    /// the Yahoo Japan history pages. Each page holds ~20 trading days; the
    /// endpoint stops once every date is covered (funds expose roughly the last
    /// year). NAV is per 10,000 口 — the 10,000 scale is applied downstream
    /// exactly like the live quote, so it is stored here un-scaled. Best-effort:
    /// any failure returns an empty array (the caller keeps its existing data).
    /// Individual pages are retried so a flaky response can't truncate the
    /// series, and only a fetch that reached the true end is cached in memory.
    func fetchJapaneseFundHistory(symbol: String) async -> [PricePoint] {
        let targetCode = japaneseFundTargetCode(for: symbol)

        Self.jpFundHistoryLock.lock()
        if let cached = Self.jpFundHistoryCache[targetCode],
           Date().timeIntervalSince(cached.fetchedAt) < 21600 {
            let points = cached.points
            Self.jpFundHistoryLock.unlock()
            return points
        }
        Self.jpFundHistoryLock.unlock()

        var collected: [PricePoint] = []
        var sawPartial = false
        var reachedEnd = false
        for page in 1...Self.jpFundHistoryMaxPages {
            let points = await fetchJapaneseFundHistoryPage(targetCode: targetCode, page: page)
            if points.isEmpty {
                // An empty page only counts as the true end once a partial page
                // was seen or a substantial series was already collected. An
                // empty page after full pages is usually a transient failure
                // (throttling), not the end — never truncate the cache.
                if sawPartial || collected.count >= 200 {
                    reachedEnd = true
                }
                break
            }
            collected.append(contentsOf: points)
            if points.count < 20 {
                sawPartial = true
                reachedEnd = true
                break  // final, partial page
            }
        }
        if collected.isEmpty || !reachedEnd { return [] }

        // De-duplicate by day (pages never overlap, but stay safe) and sort ascending.
        let byDay = Dictionary(grouping: collected, by: { Calendar.current.startOfDay(for: $0.date) })
        let unique = byDay.values.compactMap(\.first).sorted { $0.date < $1.date }

        // Only a fetch that reached the true end is cached, so a partial result
        // is re-fetched on the next access instead of being locked in for 6h.
        if reachedEnd {
            Self.jpFundHistoryLock.lock()
            Self.jpFundHistoryCache[targetCode] = (unique, Date())
            Self.jpFundHistoryLock.unlock()
        }
        return unique
    }

    /// Fetches one paginated history page with a few retries; empty on failure.
    private func fetchJapaneseFundHistoryPage(targetCode: String, page: Int) async -> [PricePoint] {
        for attempt in 0..<Self.jpFundHistoryRetries {
            guard let url = URL(string: "https://finance.yahoo.co.jp/quote/\(targetCode)/history?page=\(page)") else { return [] }

            var request = URLRequest(url: url)
            request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)", forHTTPHeaderField: "User-Agent")

            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                      let html = String(data: data, encoding: .utf8) else { continue }
                let points = Self.parseJapaneseFundHistory(html: html)
                if !points.isEmpty { return points }
            } catch {
                // fall through to the retry backoff
            }
            if attempt < Self.jpFundHistoryRetries - 1 {
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
        }
        return []
    }

    /// Parses the Yahoo Japan fund history table (`/quote/<code>/history`) into
    /// daily NAV points. Each row carries a date in the `<th scope="row">`
    /// header followed by the 基準価額 as the first numeric cell; that value is
    /// the NAV per 10,000 口, stored un-scaled.
    nonisolated static func parseJapaneseFundHistory(html: String) -> [PricePoint] {
        let rowPattern = "<tr class=\"[^\"]*_Table__row[^\"]*\">(.*?)</tr>"
        let datePattern = "<th scope=\"row\"[^>]*>([0-9]{4}/[0-9]{1,2}/[0-9]{1,2})</th>"
        let numberPattern = "<span class=\"[^\"]*_StyledNumber__value[^\"]*\">([0-9,]+)</span>"

        guard let rowRegex = try? NSRegularExpression(pattern: rowPattern, options: [.dotMatchesLineSeparators]),
              let dateRegex = try? NSRegularExpression(pattern: datePattern),
              let numRegex = try? NSRegularExpression(pattern: numberPattern) else { return [] }

        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.calendar = Calendar(identifier: .gregorian)
        dateFormatter.dateFormat = "yyyy/M/d"

        var points: [PricePoint] = []
        let ns = html as NSString
        for rowMatch in rowRegex.matches(in: html, options: [], range: NSRange(location: 0, length: html.utf16.count)) {
            let row = ns.substring(with: rowMatch.range(at: 1)) as NSString
            guard let dMatch = dateRegex.firstMatch(in: row as String, options: [], range: NSRange(location: 0, length: row.length)),
                  let date = dateFormatter.date(from: row.substring(with: dMatch.range(at: 1))),
                  let nMatch = numRegex.firstMatch(in: row as String, options: [], range: NSRange(location: 0, length: row.length)),
                  let nav = Double(row.substring(with: nMatch.range(at: 1)).replacingOccurrences(of: ",", with: "")),
                  nav > 0 else { continue }
            points.append(PricePoint(date: Calendar.current.startOfDay(for: date), close: nav))
        }
        return points.sorted { $0.date < $1.date }
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

    /// Fetches Binance exchangeInfo (all Spot and Futures trading pairs) and caches for 6 hours.
    /// Response is ~2MB so we call once and filter client-side on every search.
    private func fetchBinanceExchangeInfo() async -> [BinanceSymbolInfo] {
        if let cached = cachedBinanceSymbols, let at = binanceSymbolsFetchedAt,
           Date().timeIntervalSince(at) < 21600 {
            return cached
        }
        
        async let spotTask: [BinanceSymbolInfo] = {
            guard let url = URL(string: "https://api.binance.com/api/v3/exchangeInfo"),
                  let (data, resp) = try? await session.data(from: url),
                  let http = resp as? HTTPURLResponse, http.statusCode == 200,
                  let response = try? JSONDecoder().decode(BinanceExchangeInfoResponse.self, from: data) else {
                return []
            }
            return response.symbols.filter { $0.status == "TRADING" }
        }()

        async let futuresTask: [BinanceSymbolInfo] = {
            guard let url = URL(string: "https://fapi.binance.com/fapi/v1/exchangeInfo"),
                  let (data, resp) = try? await session.data(from: url),
                  let http = resp as? HTTPURLResponse, http.statusCode == 200,
                  let response = try? JSONDecoder().decode(BinanceExchangeInfoResponse.self, from: data) else {
                return []
            }
            return response.symbols.filter { $0.status == "TRADING" }
        }()

        let (spotSymbols, futuresSymbols) = await (spotTask, futuresTask)
        var combined: [String: BinanceSymbolInfo] = [:]
        for s in spotSymbols {
            combined[s.symbol.uppercased()] = s
        }
        for f in futuresSymbols {
            if combined[f.symbol.uppercased()] == nil {
                combined[f.symbol.uppercased()] = f
            }
        }

        let active = Array(combined.values)
        if !active.isEmpty {
            cachedBinanceSymbols = active
            binanceSymbolsFetchedAt = Date()
            return active
        }
        return cachedBinanceSymbols ?? []
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

        for stock in Self.popularVietnameseStocks {
            if stock.symbol.contains(upperQuery) || stock.name.localizedCaseInsensitiveContains(cleanQuery) {
                fundResults.append(stock)
            }
        }

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

        for index in Self.popularGlobalIndices {
            if index.symbol.contains(upperQuery) || index.name.localizedCaseInsensitiveContains(cleanQuery) {
                fundResults.append(index)
            }
        }

        // Exact alias match (SPX, ES, XAUUSD, GOLD, ...) or matching name before hitting Yahoo
        if let aliasResult = Self.popularIndexAliases[upperQuery] {
            if !fundResults.contains(where: { $0.symbol == aliasResult.symbol }) {
                fundResults.append(aliasResult)
            }
        }
        for (_, alias) in Self.popularIndexAliases {
            if alias.name.localizedCaseInsensitiveContains(cleanQuery) || alias.symbol.uppercased() == upperQuery {
                if !fundResults.contains(where: { $0.symbol == alias.symbol }) {
                    fundResults.append(alias)
                }
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

        // Run VNDirect, Yahoo and Binance search in parallel
        async let vnTask = fetchVNDirectSearch(query: cleanQuery)
        async let yahooTask = fetchYahooSearch(query: query)
        async let binanceTask = fetchBinanceSearch(query: upperQuery)

        let (vnResults, yahooResults, binanceResults) = await (vnTask, yahooTask, binanceTask)

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

        var existingSymbols = Set(fundResults.map { $0.symbol.uppercased() })
        var vnFinal: [SearchResult] = []
        for r in vnResults {
            let sym = r.symbol.uppercased()
            if !existingSymbols.contains(sym) {
                existingSymbols.insert(sym)
                vnFinal.append(r)
            }
        }

        let uniqueFinal = final.filter { !existingSymbols.contains($0.symbol.uppercased()) }
        return fundResults + vnFinal + uniqueFinal
    }

    private func fetchVNDirectSearch(query: String) async -> [SearchResult] {
        let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return [] }
        let encoded = clean.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? clean
        guard let url = URL(string: "\(VNMarketConfig.searchBaseURL)?query=\(encoded)&limit=15") else {
            return []
        }
        do {
            let (data, _) = try await session.data(from: url)
            let items = try JSONDecoder().decode([VNDirectSearchItem].self, from: data)
            return items.compactMap { item in
                let sym = item.symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                guard !sym.isEmpty else { return nil }
                let desc = item.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let rawExchange = (item.exchange?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").uppercased()
                let exchange = rawExchange.isEmpty ? "HNX" : rawExchange
                let rawType = (item.type?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").uppercased()
                let type = (rawType == "CHỈ SỐ" || rawType == "INDEX") ? "INDEX" : "EQUITY"
                let name = Self.popularVietnameseStocks.first(where: { $0.symbol.uppercased() == sym })?.name
                    ?? (!desc.isEmpty ? desc : sym)
                return SearchResult(
                    symbol: sym,
                    name: name,
                    exchange: exchange,
                    type: type
                )
            }
        } catch {
            return []
        }
    }

    private func fetchYahooSearch(query: String) async -> [SearchResult] {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        guard let url = URL(string: "https://query2.finance.yahoo.com/v1/finance/search?q=\(encoded)&quotesCount=10&newsCount=0&enableFuzzyQuery=true&enableCb=true") else {
            return []
        }
        do {
            let (data, _) = try await session.data(from: url)
            let response = try JSONDecoder().decode(YahooSearchResponse.self, from: data)
            // Decode is now defensive; drop rows that had no symbol.
            return response.quotes.filter { !$0.symbol.isEmpty }
        } catch {
            return []
        }
    }

    // MARK: - Finance News (Home tab)

    /// Refresh the Home news feed. Pulls stories related to the user's tracked
    /// symbols (or general market news when nothing is tracked) from Google
    /// News' public RSS search feed — no API key required.
    /// Throttled to at most once every 5 minutes unless `force` is set.
    func refreshNews(storageService: StorageService, force: Bool = false) async {
        if !force, !news.isEmpty, let last = lastNewsFetch,
           Date().timeIntervalSince(last) < 300 {
            return
        }
        isLoadingNews = true
        defer { isLoadingNews = false }

        let symbols = Self.collectSymbols(storageService: storageService).sorted()
        var seen = Set<String>()
        var collected: [NewsArticle] = []
        await withTaskGroup(of: [NewsArticle].self) { group in
            if symbols.isEmpty {
                let lang = storageService.appLanguage.lowercased()
                if lang == "vi" {
                    group.addTask { [weak self] in
                        await self?.fetchYahooNews(symbol: "^VNINDEX.VN") ?? []
                    }
                    group.addTask { [weak self] in
                        await self?.fetchNewsChunk(
                            query: "thị trường chứng khoán OR kinh doanh tài chính",
                            sourceSymbol: nil,
                            language: "vi",
                            region: "VN",
                            ceid: "VN:vi"
                        ) ?? []
                    }
                } else if lang == "ja" {
                    group.addTask { [weak self] in
                        await self?.fetchYahooNews(symbol: "^N225") ?? []
                    }
                    group.addTask { [weak self] in
                        await self?.fetchNewsChunk(
                            query: "株式市場 OR 日経平均",
                            sourceSymbol: nil,
                            language: "ja",
                            region: "JP",
                            ceid: "JP:ja"
                        ) ?? []
                    }
                } else {
                    group.addTask { [weak self] in
                        await self?.fetchYahooNews(symbol: "^GSPC") ?? []
                    }
                    group.addTask { [weak self] in
                        await self?.fetchNewsChunk(query: "stock market", sourceSymbol: nil) ?? []
                    }
                }
            } else {
                for symbol in symbols.prefix(6) {
                    let name = self.quotes[symbol]?.name ?? self.quotes[symbol.uppercased()]?.name
                    let params = Self.smartNewsParameters(symbol: symbol, displayName: name)
                    group.addTask { [weak self] in
                        guard let self else { return [] }
                        let direct = await self.fetchYahooNews(symbol: symbol)
                        if !direct.isEmpty { return direct }
                        return await self.fetchNewsChunk(
                            query: params.query,
                            sourceSymbol: symbol,
                            language: params.language,
                            region: params.region,
                            ceid: params.ceid
                        )
                    }
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

    func fetchNewsChunk(
        query: String,
        sourceSymbol: String?,
        language: String = "en-US",
        region: String = "US",
        ceid: String = "US:en"
    ) async -> [NewsArticle] {
        // Google News RSS search feed: symbol-aware, publisher-diverse, localized.
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        guard let url = URL(string: "https://news.google.com/rss/search?q=\(encoded)&hl=\(language)&gl=\(region)&ceid=\(ceid)") else { return [] }
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return [] }
            let articles: [NewsArticle]
            if let sourceSymbol {
                articles = GoogleNewsRSSParser.parse(data, sourceSymbol: sourceSymbol)
            } else {
                articles = GoogleNewsRSSParser.parse(data)
            }
            return articles
        } catch {
            return []
        }
    }

    /// Generates the most accurate search query and localization parameters for a financial asset.
    nonisolated static func smartNewsParameters(
        symbol: String,
        displayName: String? = nil,
        marketCategory: MarketCategory? = nil
    ) -> (query: String, language: String, region: String, ceid: String) {
        let upper = symbol.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedCategory = marketCategory ?? HomeAIInsightService.detectMarketCategory(symbol: upper, isCrypto: false)

        let cleanName = (displayName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let hasName = !cleanName.isEmpty && cleanName.uppercased() != upper

        switch resolvedCategory {
        case .vietnam:
            let cleanTicker = upper.replacingOccurrences(of: ".VN", with: "").replacingOccurrences(of: "^", with: "")
            let q: String
            if hasName {
                q = "(\"\(cleanTicker)\" OR \"\(cleanName)\") (cổ phiếu OR \"kết quả kinh doanh\" OR \"doanh thu\" OR \"lợi nhuận\" OR \"tài chính\")"
            } else {
                q = "\"\(cleanTicker)\" (cổ phiếu OR \"kết quả kinh doanh\" OR \"doanh thu\" OR \"lợi nhuận\")"
            }
            return (query: q, language: "vi", region: "VN", ceid: "VN:vi")

        case .japan:
            let cleanTicker = upper.replacingOccurrences(of: ".T", with: "").replacingOccurrences(of: ".JP", with: "")
            let q: String
            if hasName {
                q = "(\"\(cleanName)\" OR \"\(cleanTicker)\") (株価 OR 決算 OR 業績 OR 適時開示)"
            } else {
                q = "\"\(cleanTicker)\" (株価 OR 決算 OR 業績)"
            }
            return (query: q, language: "ja", region: "JP", ceid: "JP:ja")

        case .crypto:
            let base = HomeAIInsightService.cryptoBaseAsset(for: upper) ?? upper
            let cleanBaseName: String = {
                switch base.uppercased() {
                case "BTC": return "Bitcoin"
                case "ETH": return "Ethereum"
                case "SOL": return "Solana"
                case "SUI": return "Sui"
                case "DOGE": return "Dogecoin"
                case "BNB": return "BNB"
                case "XRP": return "Ripple"
                case "ADA": return "Cardano"
                default:
                    let raw = cleanName.isEmpty ? base : cleanName
                    if let firstParen = raw.firstIndex(of: "(") {
                        return String(raw[..<firstParen]).trimmingCharacters(in: .whitespaces)
                    }
                    return raw
                }
            }()
            let q = "(\"\(base)\" OR \"\(cleanBaseName)\") (crypto OR Bitcoin OR rally OR crash OR dump OR \"Clarity Act\" OR regulation OR bill OR ETF OR SEC OR Fed)"
            return (query: q, language: "en-US", region: "US", ceid: "US:en")

        case .us:
            let cleanTicker = upper.replacingOccurrences(of: ".US", with: "")

            // Crypto Proxy Stocks (MSTR, BMNR, COIN, MARA, RIOT, etc.)
            if HomeAIInsightService.isCryptoProxy(symbol: cleanTicker) {
                let namePrefix = cleanName.components(separatedBy: " ").prefix(2).joined(separator: " ")
                let q = "(\"\(cleanTicker)\" OR \"\(namePrefix.isEmpty ? cleanTicker : namePrefix)\") (Bitcoin OR BTC OR crypto OR stock OR shares OR earnings)"
                return (query: q, language: "en-US", region: "US", ceid: "US:en")
            }

            let q: String
            if hasName {
                let simplifiedName = cleanName
                    .replacingOccurrences(of: " Holdings, Inc.", with: "", options: .caseInsensitive)
                    .replacingOccurrences(of: " Holdings Inc.", with: "", options: .caseInsensitive)
                    .replacingOccurrences(of: " Holding Inc.", with: "", options: .caseInsensitive)
                    .replacingOccurrences(of: " Inc.", with: "", options: .caseInsensitive)
                    .replacingOccurrences(of: " Inc", with: "", options: .caseInsensitive)
                    .replacingOccurrences(of: " Corp.", with: "", options: .caseInsensitive)
                    .replacingOccurrences(of: " Corp", with: "", options: .caseInsensitive)
                    .replacingOccurrences(of: " Corporation", with: "", options: .caseInsensitive)
                    .replacingOccurrences(of: " Ltd.", with: "", options: .caseInsensitive)
                    .replacingOccurrences(of: " Co.", with: "", options: .caseInsensitive)
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                let words = simplifiedName.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                let shortName = words.prefix(3).joined(separator: " ")
                q = "(\"\(cleanTicker)\" OR \"\(shortName)\") (stock OR earnings OR revenue OR guidance OR shares OR upgrade OR downgrade OR analysis)"
            } else {
                q = "\"\(cleanTicker)\" (stock OR shares OR earnings OR revenue OR guidance)"
            }
            return (query: q, language: "en-US", region: "US", ceid: "US:en")
        }
    }

    private func fetchYahooNews(symbol: String) async -> [NewsArticle] {
        let cleanSymbol = symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !cleanSymbol.isEmpty, !cleanSymbol.hasSuffix(".VN") else { return [] }
        guard let url = URL(string: "https://feeds.finance.yahoo.com/rss/2.0/headline?s=\(cleanSymbol)&region=US&lang=en-US") else { return [] }
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return [] }
            let articles = GoogleNewsRSSParser.parse(data, sourceSymbol: cleanSymbol)
            return articles.filter { !$0.title.isEmpty && !$0.link.isEmpty }
        } catch {
            return []
        }
    }

    /// Refresh news for a single symbol (used by the symbol detail page and AI insights).
    /// Fetches concurrently from direct Yahoo Finance RSS and targeted Google News RSS,
    /// scores by relevance to ensure company catalysts take priority over syndicated macro articles,
    /// throttled to at most once every 5 minutes per symbol, and stores the result in `newsBySymbol`.
    func refreshNews(
        for symbol: String,
        displayName: String? = nil,
        marketCategory: MarketCategory? = nil
    ) async {
        let key = symbol.uppercased()
        if let existing = newsBySymbol[key], !existing.isEmpty,
           let last = lastSymbolNewsFetch[key],
           Date().timeIntervalSince(last) < 300 {
            return
        }
        if isLoadingSymbolNews.contains(key) { return }
        isLoadingSymbolNews.insert(key)
        defer { isLoadingSymbolNews.remove(key) }

        let name = displayName ?? quotes[key]?.displayName ?? quotes[symbol]?.name
        let params = Self.smartNewsParameters(symbol: symbol, displayName: name, marketCategory: marketCategory)

        // Run both Yahoo RSS and targeted Google News RSS concurrently
        async let yahooTask = fetchYahooNews(symbol: key)
        async let googleTask = fetchNewsChunk(
            query: params.query,
            sourceSymbol: key,
            language: params.language,
            region: params.region,
            ceid: params.ceid
        )

        let yahooArticles = await yahooTask
        let googleArticles = await googleTask
        let allArticles = yahooArticles + googleArticles

        // Calculate relevance score:
        // Priority 1: Title explicitly mentions cleanTicker or cleanName -> Score +100
        // Priority 2: Snippet explicitly mentions cleanTicker or cleanName -> Score +40
        // Priority 3: Contains catalyst keywords -> Score +20
        let cleanTicker = key.replacingOccurrences(of: ".VN", with: "").replacingOccurrences(of: ".T", with: "").replacingOccurrences(of: ".US", with: "").replacingOccurrences(of: "^", with: "")
        let cleanNameUpper = (name ?? "").uppercased()

        func score(article: NewsArticle) -> Int {
            var s = 0
            let titleUp = article.title.uppercased()
            let contentUp = article.content.uppercased()

            if titleUp.contains(cleanTicker) { s += 100 }
            if !cleanNameUpper.isEmpty && cleanNameUpper != cleanTicker && titleUp.contains(cleanNameUpper) { s += 100 }
            else if !cleanNameUpper.isEmpty {
                let firstWord = cleanNameUpper.components(separatedBy: .whitespaces).first ?? ""
                if firstWord.count >= 4 && titleUp.contains(firstWord) { s += 80 }
            }

            if contentUp.contains(cleanTicker) { s += 40 }
            if !cleanNameUpper.isEmpty && contentUp.contains(cleanNameUpper) { s += 40 }

            for kw in ["EARNINGS", "REVENUE", "GUIDANCE", "TARGET", "UPGRADE", "DOWNGRADE", "PROFIT", "ARR", "QUARTER", "ACQUISITION", "SURGE", "PLUNGE", "KQKD", "DOANH THU", "LỢI NHUẬN", "QUÝ", "TĂNG TRƯỞNG", "決算", "業績"] {
                if titleUp.contains(kw) || contentUp.contains(kw) {
                    s += 20
                    break
                }
            }
            return s
        }

        var scored = allArticles.map { (article: $0, score: score(article: $0)) }
        // Sort by relevance score descending, then by publishTime descending
        scored.sort { a, b in
            if a.score != b.score {
                return a.score > b.score
            }
            return a.article.publishTime > b.article.publishTime
        }

        var seen = Set<String>()
        var deduped: [NewsArticle] = []
        for item in scored {
            let a = item.article
            let keyId = a.title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            if !a.title.isEmpty && !seen.contains(keyId) && !seen.contains(a.id) {
                seen.insert(keyId)
                seen.insert(a.id)
                deduped.append(a)
            }
        }

        newsBySymbol[key] = Array(deduped.prefix(10))
        lastSymbolNewsFetch[key] = Date()
    }

    // MARK: - Fear & Greed Index

    /// Fetch Fear & Greed data for both Stock (CNN) and Crypto (Alternative.me).
    /// Cached for 1 calendar day — will not re-fetch within the same day unless `force` is true.
    func fetchFearGreedIndex(force: Bool = false) async {
        if !force, let fetched = fearGreedFetchedAt, Calendar.current.isDateInToday(fetched) {
            return
        }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.fetchCNNFearGreed() }
            group.addTask { await self.fetchCryptoFearGreed() }
        }
        fearGreedFetchedAt = Date()
    }

    /// CNN Fear & Greed Index for US stocks.
    private func fetchCNNFearGreed() async {
        guard let url = URL(string: "https://production.dataviz.cnn.io/index/fearandgreed/graphdata") else { return }
        do {
            var request = URLRequest(url: url)
            request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)", forHTTPHeaderField: "User-Agent")
            let (data, _) = try await session.data(for: request)
            // CNN response shape: { "fear_and_greed": { "score": 72.5, "rating": "greed", "previous_close": 68.2, ... },
            //                        "fear_and_greed_historical": { ... } }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let fg = json["fear_and_greed"] as? [String: Any],
                  let score = fg["score"] as? Double else { return }

            let previousClose = fg["previous_close"] as? Double
            let weekAgo = (fg["previous_1_week"] as? Double)
            let monthAgo = (fg["previous_1_month"] as? Double)
            let rating = fg["rating"] as? String ?? FearGreedData.label(for: Int(score))

            stockFearGreed = FearGreedData(
                score: Int(score.rounded()),
                label: rating.capitalized,
                previousClose: previousClose.map { Int($0.rounded()) },
                weekAgo: weekAgo.map { Int($0.rounded()) },
                monthAgo: monthAgo.map { Int($0.rounded()) },
                fetchedAt: Date()
            )
        } catch {
            print("[FearGreed] CNN fetch error: \(error.localizedDescription)")
        }
    }

    /// Alternative.me Fear & Greed Index for Crypto.
    private func fetchCryptoFearGreed() async {
        guard let url = URL(string: "https://api.alternative.me/fng/?limit=31&format=json&date_format=world") else { return }
        do {
            let (data, _) = try await session.data(for: URLRequest(url: url))
            // Response: { "data": [ { "value": "65", "value_classification": "Greed", "timestamp": "..." }, ... ] }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let entries = json["data"] as? [[String: Any]],
                  let first = entries.first,
                  let valueStr = first["value"] as? String,
                  let score = Int(valueStr) else { return }

            let label = first["value_classification"] as? String ?? FearGreedData.label(for: score)
            let previousClose = entries.count > 1 ? Int(entries[1]["value"] as? String ?? "") : nil
            let weekAgo = entries.count >= 7 ? Int(entries[6]["value"] as? String ?? "") : nil
            let monthAgo = entries.count >= 30 ? Int(entries[29]["value"] as? String ?? "") : nil

            cryptoFearGreed = FearGreedData(
                score: score,
                label: label,
                previousClose: previousClose,
                weekAgo: weekAgo,
                monthAgo: monthAgo,
                fetchedAt: Date()
            )
        } catch {
            print("[FearGreed] Crypto fetch error: \(error.localizedDescription)")
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
                histories[key] = points
                histories[key.uppercased()] = points
                histories[symbol] = points
                histories[symbol.uppercased()] = points
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
        let regularMarketTime: Int?
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

private struct VNDirectHistoryResponse: Decodable {
    let t: [Int64]?
    let c: [Double]?
    let o: [Double]?
    let h: [Double]?
    let l: [Double]?
    let v: [Double]?
    let s: String?
}

private struct VNDirectSearchItem: Decodable {
    let symbol: String
    let description: String?
    let exchange: String?
    let type: String?
}
