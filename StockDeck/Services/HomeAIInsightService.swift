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
    static func cryptoBaseAsset(for symbol: String) -> String? {
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
    static func cryptoDisplayName(for baseAsset: String, fallback: String) -> String {
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
    static func detectMarketCategory(symbol: String, isCrypto: Bool) -> MarketCategory {
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
            let emptyInsight = HomeAIInsight(
                date: Date(),
                portfolioSummary: "Chưa có danh mục hoặc mã theo dõi để phân tích.",
                items: []
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
            let emptyInsight = HomeAIInsight(
                date: Date(),
                portfolioSummary: "Không có dữ liệu giá phiên chính để phân tích biến động hôm nay.",
                items: []
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

        // 4. Fetch symbol-specific news with smart localized parameters
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
            articlesBySymbol[mover.symbol] = Array(combined.prefix(4))
        }

        // 6. Build prompt with market benchmarks and movers
        let prompt = buildPrompt(
            movers: selectedMovers,
            marketBenchmarks: marketBenchmarks,
            articlesBySymbol: articlesBySymbol,
            storageService: storageService
        )

        // 7. Send to AI
        let request = AIReviewService.Request(
            baseURL: storageService.aiBaseURL,
            apiKey: storageService.aiApiKey,
            model: storageService.aiModel,
            systemContext: prompt.systemContext,
            messages: [AIChatSection.APIMessage(role: "user", content: prompt.userMessage)],
            thinking: false,
            maxTokens: 4096
        )

        let reply = try await aiService.send(request: request)

        // 8. Parse response
        let insight = try parseAIResponse(
            reply: reply,
            movers: selectedMovers,
            articlesBySymbol: articlesBySymbol
        )

        // 9. Cache in storage
        storageService.saveDailyAIInsight(insight)
        return insight
    }

    func buildPrompt(
        movers: [SymbolCandidate],
        marketBenchmarks: [MarketCategory: [(name: String, symbol: String, price: Double, changePercent: Double)]] = [:],
        articlesBySymbol: [String: [NewsArticle]],
        storageService: StorageService
    ) -> (systemContext: String, userMessage: String) {
        let sys = """
        Bạn là một chuyên gia phân tích thị trường tài chính cấp cao của StockDeck.
        Nhiệm vụ của bạn:
        1. Phân tích bối cảnh và chuyển động chung của TỪNG THỊ TRƯỜNG trước (Mỹ, Nhật Bản, Việt Nam, Crypto) dựa trên biến động của các chỉ số đại diện (ví dụ: Mỹ dựa trên S&P 500, Nasdaq, Dow Jones; Nhật dựa trên Nikkei 225; Việt Nam dựa trên VN-Index; Crypto dựa trên Bitcoin).
        2. Sau đó, giải thích nguyên nhân tăng/giảm trực diện cho TỪNG MÃ TÀI SẢN trong danh mục.

        NGUYÊN TẮC PHÂN TÍCH VÀ BẢO ĐẢM TÍNH TRUNG THỰC (QUAN TRỌNG NHẤT):
        1. BỐI CẢNH THỊ TRƯỜNG ("marketOverviews"): Viết 1-2 câu nhận định sắc bén về chuyển động của các chỉ số chính (Ví dụ: Mỹ bứt phá nhờ nhóm công nghệ trên S&P 500 & Nasdaq; Nhật Bản tăng theo đà Nikkei 225; VN-Index giằng co quanh mốc tâm lý; Crypto tăng theo nhịp của Bitcoin).
        2. TỪNG MÃ TÀI SẢN ("items"):
           - Nếu có tin tức báo chí được cung cấp: Trích xuất và giải thích đi thẳng vào sự kiện cốt lõi (KQKD, hợp đồng, kế hoạch mua lại cổ phiếu, tin tức ngành...).
           - Nếu KHÔNG CÓ tin tức báo chí trong dữ liệu: BẮT BUỘC giải thích dựa trên đà tăng/giảm đồng pha với chỉ số chung của thị trường hoặc nhóm ngành/cung cầu kỹ thuật. TUYỆT ĐỐI KHÔNG tự bịa đặt, suy đoán tin đồn hay bịa ra các sự kiện doanh nghiệp không có trong dữ liệu đầu vào.
        3. TOÀN BỘ nội dung phản hồi PHẢI ĐƯỢC VIẾT BẰNG TIẾNG VIỆT tự nhiên, chuẩn mực, văn phong tài chính chuyên nghiệp.

        Cấu trúc JSON phản hồi bắt buộc đúng 100% định dạng sau:
        {
          "portfolioSummary": "Tóm tắt 1-2 câu ngắn gọn, sắc bén bằng tiếng Việt về toàn cảnh các thị trường và danh mục hôm nay.",
          "marketOverviews": {
            "US": "1-2 câu tiếng Việt phân tích bối cảnh chuyển động của thị trường Mỹ dựa trên S&P 500, Nasdaq, Dow Jones.",
            "JP": "1-2 câu tiếng Việt phân tích bối cảnh thị trường Nhật Bản dựa trên Nikkei 225.",
            "VN": "1-2 câu tiếng Việt phân tích bối cảnh thị trường Việt Nam dựa trên VN-Index.",
            "CRYPTO": "1-2 câu tiếng Việt phân tích bối cảnh thị trường Tiền mã hóa dựa trên Bitcoin & Ethereum."
          },
          "items": [
            {
              "symbol": "SYMBOL",
              "name": "Tên công ty / Quỹ / Tài sản",
              "coreDriver": "Một câu tiếng Việt ngắn gọn, đi thẳng vào nguyên nhân chính khiến mã tăng hoặc giảm hôm nay.",
              "bulletPoints": [
                "Luận điểm số liệu / tin tức cụ thể hỗ trợ bằng tiếng Việt",
                "Bối cảnh dòng tiền / nhóm ngành / chỉ số chung hỗ trợ bằng tiếng Việt"
              ],
              "sentiment": "positive",
              "sourcePublisher": "Tên nguồn báo chí (ví dụ: 'Reuters', 'Bloomberg') hoặc 'Xu hướng chỉ số / Dòng tiền thị trường'"
            }
          ]
        }
        Chỉ trả về duy nhất chuỗi JSON hợp lệ. Không thêm bất kỳ lời dẫn hay văn bản thừa bên ngoài.
        """

        var user = "Dưới đây là dữ liệu biến động các chỉ số thị trường và tin tức gần nhất:\n\n"

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
                user += "Giá: \(mover.price) \(mover.currency), Biến động hôm nay: \(pctStr)\n"
                let news = articlesBySymbol[mover.symbol] ?? articlesBySymbol[mover.originalSymbol] ?? []
                if news.isEmpty {
                    user += "Tin tức: Chưa có tin tức báo chí trực tiếp riêng lẻ.\n\n"
                } else {
                    user += "Tin tức báo chí:\n"
                    for (idx, article) in news.enumerated() {
                        user += "  [\(idx + 1)] \"\(article.title)\" (Nguồn: \(article.publisher))"
                        if !article.content.isEmpty {
                            user += " - \(article.content.prefix(160))"
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
        articlesBySymbol: [String: [NewsArticle]]
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
                coreDriver: item.coreDriver,
                bulletPoints: item.bulletPoints ?? [],
                sentiment: sentiment,
                sources: sources,
                marketCategory: market
            ))
        }

        return HomeAIInsight(
            date: Date(),
            portfolioSummary: decoded.portfolioSummary,
            marketOverviews: decoded.marketOverviews,
            items: finalItems,
            generatedAt: Date()
        )
    }
}
