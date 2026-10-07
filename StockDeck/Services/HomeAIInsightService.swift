import Foundation

@MainActor
final class HomeAIInsightService {
    static let shared = HomeAIInsightService()

    private let aiService = AIReviewService.shared

    private init() {}

    struct SymbolCandidate {
        let symbol: String
        let name: String
        let price: Double
        let changePercent: Double
        let currency: String
        let isCrypto: Bool
        let marketCategory: MarketCategory
        let originalSymbol: String

        init(
            symbol: String,
            name: String,
            price: Double,
            changePercent: Double,
            currency: String,
            isCrypto: Bool = false,
            marketCategory: MarketCategory = .us,
            originalSymbol: String? = nil
        ) {
            self.symbol = symbol
            self.name = name
            self.price = price
            self.changePercent = changePercent
            self.currency = currency
            self.isCrypto = isCrypto
            self.marketCategory = marketCategory
            self.originalSymbol = originalSymbol ?? symbol
        }
    }

    /// Determines if a symbol is a crypto pair and returns its base asset (e.g. BTC, ETH, SOL, SUI, DOGE).
    nonisolated static func cryptoBaseAsset(for symbol: String) -> String? {
        let upper = symbol.uppercased()
        if upper.hasPrefix("BTC-") || upper == "BTCUSD" || upper == "BTCUSDT" || upper == "BTCETH" || upper == "BTC-USD" {
            return "BTC"
        }
        if upper.hasPrefix("ETH-") || upper == "ETHUSD" || upper == "ETHUSDT" || upper == "ETHUSDC" || upper == "ETH-USD" {
            return "ETH"
        }
        if upper.hasPrefix("SOL-") || upper == "SOLUSD" || upper == "SOLUSDT" || upper == "SOLUSDC" || upper == "SOL-USD" {
            return "SOL"
        }
        if upper.hasPrefix("SUI-") || upper == "SUIUSD" || upper == "SUIUSDT" || upper == "SUI-USD" {
            return "SUI"
        }
        if upper.hasPrefix("DOGE-") || upper == "DOGEUSD" || upper == "DOGEUSDT" || upper == "DOGE-USD" {
            return "DOGE"
        }
        if upper.hasPrefix("BNB-") || upper == "BNBUSD" || upper == "BNBUSDT" || upper == "BNB-USD" {
            return "BNB"
        }
        if upper.hasPrefix("XRP-") || upper == "XRPUSD" || upper == "XRPUSDT" || upper == "XRP-USD" {
            return "XRP"
        }
        if upper.hasPrefix("ADA-") || upper == "ADAUSD" || upper == "ADAUSDT" || upper == "ADA-USD" {
            return "ADA"
        }
        if upper.hasSuffix("-USD") {
            let parts = upper.components(separatedBy: "-")
            if parts.count == 2 && !parts[0].isEmpty {
                return parts[0]
            }
        }
        for suffix in ["USDT", "USDC", "BUSD", "FDUSD"] {
            if upper.hasSuffix(suffix) && upper.count > suffix.count {
                return String(upper.dropLast(suffix.count))
            }
        }
        return nil
    }

    /// User-friendly name for crypto base assets.
    nonisolated static func cryptoDisplayName(for baseAsset: String, fallback: String) -> String {
        switch baseAsset.uppercased() {
        case "BTC": return "Bitcoin (BTC)"
        case "ETH": return "Ethereum (ETH)"
        case "SOL": return "Solana (SOL)"
        case "SUI": return "Sui (SUI)"
        case "DOGE": return "Dogecoin (DOGE)"
        case "BNB": return "BNB"
        case "XRP": return "XRP"
        case "ADA": return "Cardano (ADA)"
        default: return fallback.isEmpty ? baseAsset : fallback
        }
    }

    /// Determines the market category (US, JP, VN, CRYPTO) for a symbol.
    nonisolated static func detectMarketCategory(symbol: String, isCrypto: Bool = false) -> MarketCategory {
        if isCrypto || cryptoBaseAsset(for: symbol) != nil {
            return .crypto
        }
        let upper = symbol.uppercased()
        if StockService.isVietnameseStock(upper) || upper.hasSuffix(".VN") || upper == "^VNINDEX.VN" {
            return .vietnam
        }
        if StockService.isJapaneseStock(upper) || StockService.isJapaneseMutualFund(upper) || upper.hasSuffix(".T") || upper == "^N225" {
            return .japan
        }
        return .us
    }

    /// Determines if a US stock is a Bitcoin/crypto proxy asset (e.g. MSTR, BMNR, COIN, MARA, RIOT).
    nonisolated static func isCryptoProxy(symbol: String) -> Bool {
        let upper = symbol.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let clean = upper.replacingOccurrences(of: ".US", with: "")
        let proxies: Set<String> = [
            "MSTR", "BMNR", "MARA", "RIOT", "CLSK", "COIN", "CIFR", "HUT",
            "CORZ", "WULF", "IREN", "BTDR", "BITF", "HIVE", "CAN", "ARBK",
            "GLXY", "MSTU", "MSTX", "CONL"
        ]
        return proxies.contains(clean)
    }

    struct MultiDayTrend {
        let yesterdayChange: Double?
        let threeDayChange: Double?
        let sevenDayChange: Double?
    }

    /// Computes historical price trends (yesterday, 3-day, 7-day) from cached price history.
    static func computeMultiDayTrend(
        for symbol: String,
        currentPrice: Double,
        priceHistory: [String: [PricePoint]]
    ) -> MultiDayTrend {
        let clean = symbol.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let points = priceHistory[clean] ?? priceHistory[symbol] ?? []
        guard points.count >= 2 else {
            return MultiDayTrend(yesterdayChange: nil, threeDayChange: nil, sevenDayChange: nil)
        }

        let n = points.count
        let lastClosed = points[n - 1].close
        let prevClosed = points[n - 2].close

        let yesterdayChange: Double? = prevClosed > 0 ? ((lastClosed - prevClosed) / prevClosed * 100) : nil

        var threeDay: Double? = nil
        if n >= 4, points[n - 3].close > 0 {
            threeDay = (currentPrice - points[n - 3].close) / points[n - 3].close * 100
        }

        var sevenDay: Double? = nil
        if n >= 8, points[n - 7].close > 0 {
            sevenDay = (currentPrice - points[n - 7].close) / points[n - 7].close * 100
        }

        return MultiDayTrend(yesterdayChange: yesterdayChange, threeDayChange: threeDay, sevenDayChange: sevenDay)
    }

    /// Generates daily AI insights for the user's top mover symbols in portfolio/watchlist.
    /// Returns the insight on success and automatically caches it in `StorageService`.
    func generateDailyInsight(
        storageService: StorageService,
        stockService: StockService,
        force: Bool = false
    ) async throws -> HomeAIInsight {
        guard storageService.hasAIConfiguration else {
            throw AIReviewError.noConfiguration
        }

        // Check if we already have today's fresh insight and force == false
        if !force, let existing = storageService.loadDailyAIInsight(),
           Calendar.current.isDateInToday(existing.date) {
            return existing
        }

        // 1. Gather symbols from both portfolios and watchlists
        let portfolioSymbols = storageService.portfolios.flatMap(\.holdings).map(\.symbol)
        let watchlistSymbols = storageService.watchlists.flatMap(\.symbols)
        let uniqueSymbols = Array(Set(portfolioSymbols + watchlistSymbols)).filter { !$0.isEmpty }
        guard !uniqueSymbols.isEmpty else {
            let summary: String
            switch storageService.appLanguage.lowercased() {
            case "ja": summary = "分析対象の銘柄またはポートフォリオがありません。"
            case "en": summary = "No tracked symbols or portfolios available for analysis."
            default: summary = "Chưa có danh mục hoặc mã theo dõi để phân tích."
            }
            let emptyInsight = HomeAIInsight(
                date: Date(),
                portfolioSummary: summary,
                items: [],
                language: storageService.appLanguage
            )
            storageService.saveDailyAIInsight(emptyInsight)
            return emptyInsight
        }

        // 2. Resolve quotes and ensure live quotes are available
        var resolvedQuotes: [(symbol: String, quote: StockQuote)] = []
        for sym in uniqueSymbols {
            if let q = stockService.quotes[sym] ?? stockService.quotes[sym.uppercased()], q.price.isFinite {
                resolvedQuotes.append((sym, q))
            }
        }

        if resolvedQuotes.isEmpty {
            await stockService.refreshAll(storageService: storageService)
            for sym in uniqueSymbols {
                if let q = stockService.quotes[sym] ?? stockService.quotes[sym.uppercased()], q.price.isFinite {
                    resolvedQuotes.append((sym, q))
                }
            }
        }

        guard !resolvedQuotes.isEmpty else {
            let summary: String
            switch storageService.appLanguage.lowercased() {
            case "ja": summary = "本日の値動きを分析するための通常セッション価格データがありません。"
            case "en": summary = "No regular session price data available to analyze today's movements."
            default: summary = "Không có dữ liệu giá phiên chính để phân tích biến động hôm nay."
            }
            let emptyInsight = HomeAIInsight(
                date: Date(),
                portfolioSummary: summary,
                items: [],
                language: storageService.appLanguage
            )
            storageService.saveDailyAIInsight(emptyInsight)
            return emptyInsight
        }

        // Separate and deduplicate Crypto vs Equities / Funds / Stocks
        var stockCandidates: [SymbolCandidate] = []
        var cryptoByBaseAsset: [String: (originalSymbol: String, quote: StockQuote)] = [:]

        for (sym, q) in resolvedQuotes {
            if let base = Self.cryptoBaseAsset(for: sym) {
                // Deduplicate: keep the best quote for this base asset (e.g. BTC-USD or BTCUSDT)
                if cryptoByBaseAsset[base] != nil {
                    if sym.contains("-USD") || sym.hasSuffix("USDT") {
                        cryptoByBaseAsset[base] = (sym, q)
                    }
                } else {
                    cryptoByBaseAsset[base] = (sym, q)
                }
            } else {
                let name = q.displayName.isEmpty ? (q.name.isEmpty ? sym : q.name) : q.displayName
                let market = Self.detectMarketCategory(symbol: sym, isCrypto: false)
                stockCandidates.append(SymbolCandidate(
                    symbol: sym,
                    name: name,
                    price: q.price,
                    changePercent: q.changePercent,
                    currency: q.currency,
                    isCrypto: false,
                    marketCategory: market,
                    originalSymbol: sym
                ))
            }
        }

        var cryptoCandidates: [SymbolCandidate] = []
        for (base, pair) in cryptoByBaseAsset {
            let name = Self.cryptoDisplayName(for: base, fallback: pair.quote.name)
            cryptoCandidates.append(SymbolCandidate(
                symbol: base,
                name: name,
                price: pair.quote.price,
                changePercent: pair.quote.changePercent,
                currency: pair.quote.currency.isEmpty ? "USD" : pair.quote.currency,
                isCrypto: true,
                marketCategory: .crypto,
                originalSymbol: pair.originalSymbol
            ))
        }

        // Group stocks by market category
        let usStocks = stockCandidates.filter { $0.marketCategory == .us }
            .sorted { abs($0.changePercent) > abs($1.changePercent) }
        let jpStocks = stockCandidates.filter { $0.marketCategory == .japan }
            .sorted { abs($0.changePercent) > abs($1.changePercent) }
        let vnStocks = stockCandidates.filter { $0.marketCategory == .vietnam }
            .sorted { abs($0.changePercent) > abs($1.changePercent) }

        // Sort crypto: BTC first, then remaining altcoins sorted by abs(changePercent) descending
        var sortedCrypto: [SymbolCandidate] = []
        if let btc = cryptoCandidates.first(where: { $0.symbol.uppercased() == "BTC" }) {
            sortedCrypto.append(btc)
        }
        let altcoins = cryptoCandidates.filter { $0.symbol.uppercased() != "BTC" }
            .sorted { abs($0.changePercent) > abs($1.changePercent) }
        sortedCrypto.append(contentsOf: altcoins)

        // Balanced selection per market section:
        // - US: top 2-3 movers
        // - JP: top 1-2 movers (if present)
        // - VN: top 1-2 movers (if present)
        // - Crypto: BTC + top 1 altcoin (if present)
        var selectedMovers: [SymbolCandidate] = []
        selectedMovers.append(contentsOf: usStocks.prefix(3))
        selectedMovers.append(contentsOf: jpStocks.prefix(2))
        selectedMovers.append(contentsOf: vnStocks.prefix(2))

        if let btc = sortedCrypto.first(where: { $0.symbol.uppercased() == "BTC" }) {
            selectedMovers.append(btc)
        }
        if let topAlt = sortedCrypto.first(where: { $0.symbol.uppercased() != "BTC" }) {
            selectedMovers.append(topAlt)
        }

        // If total is empty (fallback), take whatever candidates exist
        if selectedMovers.isEmpty {
            selectedMovers = Array((stockCandidates + cryptoCandidates).prefix(5))
        }

        // 3. Fetch benchmark quotes for active markets to provide macro context
        let activeMarkets = Set(selectedMovers.map(\.marketCategory))
        var benchmarkSymbols: [String] = []
        if activeMarkets.contains(.us) {
            benchmarkSymbols.append(contentsOf: ["^GSPC", "^IXIC", "^DJI"])
        }
        if activeMarkets.contains(.japan) {
            benchmarkSymbols.append("^N225")
        }
        if activeMarkets.contains(.vietnam) {
            benchmarkSymbols.append("^VNINDEX.VN")
        }
        if activeMarkets.contains(.crypto) {
            benchmarkSymbols.append(contentsOf: ["BTC-USD", "ETH-USD"])
        }

        let missingBenchmarks = benchmarkSymbols.filter {
            stockService.quotes[$0] == nil && stockService.quotes[$0.uppercased()] == nil
        }
        if !missingBenchmarks.isEmpty {
            await stockService.fetchQuotes(symbols: missingBenchmarks)
        }

        var marketBenchmarks: [MarketCategory: [(name: String, symbol: String, price: Double, changePercent: Double)]] = [:]
        for cat in activeMarkets {
            switch cat {
            case .us:
                var list: [(name: String, symbol: String, price: Double, changePercent: Double)] = []
                for (sym, label) in [("^GSPC", "S&P 500"), ("^IXIC", "Nasdaq"), ("^DJI", "Dow Jones")] {
                    if let q = stockService.quotes[sym] ?? stockService.quotes[sym.uppercased()], q.price.isFinite {
                        list.append((label, sym, q.price, q.changePercent))
                    }
                }
                marketBenchmarks[.us] = list
            case .japan:
                var list: [(name: String, symbol: String, price: Double, changePercent: Double)] = []
                for (sym, label) in [("^N225", "Nikkei 225")] {
                    if let q = stockService.quotes[sym] ?? stockService.quotes[sym.uppercased()], q.price.isFinite {
                        list.append((label, sym, q.price, q.changePercent))
                    }
                }
                marketBenchmarks[.japan] = list
            case .vietnam:
                var list: [(name: String, symbol: String, price: Double, changePercent: Double)] = []
                for (sym, label) in [("^VNINDEX.VN", "VN-Index")] {
                    if let q = stockService.quotes[sym] ?? stockService.quotes[sym.uppercased()], q.price.isFinite {
                        list.append((label, sym, q.price, q.changePercent))
                    }
                }
                marketBenchmarks[.vietnam] = list
            case .crypto:
                var list: [(name: String, symbol: String, price: Double, changePercent: Double)] = []
                for (sym, label) in [("BTC-USD", "Bitcoin (BTC)"), ("ETH-USD", "Ethereum (ETH)")] {
                    if let q = stockService.quotes[sym] ?? stockService.quotes[sym.uppercased()], q.price.isFinite {
                        list.append((label, sym, q.price, q.changePercent))
                    }
                }
                marketBenchmarks[.crypto] = list
            }
        }

        // 4. Fetch symbol-specific news and ensure price history for multi-day context
        await withTaskGroup(of: Void.self) { group in
            for mover in selectedMovers {
                let symKey = mover.originalSymbol.uppercased()
                if stockService.newsBySymbol[symKey] == nil || stockService.newsBySymbol[symKey]?.isEmpty == true {
                    group.addTask {
                        await stockService.refreshNews(
                            for: mover.originalSymbol,
                            displayName: mover.name,
                            marketCategory: mover.marketCategory
                        )
                    }
                }
                group.addTask {
                    await stockService.ensurePriceHistory(for: mover.originalSymbol)
                }
            }
        }

        // 5. Filter news in the last 72h (or 120h on Mondays/weekends) to capture major weekend/recent events
        let weekday = Calendar.current.component(.weekday, from: Date())
        let isMondayOrSunday = (weekday == 2 || weekday == 1)
        let maxAgeSeconds: TimeInterval = isMondayOrSunday ? (120 * 3600) : (72 * 3600)
        let now = Date()

        var articlesBySymbol: [String: [NewsArticle]] = [:]
        for mover in selectedMovers {
            let symKey = mover.originalSymbol.uppercased()
            let symNews = stockService.newsBySymbol[symKey] ?? stockService.newsBySymbol[mover.symbol.uppercased()] ?? []
            let generalNews = stockService.news.filter {
                $0.sourceSymbol?.uppercased() == symKey ||
                $0.sourceSymbol?.uppercased() == mover.symbol.uppercased() ||
                $0.relatedTickers.contains { $0.uppercased() == symKey || $0.uppercased() == mover.symbol.uppercased() }
            }
            let combined = Array(Set(symNews + generalNews))
                .filter { now.timeIntervalSince($0.publishedAt) <= maxAgeSeconds }
                .sorted { $0.publishTime > $1.publishTime }
            articlesBySymbol[mover.symbol] = Array(combined.prefix(6))
        }

        // 5b. Fetch macro news (Clarity Act, regulatory policy, Fed, inflation)
        var macroNews: [MarketCategory: [NewsArticle]] = [:]
        let hasCrypto = selectedMovers.contains { $0.marketCategory == .crypto || Self.isCryptoProxy(symbol: $0.symbol) || Self.isCryptoProxy(symbol: $0.originalSymbol) }
        if hasCrypto {
            let cryptoArticles = await stockService.fetchNewsChunk(
                query: "crypto (\"Clarity Act\" OR regulation OR bill OR Senate OR SEC OR \"Bitcoin crash\" OR \"Bitcoin rally\")",
                sourceSymbol: "CRYPTO_MACRO"
            )
            if !cryptoArticles.isEmpty {
                macroNews[.crypto] = Array(cryptoArticles.prefix(4))
            }
        }
        let hasUS = selectedMovers.contains { $0.marketCategory == .us }
        if hasUS {
            let usArticles = await stockService.fetchNewsChunk(
                query: "stock market news (Wall Street OR S&P 500 OR Nasdaq OR Fed OR CPI OR inflation)",
                sourceSymbol: "US_MACRO"
            )
            if !usArticles.isEmpty {
                macroNews[.us] = Array(usArticles.prefix(3))
            }
        }

        // 6. Build prompt with market benchmarks, movers, multi-day trend, and macro news
        let prompt = buildPrompt(
            movers: selectedMovers,
            quotes: stockService.quotes,
            priceHistory: stockService.priceHistory,
            macroNews: macroNews,
            stockFearGreed: stockService.stockFearGreed,
            cryptoFearGreed: stockService.cryptoFearGreed,
            marketBenchmarks: marketBenchmarks,
            articlesBySymbol: articlesBySymbol,
            storageService: storageService
        )

        // 7. Send to AI (enable real-time search grounding for Gemini)
        let isGemini = storageService.aiProvider == "gemini" || storageService.aiBaseURL.contains("googleapis.com")
        let request = AIReviewService.Request(
            baseURL: storageService.aiBaseURL,
            apiKey: storageService.aiApiKey,
            model: storageService.aiModel,
            systemContext: prompt.systemContext,
            messages: [AIChatSection.APIMessage(role: "user", content: prompt.userMessage)],
            thinking: storageService.aiProvider == "deepseek" ? storageService.aiDeepseekThinking : nil,
            maxTokens: 4096,
            enableSearchGrounding: isGemini
        )

        let reply = try await aiService.send(request: request)

        // 8. Parse response
        let insight = try parseAIResponse(
            reply: reply,
            movers: selectedMovers,
            articlesBySymbol: articlesBySymbol,
            language: storageService.appLanguage
        )

        // 9. Cache in storage
        storageService.saveDailyAIInsight(insight)
        return insight
    }

    private func formatMarketCap(_ value: Double, currency: String) -> String {
        let isVND = currency.uppercased() == "VND"
        let prefix = isVND ? "₫" : "$"
        
        if isVND {
            let inBillions = value / 1_000_000_000
            if inBillions >= 1000 {
                return String(format: "%@%.0fT tỷ", prefix, inBillions / 1000)
            } else {
                return String(format: "%@%.0f tỷ", prefix, inBillions)
            }
        } else {
            if value >= 1_000_000_000_000 {
                return String(format: "%@%.1fT", prefix, value / 1_000_000_000_000)
            } else if value >= 1_000_000_000 {
                return String(format: "%@%.0fB", prefix, value / 1_000_000_000)
            } else if value >= 1_000_000 {
                return String(format: "%@%.0fM", prefix, value / 1_000_000)
            } else {
                return String(format: "%@%.0f", prefix, value)
            }
        }
    }

    func buildPrompt(
        movers: [SymbolCandidate],
        quotes: [String: StockQuote] = [:],
        priceHistory: [String: [PricePoint]] = [:],
        macroNews: [MarketCategory: [NewsArticle]] = [:],
        stockFearGreed: FearGreedData? = nil,
        cryptoFearGreed: FearGreedData? = nil,
        marketBenchmarks: [MarketCategory: [(name: String, symbol: String, price: Double, changePercent: Double)]] = [:],
        articlesBySymbol: [String: [NewsArticle]],
        storageService: StorageService
    ) -> (systemContext: String, userMessage: String) {
        let lang = storageService.appLanguage.lowercased()
        let languageInstruction: String
        let summaryPlaceholder: String
        let overviewPlaceholderUS: String
        let overviewPlaceholderJP: String
        let overviewPlaceholderVN: String
        let overviewPlaceholderCrypto: String
        let driverPlaceholder: String
        let bulletsPlaceholder1: String
        let bulletsPlaceholder2: String

        switch lang {
        case "ja":
            languageInstruction = "TOÀN BỘ nội dung phản hồi PHẢI ĐƯỢC VIẾT BẰNG TIẾNG NHẬT (日本語) tự nhiên, trôi chảy, đúng chuẩn văn phong phân tích tài chính chuyên nghiệp của Nhật Bản."
            summaryPlaceholder = "本日の市場全体およびポートフォリオの概況をまとめた、鋭く簡潔な日本語の1〜2文。"
            overviewPlaceholderUS = "S&P 500、Nasdaq、Dow Jonesの動向と背景を分析した簡潔な日本語の1〜2文。"
            overviewPlaceholderJP = "日経平均株価の動向と背景を分析した簡潔な日本語の1〜2文。"
            overviewPlaceholderVN = "VN-Indexの動向と背景を分析した簡潔な日本語の1〜2文。"
            overviewPlaceholderCrypto = "BitcoinやEthereumの動向、最新の政策動向を分析した簡潔な日本語の1〜2文。"
            driverPlaceholder = "銘柄の本日における値動きの核心要因を明快に説明した簡潔な日本語の1文。"
            bulletsPlaceholder1 = "企業・資産の財務データや重要イベントに関する箇条書き（日本語）"
            bulletsPlaceholder2 = "バリュエーション、需給、テクニカルまたは市場相関に関する箇条書き（日本語）"
        case "en":
            languageInstruction = "ALL content MUST BE WRITTEN IN NATURAL, PROFESSIONAL FINANCIAL ENGLISH."
            summaryPlaceholder = "Concise, sharp 1-2 sentence overview in English of today's markets and portfolio performance."
            overviewPlaceholderUS = "1-2 sentence sharp analysis in English of S&P 500, Nasdaq, and Dow Jones movements."
            overviewPlaceholderJP = "1-2 sentence sharp analysis in English of Nikkei 225 movements."
            overviewPlaceholderVN = "1-2 sentence sharp analysis in English of VN-Index movements."
            overviewPlaceholderCrypto = "1-2 sentence sharp analysis in English of Bitcoin & Ethereum movements and policy developments."
            driverPlaceholder = "A concise, sharp sentence in English stating the exact catalyst or industry factor driving today's movement."
            bulletsPlaceholder1 = "Core financial data / key event bullet point in English"
            bulletsPlaceholder2 = "Valuation / cashflow / technical context or market correlation bullet point in English"
        default: // "vi" and others
            languageInstruction = "TOÀN BỘ nội dung PHẢI ĐƯỢC VIẾT BẰNG TIẾNG VIỆT tự nhiên, chuẩn mực, văn phong tài chính chuyên nghiệp."
            summaryPlaceholder = "Tóm tắt 1-2 câu ngắn gọn, sắc bén bằng tiếng Việt về toàn cảnh các thị trường và danh mục hôm nay."
            overviewPlaceholderUS = "1-2 câu tiếng Việt phân tích bối cảnh và nêu cụ thể mức tăng giảm của S&P 500, Nasdaq, Dow Jones."
            overviewPlaceholderJP = "1-2 câu tiếng Việt phân tích bối cảnh và nêu cụ thể mức tăng giảm của Nikkei 225."
            overviewPlaceholderVN = "1-2 câu tiếng Việt phân tích bối cảnh và nêu cụ thể mức tăng giảm của VN-Index."
            overviewPlaceholderCrypto = "1-2 câu tiếng Việt phân tích bối cảnh và nêu cụ thể mức tăng giảm của Bitcoin & Ethereum cùng các sự kiện chính sách mới nhất."
            driverPlaceholder = "Một câu tiếng Việt ngắn gọn, sắc bén nêu chính xác nguyên nhân nội tại hoặc yếu tố ngành khiến mã tăng/giảm hôm nay."
            bulletsPlaceholder1 = "Luận điểm số liệu / sự kiện cốt lõi của doanh nghiệp bằng tiếng Việt"
            bulletsPlaceholder2 = "Bối cảnh định giá / dòng tiền / áp lực kỹ thuật hoặc tương quan thị trường bằng tiếng Việt"
        }

        var sys = """
        Bạn là một chuyên gia phân tích tài chính và chiến lược thị trường cấp cao của StockDeck.
        Nhiệm vụ của bạn:
        1. Phân tích bối cảnh và chuyển động chung của TỪNG THỊ TRƯỜNG trước (Mỹ, Nhật Bản, Việt Nam, Crypto) dựa trên biến động của các chỉ số đại diện (S&P 500, Nasdaq, Dow Jones, Nikkei 225, VN-Index, Bitcoin) và tin tức vĩ mô mới nhất.
        2. Phân tích và giải thích NGUYÊN NHÂN TĂNG/GIẢM CỐT LÕI & SÂU SẮC cho TỪNG MÃ CỔ PHIẾU/TÀI SẢN trong danh mục.

        QUY TẮC PHÂN TÍCH CHUYÊN SÂU & BẢO ĐẢM TÍNH TRUNG THỰC (BẮT BUỘC TUÂN THỦ 100%):
        1. BỐI CẢNH THỊ TRƯỜNG ("marketOverviews"): Viết 1-2 câu nhận định sắc bén về chuyển động của các chỉ số chính, nêu rõ mức tăng/giảm cụ thể của các chỉ số đại diện (Ví dụ: "Thị trường Mỹ tăng điểm tích cực khi S&P 500 tăng +0.76%, Nasdaq tăng +1.12% nhờ lực kéo từ nhóm công nghệ..."; "VN-Index tăng +1.67% lên 1,280 điểm nhờ lực cầu lan tỏa...").
        2. TỪNG MÃ CỔ PHIẾU/TÀI SẢN ("items"):
           - NGUYÊN NHÂN CỐT LÕI (coreDriver) PHẢI LÀ CHẤT XÚC TÁC / SỰ KIỆN THỰC TẾ:
             * Bắt buộc giải thích BẰNG SỰ KIỆN: Kết quả kinh doanh, Doanh thu ARR/EPS, Hợp đồng đối tác, Mua lại cổ phiếu, Nâng/Hạ xếp hạng, hoặc Sự kiện vĩ mô / Chính sách pháp lý (ví dụ: dự luật Clarity Act, phán quyết SEC, thuế quan, lãi suất Fed...), hoặc tương quan tài sản neo (ví dụ: Bitcoin điều chỉnh giảm kéo theo các mã ủy thác).
             * TUYỆT ĐỐI CẤM dùng "52-week range" làm lý do cốt lõi trong coreDriver (CẤM viết kiểu "Cổ phiếu giảm vì đang ở vùng đỉnh 52 tuần"). Vị thế 52W range chỉ là dữ liệu kỹ thuật tham khảo phụ, chỉ được đưa vào bulletPoints hoặc actionableNote nếu cần.
           - CỔ PHIẾU PROXY & TƯƠNG QUAN BITCOIN:
             * Đối với các cổ phiếu nắm giữ crypto hoặc hoạt động trong ngành khai thác / sàn giao dịch (như MSTR, BMNR, COIN, MARA, RIOT, CLSK, CIFR, HUT, CORZ...): biến động giá CHỦ YẾU PHỤ THUỘC VÀO GIÁ BITCOIN (với hệ số beta đòn bẩy). Khi Bitcoin giảm (ví dụ: tin tức vĩ mô Clarity Act tạch), các mã này sẽ giảm theo ngay cả khi nội bộ công ty không có tin riêng. BẮT BUỘC phải chỉ ra tương quan trực tiếp với biến động của Bitcoin, KHÔNG ĐƯỢC giải thích như một doanh nghiệp độc lập!
           - BỐI CẢNH ĐA PHIÊN & TRÁNH ĐÁNH GIÁ THIỂN CẬN:
             * Khi đánh giá biến động, PHẢI đối chiếu cả phiên hôm nay với phiên trước và xu hướng 3 ngày / 7 ngày được cung cấp trong dữ liệu. Nếu một mã hôm nay chỉ tăng nhẹ (+0.2% đến +0.5%) sau khi vừa sụt giảm mạnh (-3% đến -5%) ở phiên trước, PHẢI giải thích rõ đây là "nhịp hồi phục kỹ thuật nhẹ / tích lũy sau phiên bán tháo mạnh hôm trước", TUYỆT ĐỐI KHÔNG đánh giá thiển cận là "hôm nay tăng trưởng tích cực".
           - TÍCH HỢP TIN TỨC VĨ MÔ & PHÁP LÝ:
             * Phải đọc kỹ phần Tin tức vĩ mô được cung cấp (như diễn biến dự luật Clarity Act, quyết định của SEC, động thái Fed...) để phản ánh chính xác nguyên nhân của Bitcoin và các cổ phiếu liên quan.
           - PHÂN BIỆT RÕ RÀNG YẾU TỐ RIÊNG LẺ VS YẾU TỐ NGÀNH:
             * Nếu có tin tức nội tại: Nêu rõ tên sản phẩm/dịch vụ cốt lõi (ví dụ: Falcon platform đối với CrowdStrike, GPU Hopper/Blackwell với Nvidia, mảng thép HRC với Hòa Phát...).
             * Nếu cổ phiếu biến động theo đà chung của ngành/thị trường mà không có tin tức nội tại mới: PHẢI nói thẳng rõ ràng (ví dụ: "Cổ phiếu chịu áp lực điều chỉnh chung theo nhóm Cloud SaaS khi lợi suất trái phiếu tăng, chưa ghi nhận tin tức tiêu cực riêng lẻ từ nội bộ công ty.").
           - TUYỆT ĐỐI KHÔNG dùng những câu văn sáo rỗng chung chung có thể gán cho bất kỳ công ty nào mà không chỉ ra đặc thù của mã đó.
        3. \(languageInstruction)

        Cấu trúc JSON phản hồi bắt buộc đúng 100% định dạng sau:
        {
          "portfolioSummary": "\(summaryPlaceholder)",
          "marketOverviews": {
            "US": "\(overviewPlaceholderUS)",
            "JP": "\(overviewPlaceholderJP)",
            "VN": "\(overviewPlaceholderVN)",
            "CRYPTO": "\(overviewPlaceholderCrypto)"
          },
          "items": [
            {
              "symbol": "SYMBOL",
              "name": "Tên công ty / Quỹ / Tài sản",
              "coreDriver": "\(driverPlaceholder)",
              "bulletPoints": [
                "\(bulletsPlaceholder1)",
                "\(bulletsPlaceholder2)"
              ],
              "sentiment": "positive",
              "sourcePublisher": "Tên nguồn báo chí (ví dụ: 'CNBC', 'Bloomberg', 'Reuters', 'Morningstar') hoặc 'Dòng tiền & Nhóm ngành'"
            }
          ]
        }
        Chỉ trả về duy nhất chuỗi JSON hợp lệ. Không thêm bất kỳ lời dẫn hay văn bản thừa bên ngoài.
        """
        
        let customPrompt = storageService.aiCustomPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !customPrompt.isEmpty {
            sys += "\n\n--- YÊU CẦU TÙY CHỈNH TỪ NGƯỜI DÙNG ---\n"
            sys += customPrompt
            sys += "\n---------------------------------------"
        }

        var user = "Dưới đây là dữ liệu biến động các chỉ số thị trường, xu hướng đa phiên và tin tức vĩ mô/doanh nghiệp gần nhất:\n\n"

        // Add Market Benchmarks
        if !marketBenchmarks.isEmpty {
            user += "=== BỐI CẢNH CÁC CHỈ SỐ THỊ TRƯỜNG HÔM NAY ===\n"
            for cat in MarketCategory.allCases {
                if let benchmarks = marketBenchmarks[cat], !benchmarks.isEmpty {
                    let desc = benchmarks.map { item in
                        let sign = item.changePercent >= 0 ? "+" : ""
                        return "\(item.name): \(sign)\(String(format: "%.2f%%", item.changePercent))"
                    }.joined(separator: " | ")
                    user += "• \(cat.title): \(desc)\n"
                }
            }
            user += "\n"
        }

        // Add Macro News (e.g. Clarity Act, SEC, Fed)
        if let cryptoMacro = macroNews[.crypto], !cryptoMacro.isEmpty {
            user += "=== TIN TỨC VĨ MÔ & PHÁP LÝ THỊ TRƯỜNG CRYPTO (24H - 72H) ===\n"
            for (idx, article) in cryptoMacro.enumerated() {
                user += "  [\(idx + 1)] \"\(article.title)\" (Nguồn: \(article.publisher))"
                if !article.content.isEmpty {
                    user += " - \(article.content.prefix(350))"
                }
                user += "\n"
            }
            user += "\n"
        }

        if let usMacro = macroNews[.us], !usMacro.isEmpty {
            user += "=== TIN TỨC VĨ MÔ THỊ TRƯỜNG CHỨNG KHOÁN MỸ (24H - 72H) ===\n"
            for (idx, article) in usMacro.enumerated() {
                user += "  [\(idx + 1)] \"\(article.title)\" (Nguồn: \(article.publisher))"
                if !article.content.isEmpty {
                    user += " - \(article.content.prefix(350))"
                }
                user += "\n"
            }
            user += "\n"
        }

        if stockFearGreed != nil || cryptoFearGreed != nil {
            user += "=== TÂM LÝ THỊ TRƯỜNG (FEAR & GREED INDEX) ===\n"
            if let fg = stockFearGreed {
                user += "• Chứng khoán Mỹ (CNN): \(fg.score)/100 — \(fg.label) (tuần trước: \(fg.weekAgo ?? 0), tháng trước: \(fg.monthAgo ?? 0))\n"
            }
            if let fg = cryptoFearGreed {
                user += "• Crypto (Alternative.me): \(fg.score)/100 — \(fg.label) (hôm qua: \(fg.previousClose ?? 0))\n"
            }
            user += "→ Hãy đánh giá mức rủi ro (riskLevel) và đưa khuyến nghị hành động mạnh dạn (actionableNote) dựa trên tâm lý thị trường + vị thế giá.\n\n"
        }

        // Add Symbols grouped by market
        user += "=== DANH SÁCH MÃ BIẾN ĐỘNG THEO TỪNG THỊ TRƯỜNG ===\n\n"
        let grouped = Dictionary(grouping: movers, by: \.marketCategory)
        for cat in MarketCategory.allCases {
            guard let items = grouped[cat], !items.isEmpty else { continue }
            user += "--- [\(cat.title.uppercased())] ---\n"
            for mover in items {
                let sign = mover.changePercent >= 0 ? "+" : ""
                let pctStr = String(format: "%@%.2f%%", sign, mover.changePercent)
                user += "Mã: \(mover.symbol) | Tên: \(mover.name)\n"

                // Proxy indicator
                if Self.isCryptoProxy(symbol: mover.symbol) || Self.isCryptoProxy(symbol: mover.originalSymbol) {
                    user += "[LƯU Ý: CỔ PHIẾU ỦY THÁC BITCOIN (BITCOIN PROXY) — Biến động tương quan trực tiếp với giá Bitcoin (BTC)]\n"
                }

                // Multi-day price trend
                let trend = Self.computeMultiDayTrend(for: mover.originalSymbol, currentPrice: mover.price, priceHistory: priceHistory)
                var priceLine = "Giá: \(mover.price) \(mover.currency) | Biến động hôm nay: \(pctStr)"
                if let yChg = trend.yesterdayChange {
                    let ySign = yChg >= 0 ? "+" : ""
                    priceLine += String(format: " | Phiên trước: %@%.2f%%", ySign, yChg)
                }
                if let d3 = trend.threeDayChange {
                    let s3 = d3 >= 0 ? "+" : ""
                    priceLine += String(format: " | 3 ngày: %@%.2f%%", s3, d3)
                }
                if let d7 = trend.sevenDayChange {
                    let s7 = d7 >= 0 ? "+" : ""
                    priceLine += String(format: " | 7 ngày: %@%.2f%%", s7, d7)
                }
                user += priceLine + "\n"

                if let quote = quotes[mover.symbol] ?? quotes[mover.originalSymbol] ?? quotes[mover.symbol.uppercased()] ?? quotes[mover.originalSymbol.uppercased()] {
                    if let mc = quote.marketCap, mc > 0 {
                        user += "Market Cap: \(formatMarketCap(mc, currency: quote.currency))\n"
                    }
                    if let h = quote.fiftyTwoWeekHigh, let l = quote.fiftyTwoWeekLow, h > l {
                        let pos = (quote.price - l) / (h - l) * 100
                        user += "52W Range (tham khảo kỹ thuật): \(l) - \(h) (vị trí: \(String(format: "%.0f%%", pos)))\n"
                    }
                }

                let news = articlesBySymbol[mover.symbol] ?? articlesBySymbol[mover.originalSymbol] ?? []
                if news.isEmpty {
                    user += "Tin tức: Chưa có tin tức báo chí trực tiếp riêng lẻ.\n\n"
                } else {
                    user += "Tin tức báo chí:\n"
                    for (idx, article) in news.enumerated() {
                        user += "  [\(idx + 1)] \"\(article.title)\" (Nguồn: \(article.publisher))"
                        if !article.content.isEmpty {
                            user += " - \(article.content.prefix(450))"
                        }
                        user += "\n"
                    }
                    user += "\n"
                }
            }
        }

        return (sys, user)
    }

    func parseAIResponse(
        reply: String,
        movers: [SymbolCandidate],
        articlesBySymbol: [String: [NewsArticle]],
        language: String? = nil
    ) throws -> HomeAIInsight {
        // Strip markdown code fences if present: ```json ... ```
        var cleanJSON = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanJSON.hasPrefix("```") {
            let lines = cleanJSON.components(separatedBy: .newlines)
            let filtered = lines.filter { !$0.hasPrefix("```") }
            cleanJSON = filtered.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard let data = cleanJSON.data(using: .utf8) else {
            throw AIReviewError.decoding("Invalid UTF-8 response from AI")
        }

        struct DTO: Decodable {
            struct ItemDTO: Decodable {
                let symbol: String
                let name: String?
                let marketCategory: String?
                let changePercent: Double?
                let coreDriver: String
                let bulletPoints: [String]?
                let sentiment: String?
                let sourcePublisher: String?
                let riskLevel: String?
                let actionableNote: String?
            }
            let portfolioSummary: String
            let marketOverviews: [String: String]?
            let items: [ItemDTO]
        }

        let decoded = try JSONDecoder().decode(DTO.self, from: data)

        var finalItems: [SymbolInsightItem] = []
        for item in decoded.items {
            let mover = movers.first {
                $0.symbol.uppercased() == item.symbol.uppercased() ||
                $0.originalSymbol.uppercased() == item.symbol.uppercased()
            }
            let change = item.changePercent ?? mover?.changePercent ?? 0.0
            let name = item.name ?? mover?.name ?? item.symbol
            let price = mover?.price
            let symbolKey = mover?.symbol ?? item.symbol

            // Strict deterministic market category from system data - do not allow AI hallucination to override
            let market: MarketCategory
            if let mover = mover {
                market = mover.marketCategory
            } else {
                market = Self.detectMarketCategory(symbol: symbolKey, isCrypto: false)
            }

            let sentiment: SymbolInsightSentiment
            switch (item.sentiment ?? "").lowercased() {
            case "positive", "tích cực": sentiment = .positive
            case "negative", "tiêu cực": sentiment = .negative
            default: sentiment = change > 0 ? .positive : (change < 0 ? .negative : .neutral)
            }

            let risk: InsightRiskLevel?
            switch (item.riskLevel ?? "").lowercased() {
            case "low": risk = .low
            case "moderate": risk = .moderate
            case "high": risk = .high
            case "extreme": risk = .extreme
            default: risk = nil
            }

            // Find matching sources
            let origKey = mover?.originalSymbol ?? item.symbol
            let news = articlesBySymbol[symbolKey] ?? articlesBySymbol[origKey] ?? []
            let sources = news.map {
                InsightSourceRef(
                    articleId: $0.id,
                    title: $0.title,
                    publisher: $0.publisher,
                    url: $0.link
                )
            }

            finalItems.append(SymbolInsightItem(
                symbol: symbolKey,
                name: name,
                changePercent: change,
                currentPrice: price,
                currency: mover?.currency,
                coreDriver: item.coreDriver,
                bulletPoints: item.bulletPoints ?? [],
                sentiment: sentiment,
                sources: sources,
                marketCategory: market,
                riskLevel: risk,
                actionableNote: item.actionableNote
            ))
        }

        return HomeAIInsight(
            date: Date(),
            portfolioSummary: decoded.portfolioSummary,
            marketOverviews: decoded.marketOverviews,
            items: finalItems,
            language: language,
            generatedAt: Date()
        )
    }
}
