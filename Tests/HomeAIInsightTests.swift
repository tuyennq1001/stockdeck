import XCTest
@testable import StockDeck

@MainActor
final class HomeAIInsightTests: XCTestCase {

    func testInsightEncodingAndDecoding() throws {
        let source = InsightSourceRef(
            articleId: "art-1",
            title: "Ferrari beats Q2 earnings",
            publisher: "Reuters",
            url: "https://reuters.com/ferrari"
        )
        let item = SymbolInsightItem(
            symbol: "RACE",
            name: "Ferrari N.V.",
            changePercent: 3.12,
            currentPrice: 425.0,
            coreDriver: "Q2 revenue and EPS exceeded analyst expectations.",
            bulletPoints: [
                "Revenue up 8% YoY to €1.94B",
                "Raised full-year 2026 guidance"
            ],
            sentiment: .positive,
            sources: [source]
        )
        let insight = HomeAIInsight(
            date: Date(),
            portfolioSummary: "Thị trường tăng điểm nhờ KQKD tích cực.",
            items: [item]
        )

        let data = try JSONEncoder().encode(insight)
        let decoded = try JSONDecoder().decode(HomeAIInsight.self, from: data)

        XCTAssertEqual(decoded.portfolioSummary, insight.portfolioSummary)
        XCTAssertEqual(decoded.items.count, 1)
        XCTAssertEqual(decoded.items.first?.symbol, "RACE")
        XCTAssertEqual(decoded.items.first?.sentiment, .positive)
        XCTAssertEqual(decoded.items.first?.sources.first?.publisher, "Reuters")
    }

    func testParseAIResponseWithMarkdownCodeFences() throws {
        let jsonPayload = """
        ```json
        {
          "portfolioSummary": "Danh mục ghi nhận mức tăng tốt nhờ nhóm công nghệ và xe sang.",
          "items": [
            {
              "symbol": "NVDA",
              "name": "NVIDIA Corporation",
              "changePercent": 4.5,
              "coreDriver": "Doanh thu chip AI trung tâm dữ liệu tăng mạnh.",
              "bulletPoints": [
                "Nhu cầu GPU Hopper và Blackwell duy trì ở mức cao",
                "Biên lợi nhuận gộp đạt trên 75%"
              ],
              "sentiment": "positive",
              "sourcePublisher": "Bloomberg"
            }
          ]
        }
        ```
        """

        let mover = HomeAIInsightService.SymbolCandidate(
            symbol: "NVDA",
            name: "NVIDIA Corporation",
            price: 130.0,
            changePercent: 4.5,
            currency: "USD"
        )
        let article = NewsArticle(
            id: "news-nvda-1",
            title: "Nvidia Data Center Momentum Continues",
            content: "Strong demand for AI chips.",
            publisher: "Bloomberg",
            link: "https://bloomberg.com/nvda",
            publishTime: Int(Date().timeIntervalSince1970),
            thumbnailURL: nil,
            relatedTickers: ["NVDA"],
            sourceSymbol: "NVDA"
        )

        let parsed = try HomeAIInsightService.shared.parseAIResponse(
            reply: jsonPayload,
            movers: [mover],
            articlesBySymbol: ["NVDA": [article]]
        )

        XCTAssertEqual(parsed.portfolioSummary, "Danh mục ghi nhận mức tăng tốt nhờ nhóm công nghệ và xe sang.")
        XCTAssertEqual(parsed.items.count, 1)
        let nvdaItem = try XCTUnwrap(parsed.items.first)
        XCTAssertEqual(nvdaItem.symbol, "NVDA")
        XCTAssertEqual(nvdaItem.sentiment, .positive)
        XCTAssertEqual(nvdaItem.coreDriver, "Doanh thu chip AI trung tâm dữ liệu tăng mạnh.")
        XCTAssertEqual(nvdaItem.bulletPoints.count, 2)
        XCTAssertEqual(nvdaItem.sources.count, 1)
        XCTAssertEqual(nvdaItem.sources.first?.url, "https://bloomberg.com/nvda")
    }

    func testPromptBuilderIncludesSymbolAndNews() {
        let storage = StorageService.shared
        let mover = HomeAIInsightService.SymbolCandidate(
            symbol: "AAPL",
            name: "Apple Inc.",
            price: 220.0,
            changePercent: -1.2,
            currency: "USD"
        )
        let article = NewsArticle(
            id: "news-aapl-1",
            title: "Apple iPhone 16 production ramp up",
            content: "Suppliers indicate steady shipment targets.",
            publisher: "Reuters",
            link: "https://reuters.com/aapl",
            publishTime: Int(Date().timeIntervalSince1970),
            thumbnailURL: nil,
            relatedTickers: ["AAPL"],
            sourceSymbol: "AAPL"
        )

        let prompt = HomeAIInsightService.shared.buildPrompt(
            movers: [mover],
            articlesBySymbol: ["AAPL": [article]],
            storageService: storage
        )

        XCTAssertTrue(prompt.systemContext.contains("StockDeck"))
        XCTAssertTrue(prompt.systemContext.contains("portfolioSummary"))
        XCTAssertTrue(prompt.userMessage.contains("AAPL"))
        XCTAssertTrue(prompt.userMessage.contains("Apple iPhone 16 production ramp up"))
    }

    func testStorageServiceDailyInsightCache() {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let tempFile = tempDir.appendingPathComponent("data.json")
        let storage = StorageService(fileURL: tempFile)
        let insight = HomeAIInsight(
            date: Date(),
            portfolioSummary: "Test daily cache summary",
            items: []
        )

        storage.saveDailyAIInsight(insight)
        let loaded = storage.loadDailyAIInsight()

        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.portfolioSummary, "Test daily cache summary")
    }

    func testCryptoBaseAssetNormalization() {
        XCTAssertEqual(HomeAIInsightService.cryptoBaseAsset(for: "BTC-USD"), "BTC")
        XCTAssertEqual(HomeAIInsightService.cryptoBaseAsset(for: "BTCUSDT"), "BTC")
        XCTAssertEqual(HomeAIInsightService.cryptoBaseAsset(for: "BTCETH"), "BTC")
        XCTAssertEqual(HomeAIInsightService.cryptoBaseAsset(for: "ETHUSDC"), "ETH")
        XCTAssertEqual(HomeAIInsightService.cryptoBaseAsset(for: "ETHUSDT"), "ETH")
        XCTAssertEqual(HomeAIInsightService.cryptoBaseAsset(for: "ETH-USD"), "ETH")
        XCTAssertEqual(HomeAIInsightService.cryptoBaseAsset(for: "SOLUSDT"), "SOL")
        XCTAssertEqual(HomeAIInsightService.cryptoBaseAsset(for: "SUIUSDT"), "SUI")
        XCTAssertEqual(HomeAIInsightService.cryptoBaseAsset(for: "DOGE-USD"), "DOGE")
        XCTAssertNil(HomeAIInsightService.cryptoBaseAsset(for: "AAPL"))
        XCTAssertNil(HomeAIInsightService.cryptoBaseAsset(for: "VOO"))
        XCTAssertNil(HomeAIInsightService.cryptoBaseAsset(for: "FUEVFVND.VN"))
    }

    func testMarketCategoryDetection() {
        XCTAssertEqual(HomeAIInsightService.detectMarketCategory(symbol: "AAPL", isCrypto: false), .us)
        XCTAssertEqual(HomeAIInsightService.detectMarketCategory(symbol: "VOO", isCrypto: false), .us)
        XCTAssertEqual(HomeAIInsightService.detectMarketCategory(symbol: "6861.T", isCrypto: false), .japan)
        XCTAssertEqual(HomeAIInsightService.detectMarketCategory(symbol: "9I314241", isCrypto: false), .japan)
        XCTAssertEqual(HomeAIInsightService.detectMarketCategory(symbol: "^N225", isCrypto: false), .japan)
        XCTAssertEqual(HomeAIInsightService.detectMarketCategory(symbol: "FUEVFVND.VN", isCrypto: false), .vietnam)
        XCTAssertEqual(HomeAIInsightService.detectMarketCategory(symbol: "^VNINDEX.VN", isCrypto: false), .vietnam)
        XCTAssertEqual(HomeAIInsightService.detectMarketCategory(symbol: "BTC-USD", isCrypto: true), .crypto)
        XCTAssertEqual(HomeAIInsightService.detectMarketCategory(symbol: "ETHUSDT", isCrypto: false), .crypto)
    }

    func testDeterministicCategoryNeverOverriddenByAI() throws {
        // SKHY is a US stock candidate, but AI hallucinates and labels it "CRYPTO"
        let mover = HomeAIInsightService.SymbolCandidate(
            symbol: "SKHY",
            name: "SK hynix",
            price: 185.0,
            changePercent: 3.5,
            currency: "USD",
            isCrypto: false,
            marketCategory: .us
        )

        let aiReplyWithHallucinatedCrypto = """
        {
          "portfolioSummary": "Thị trường hôm nay tích cực.",
          "marketOverviews": {
            "US": "S&P 500 và Nasdaq tăng điểm nhờ nhóm bán dẫn."
          },
          "items": [
            {
              "symbol": "SKHY",
              "name": "SK hynix",
              "marketCategory": "CRYPTO",
              "changePercent": 3.5,
              "coreDriver": "Kế hoạch mua lại cổ phiếu 28.6 tỷ USD tạo đà tăng trưởng mạnh.",
              "bulletPoints": [
                "SK hynix công bố mua lại lượng lớn cổ phiếu",
                "Hưởng lợi từ làn sóng nhu cầu bộ nhớ băng thông cao HBM"
              ],
              "sentiment": "positive",
              "sourcePublisher": "Yahoo Finance"
            }
          ]
        }
        """

        let parsed = try HomeAIInsightService.shared.parseAIResponse(
            reply: aiReplyWithHallucinatedCrypto,
            movers: [mover],
            articlesBySymbol: [:]
        )

        XCTAssertEqual(parsed.marketOverviews?["US"], "S&P 500 và Nasdaq tăng điểm nhờ nhóm bán dẫn.")
        XCTAssertEqual(parsed.overview(for: .us), "S&P 500 và Nasdaq tăng điểm nhờ nhóm bán dẫn.")
        let item = try XCTUnwrap(parsed.items.first)
        // Must strictly remain .us, NOT .crypto!
        XCTAssertEqual(item.marketCategory, .us)
        XCTAssertEqual(item.symbol, "SKHY")
        XCTAssertEqual(item.coreDriver, "Kế hoạch mua lại cổ phiếu 28.6 tỷ USD tạo đà tăng trưởng mạnh.")
    }

    func testSmartNewsParametersLocalization() {
        // Vietnam Stock
        let vn = StockService.smartNewsParameters(symbol: "HPG.VN", displayName: "Hòa Phát", marketCategory: .vietnam)
        XCTAssertEqual(vn.language, "vi")
        XCTAssertEqual(vn.region, "VN")
        XCTAssertEqual(vn.ceid, "VN:vi")
        XCTAssertTrue(vn.query.contains("HPG") && vn.query.contains("Hòa Phát"))

        // Japan Stock
        let jp = StockService.smartNewsParameters(symbol: "7203.T", displayName: "Toyota", marketCategory: .japan)
        XCTAssertEqual(jp.language, "ja")
        XCTAssertEqual(jp.region, "JP")
        XCTAssertEqual(jp.ceid, "JP:ja")
        XCTAssertTrue(jp.query.contains("7203") && jp.query.contains("Toyota") && jp.query.contains("株価"))

        // Crypto
        let crypto = StockService.smartNewsParameters(symbol: "BTC-USD", displayName: "Bitcoin", marketCategory: .crypto)
        XCTAssertEqual(crypto.language, "en-US")
        XCTAssertTrue(crypto.query.contains("BTC") && crypto.query.contains("Bitcoin") && crypto.query.contains("crypto"))

        // US Stock
        let us = StockService.smartNewsParameters(symbol: "CRWD", displayName: "CrowdStrike Holdings, Inc.", marketCategory: .us)
        XCTAssertEqual(us.language, "en-US")
        XCTAssertTrue(us.query.contains("CRWD") && us.query.contains("CrowdStrike") && us.query.contains("earnings"))
    }

    func testFearGreedDataCalculations() {
        let fgStock = FearGreedData(
            score: 72,
            label: "Greed",
            previousClose: 68,
            weekAgo: 65,
            monthAgo: 50,
            fetchedAt: Date()
        )
        XCTAssertEqual(fgStock.score, 72)
        XCTAssertEqual(fgStock.label, "Greed")
        XCTAssertEqual(fgStock.dailyChange, 4)
        XCTAssertEqual(FearGreedData.vietnameseLabel(for: 72), "Tham lam")
        XCTAssertEqual(FearGreedData.vietnameseLabel(for: 15), "Cực kỳ Sợ hãi")
        XCTAssertEqual(FearGreedData.vietnameseLabel(for: 35), "Sợ hãi")
        XCTAssertEqual(FearGreedData.vietnameseLabel(for: 50), "Trung lập")
        XCTAssertEqual(FearGreedData.vietnameseLabel(for: 85), "Cực kỳ Tham lam")

        let fgCrypto = FearGreedData(
            score: 22,
            label: "Extreme Fear",
            previousClose: 25,
            weekAgo: 30,
            monthAgo: 45,
            fetchedAt: Date()
        )
        XCTAssertEqual(fgCrypto.dailyChange, -3)
        XCTAssertEqual(fgCrypto.scoreColor, .extremeFear)
    }

    func testParseAIResponseWithRiskLevelAndActionableNote() throws {
        let jsonPayload = """
        {
          "portfolioSummary": "Thị trường hưng phấn trong vùng tham lam.",
          "items": [
            {
              "symbol": "AAPL",
              "name": "Apple Inc.",
              "changePercent": 2.1,
              "coreDriver": "Doanh thu dịch vụ đạt kỷ lục 24.2 tỷ USD.",
              "bulletPoints": [
                "Biên lợi nhuận dịch vụ vượt 70%",
                "Thị trường đang trong vùng Greed 72 điểm"
              ],
              "sentiment": "positive",
              "riskLevel": "high",
              "actionableNote": "Cân nhắc chốt lời 20% khi giá tiệm cận đỉnh 52 tuần."
            }
          ]
        }
        """

        let mover = HomeAIInsightService.SymbolCandidate(
            symbol: "AAPL",
            name: "Apple Inc.",
            price: 230.0,
            changePercent: 2.1,
            currency: "USD"
        )

        let parsed = try HomeAIInsightService.shared.parseAIResponse(
            reply: jsonPayload,
            movers: [mover],
            articlesBySymbol: [:]
        )

        XCTAssertEqual(parsed.items.count, 1)
        let item = try XCTUnwrap(parsed.items.first)
        XCTAssertEqual(item.symbol, "AAPL")
        XCTAssertEqual(item.riskLevel, .high)
        XCTAssertEqual(item.riskLevel?.displayLabel, "Rủi ro cao")
        XCTAssertEqual(item.actionableNote, "Cân nhắc chốt lời 20% khi giá tiệm cận đỉnh 52 tuần.")
    }

    func testCryptoProxyDetection() {
        XCTAssertTrue(HomeAIInsightService.isCryptoProxy(symbol: "MSTR"))
        XCTAssertTrue(HomeAIInsightService.isCryptoProxy(symbol: "mstr"))
        XCTAssertTrue(HomeAIInsightService.isCryptoProxy(symbol: "MSTR.US"))
        XCTAssertTrue(HomeAIInsightService.isCryptoProxy(symbol: "BMNR"))
        XCTAssertTrue(HomeAIInsightService.isCryptoProxy(symbol: "COIN"))
        XCTAssertTrue(HomeAIInsightService.isCryptoProxy(symbol: "MARA"))
        XCTAssertTrue(HomeAIInsightService.isCryptoProxy(symbol: "RIOT"))
        XCTAssertFalse(HomeAIInsightService.isCryptoProxy(symbol: "AAPL"))
        XCTAssertFalse(HomeAIInsightService.isCryptoProxy(symbol: "NVDA"))
    }

    func testComputeMultiDayTrend() {
        let now = Date()
        let p1 = PricePoint(date: now.addingTimeInterval(-86400 * 3), close: 100.0)
        let p2 = PricePoint(date: now.addingTimeInterval(-86400 * 2), close: 95.0)
        let p3 = PricePoint(date: now.addingTimeInterval(-86400 * 1), close: 91.675) // -3.5% vs 95.0
        let history = ["BTC-USD": [p1, p2, p3]]

        let trend = HomeAIInsightService.computeMultiDayTrend(
            for: "BTC-USD",
            currentPrice: 92.133, // +0.5% vs 91.675
            priceHistory: history
        )

        XCTAssertNotNil(trend.yesterdayChange)
        if let yesterday = trend.yesterdayChange {
            XCTAssertEqual(yesterday, -3.5, accuracy: 0.1)
        }
    }

    func testSmartNewsParametersForCryptoProxy() {
        let mstr = StockService.smartNewsParameters(symbol: "MSTR", displayName: "MicroStrategy", marketCategory: .us)
        XCTAssertTrue(mstr.query.contains("MSTR"))
        XCTAssertTrue(mstr.query.contains("Bitcoin") || mstr.query.contains("BTC"))

        let btc = StockService.smartNewsParameters(symbol: "BTC-USD", displayName: "Bitcoin", marketCategory: .crypto)
        XCTAssertTrue(btc.query.contains("Bitcoin"))
        XCTAssertTrue(btc.query.contains("Clarity Act"))
    }

    func testBuildPromptIncludesProxyAndMultiDayTrend() {
        let mover = HomeAIInsightService.SymbolCandidate(
            symbol: "MSTR",
            name: "MicroStrategy Inc.",
            price: 130.0,
            changePercent: -4.5,
            currency: "USD",
            isCrypto: false,
            marketCategory: .us,
            originalSymbol: "MSTR"
        )
        let p1 = PricePoint(date: Date().addingTimeInterval(-86400 * 2), close: 145.0)
        let p2 = PricePoint(date: Date().addingTimeInterval(-86400 * 1), close: 136.12) // -6.1%
        let history = ["MSTR": [p1, p2]]

        let macroArticle = NewsArticle(
            id: "clarity-1",
            title: "Senate delays Clarity Act vote",
            content: "Bipartisan disagreement stalls crypto bill.",
            publisher: "CoinDesk",
            link: "https://coindesk.com/clarity",
            publishTime: Int(Date().timeIntervalSince1970),
            thumbnailURL: nil,
            relatedTickers: ["BTC"],
            sourceSymbol: "CRYPTO_MACRO"
        )

        let prompt = HomeAIInsightService.shared.buildPrompt(
            movers: [mover],
            quotes: [:],
            priceHistory: history,
            macroNews: [.crypto: [macroArticle]],
            stockFearGreed: nil,
            cryptoFearGreed: nil,
            marketBenchmarks: [:],
            articlesBySymbol: [:],
            storageService: StorageService.shared
        )

        XCTAssertTrue(prompt.userMessage.contains("BITCOIN PROXY"))
        XCTAssertTrue(prompt.userMessage.contains("Phiên trước"))
        XCTAssertTrue(prompt.userMessage.contains("Clarity Act"))
        XCTAssertTrue(prompt.systemContext.contains("CỔ PHIẾU PROXY & TƯƠNG QUAN BITCOIN"))
        XCTAssertTrue(prompt.systemContext.contains("BỐI CẢNH ĐA PHIÊN"))
    }

    func testFormattedPriceFormatting() {
        // US stock
        let us = SymbolInsightItem(
            symbol: "MSTR",
            name: "MicroStrategy",
            changePercent: -5.36,
            currentPrice: 130.5,
            currency: "USD",
            coreDriver: "Correlation with Bitcoin drop",
            bulletPoints: [],
            sentiment: .negative,
            marketCategory: .us
        )
        XCTAssertEqual(us.formattedPrice, "$130.50")

        // Crypto
        let btc = SymbolInsightItem(
            symbol: "BTC",
            name: "Bitcoin",
            changePercent: 0.5,
            currentPrice: 64230.15,
            currency: "USD",
            coreDriver: "Rebound",
            bulletPoints: [],
            sentiment: .positive,
            marketCategory: .crypto
        )
        XCTAssertEqual(btc.formattedPrice, "$64,230.15")

        // VN stock
        let vn = SymbolInsightItem(
            symbol: "VIC",
            name: "Vingroup",
            changePercent: 1.2,
            currentPrice: 45000.0,
            currency: "VND",
            coreDriver: "Strong trading volume",
            bulletPoints: [],
            sentiment: .positive,
            marketCategory: .vietnam
        )
        XCTAssertEqual(vn.formattedPrice, "45,000 ₫")

        // JP stock
        let jp = SymbolInsightItem(
            symbol: "7203",
            name: "Toyota",
            changePercent: -0.8,
            currentPrice: 3120.0,
            currency: "JPY",
            coreDriver: "Auto sales",
            bulletPoints: [],
            sentiment: .negative,
            marketCategory: .japan
        )
        XCTAssertEqual(jp.formattedPrice, "¥3,120")
    }

    func testSupportedLanguagesIncludeVietnameseAndJapanese() {
        let langs = StorageService.supportedLanguages
        XCTAssertTrue(langs.contains { $0.code == "vi" && $0.name == "Tiếng Việt" }, "supportedLanguages must contain Vietnamese")
        XCTAssertTrue(langs.contains { $0.code == "ja" && $0.name == "日本語" }, "supportedLanguages must contain Japanese")
        XCTAssertTrue(langs.contains { $0.code == "en" && $0.name == "English" }, "supportedLanguages must contain English")
    }

    func testPromptBuilderLanguageCustomization() {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let storage = StorageService(fileURL: tempDir.appendingPathComponent("data.json"))

        let mover = HomeAIInsightService.SymbolCandidate(
            symbol: "AAPL",
            name: "Apple Inc.",
            price: 220.0,
            changePercent: 1.5,
            currency: "USD"
        )

        // 1. Japanese
        storage.appLanguage = "ja"
        let jaPrompt = HomeAIInsightService.shared.buildPrompt(
            movers: [mover],
            articlesBySymbol: [:],
            storageService: storage
        )
        XCTAssertTrue(jaPrompt.systemContext.contains("日本語"), "Japanese prompt should request response in Japanese")

        // 2. Vietnamese
        storage.appLanguage = "vi"
        let viPrompt = HomeAIInsightService.shared.buildPrompt(
            movers: [mover],
            articlesBySymbol: [:],
            storageService: storage
        )
        XCTAssertTrue(viPrompt.systemContext.contains("tiếng Việt"), "Vietnamese prompt should request response in Vietnamese")

        // 3. English
        storage.appLanguage = "en"
        let enPrompt = HomeAIInsightService.shared.buildPrompt(
            movers: [mover],
            articlesBySymbol: [:],
            storageService: storage
        )
        XCTAssertTrue(enPrompt.systemContext.contains("English"), "English prompt should request response in English")
    }

    func testHomeAIInsightLanguagePersistence() throws {
        let insight = HomeAIInsight(
            date: Date(),
            portfolioSummary: "Thị trường hôm nay biến động nhẹ.",
            items: [],
            language: "vi"
        )

        let data = try JSONEncoder().encode(insight)
        let decoded = try JSONDecoder().decode(HomeAIInsight.self, from: data)

        XCTAssertEqual(decoded.language, "vi")
        XCTAssertEqual(decoded.portfolioSummary, insight.portfolioSummary)
    }
}
