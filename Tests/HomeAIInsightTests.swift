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
}
