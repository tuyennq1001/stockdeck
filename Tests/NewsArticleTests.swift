import XCTest
@testable import StockDeck

final class NewsArticleTests: XCTestCase {

    /// A representative Google News RSS feed as returned by `/rss/search`.
    private let sampleRSS = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <rss version="2.0">
      <channel>
        <title>"AAPL" - Google News</title>
        <item>
          <title>Apple hits new high after earnings beat - Yahoo Finance</title>
          <link>https://news.google.com/rss/articles/CBMi-test1?oc=5</link>
          <guid isPermaLink="false">CBMi-test1</guid>
          <pubDate>Tue, 11 Aug 2026 17:10:15 GMT</pubDate>
          <description>&lt;a href="https://news.google.com/rss/articles/CBMi-test1?oc=5"&gt;Apple hits new high&lt;/a&gt;</description>
          <source url="https://finance.yahoo.com">Yahoo Finance</source>
        </item>
        <item>
          <title>Apple supplier warning. Production delayed in Q3 - Reuters</title>
          <link>https://news.google.com/rss/articles/CBMi-test2?oc=5</link>
          <guid isPermaLink="false">CBMi-test2</guid>
          <pubDate>Mon, 10 Aug 2026 09:30:00 GMT</pubDate>
          <source url="https://www.reuters.com">Reuters</source>
        </item>
        <item>
          <title>Untitled</title>
        </item>
      </channel>
    </rss>
    """.data(using: .utf8)!

    func testParsesRSSItems() {
        let articles = GoogleNewsRSSParser.parse(sampleRSS)
        XCTAssertEqual(articles.count, 2, "items without a link are skipped")
    }

    func testParsesAllFields() throws {
        let a = try XCTUnwrap(GoogleNewsRSSParser.parse(sampleRSS).first)
        XCTAssertEqual(a.id, "CBMi-test1")
        XCTAssertEqual(a.title, "Apple hits new high after earnings beat")
        XCTAssertEqual(a.publisher, "Yahoo Finance")
        XCTAssertEqual(a.link, "https://news.google.com/rss/articles/CBMi-test1?oc=5")
        XCTAssertEqual(a.publishTime, 1786468215)
        XCTAssertNil(a.thumbnailURL, "Google News RSS exposes no thumbnails")
        XCTAssertTrue(a.relatedTickers.isEmpty)
        XCTAssertNil(a.sourceSymbol, "sourceSymbol is not part of the feed; set by the fetcher")
        XCTAssertEqual(a.url?.scheme, "https")
    }

    func testSplitTitleAndContentWithSentenceBreak() throws {
        let second = try XCTUnwrap(GoogleNewsRSSParser.parse(sampleRSS).dropFirst().first)
        XCTAssertEqual(second.title, "Apple supplier warning")
        XCTAssertEqual(second.content, "Production delayed in Q3")
        XCTAssertEqual(second.publisher, "Reuters")
    }

    func testCleanHTML() {
        let html = "<p>Apple &amp; Microsoft report &quot;record&quot; earnings&#39; growth.&nbsp;&lt;strong&gt;Read more&lt;/strong&gt;</p>"
        let cleaned = GoogleNewsRSSParser.cleanHTML(html)
        XCTAssertEqual(cleaned, "Apple & Microsoft report \"record\" earnings' growth. Read more")
    }

    func testParserSetsSourceSymbol() {
        let articles = GoogleNewsRSSParser.parse(sampleRSS, sourceSymbol: "AAPL")
        XCTAssertEqual(articles.first?.sourceSymbol, "AAPL")
        XCTAssertEqual(articles.last?.sourceSymbol, "AAPL")
    }

    func testSkipsItemWithoutLink() {
        let malformed = """
        <rss version="2.0"><channel><item>
          <title>No link</title><guid>g1</guid>
        </item></channel></rss>
        """.data(using: .utf8)!
        XCTAssertTrue(GoogleNewsRSSParser.parse(malformed).isEmpty)
    }

    func testParseMultiFormatDates() {
        let multiFormatRSS = """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0"><channel>
          <item>
            <title>RFC822 GMT</title>
            <link>https://example.com/1</link>
            <pubDate>Tue, 11 Aug 2026 17:10:15 GMT</pubDate>
          </item>
          <item>
            <title>RFC822 Numeric</title>
            <link>https://example.com/2</link>
            <pubDate>Tue, 11 Aug 2026 17:10:15 +0000</pubDate>
          </item>
          <item>
            <title>No Day-of-Week</title>
            <link>https://example.com/3</link>
            <pubDate>11 Aug 2026 17:10:15 GMT</pubDate>
          </item>
          <item>
            <title>No Seconds</title>
            <link>https://example.com/4</link>
            <pubDate>Tue, 11 Aug 2026 17:10 GMT</pubDate>
          </item>
          <item>
            <title>ISO8601</title>
            <link>https://example.com/5</link>
            <pubDate>2026-08-11T17:10:15Z</pubDate>
          </item>
        </channel></rss>
        """.data(using: .utf8)!

        let articles = GoogleNewsRSSParser.parse(multiFormatRSS)
        XCTAssertEqual(articles.count, 5)
        XCTAssertEqual(articles[0].publishTime, 1786468215)
        XCTAssertEqual(articles[1].publishTime, 1786468215)
        XCTAssertEqual(articles[2].publishTime, 1786468215)
        XCTAssertEqual(articles[3].publishTime, 1786468200)
        XCTAssertEqual(articles[4].publishTime, 1786468215)
    }

    func testSortingNewestFirst() {
        let itemOld = NewsArticle(id: "1", title: "Old", publisher: "", link: "https://example.com/1", publishTime: 1000, thumbnailURL: nil, relatedTickers: [])
        let itemNew = NewsArticle(id: "2", title: "New", publisher: "", link: "https://example.com/2", publishTime: 3000, thumbnailURL: nil, relatedTickers: [])
        let itemMid = NewsArticle(id: "3", title: "Mid", publisher: "", link: "https://example.com/3", publishTime: 2000, thumbnailURL: nil, relatedTickers: [])

        let sorted = [itemOld, itemNew, itemMid].sorted { $0.publishTime > $1.publishTime }
        XCTAssertEqual(sorted.map(\.id), ["2", "3", "1"])
    }

    func testSplitTitleAndContentStripsPublisherFromContent() {
        let rawTitle = "Dow Jones Futures: What To Do After S&P 500, Nasdaq Break Support; Will Meta Earnings Save AI? - Investor's Business Daily"
        let rawDescription = "<a href=\"https://news.google.com/123\">Dow Jones Futures: What To Do After S&amp;P 500, Nasdaq Break Support; Will Meta Earnings Save AI?</a>&nbsp;&nbsp;<font color=\"#6f6f6f\">Investor's Business Daily</font>"
        let publisher = "Investor's Business Daily"

        let (title, content) = GoogleNewsRSSParser.splitTitleAndContent(
            rawTitle: rawTitle,
            rawDescription: rawDescription,
            publisher: publisher
        )

        XCTAssertEqual(title, "Dow Jones Futures: What To Do After S&P 500, Nasdaq Break Support; Will Meta Earnings Save AI?")
        XCTAssertEqual(content, "", "Publisher name must not leak into content")
    }

    func testFiltersAutomatedOptionQuoteSpam() {
        let optionItemRSS = """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0"><channel>
          <item>
            <title>INTC Sep 2027 160.000 call (INTC270917C00160000) stock price, news, quote and history - Yahoo Finance</title>
            <link>https://news.google.com/rss/articles/123</link>
            <description>Find the latest INTC Sep 2027 160.000 call (INTC270917C00160000) stock quote, history, news and other vital information</description>
            <source url="https://finance.yahoo.com">Yahoo Finance</source>
          </item>
          <item>
            <title>INTC Oct 2026 130.000 put (INTC261014P00130000) interactive stock chart - Yahoo Finance UK</title>
            <link>https://news.google.com/rss/articles/456</link>
            <source url="https://uk.finance.yahoo.com">Yahoo Finance UK</source>
          </item>
          <item>
            <title>Intel rides AI boom to fastest revenue growth in almost 15 years, but shares sink - CNBC</title>
            <link>https://news.google.com/rss/articles/789</link>
            <source url="https://www.cnbc.com">CNBC</source>
          </item>
        </channel></rss>
        """.data(using: .utf8)!

        let articles = GoogleNewsRSSParser.parse(optionItemRSS)
        XCTAssertEqual(articles.count, 1, "Only real news article should be parsed, option quotes must be filtered")
        XCTAssertEqual(articles.first?.title, "Intel rides AI boom to fastest revenue growth in almost 15 years, but shares sink")
    }

    func testFiltersJapaneseQuoteAndForumSpam() {
        let jpSpamRSS = """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0"><channel>
          <item>
            <title>(NEXT FUNDS)日経平均高配当株50指数連動型ETF【1489】：株価・株式情報（夜間PTS含む） - Yahoo!ファイナンス</title>
            <link>https://finance.yahoo.co.jp/quote/1489.T</link>
            <source url="https://finance.yahoo.co.jp">Yahoo!ファイナンス</source>
          </item>
          <item>
            <title>(NEXT FUNDS)金融(除く銀行)上場投信【1632】：掲示板 - Yahoo!ファイナンス</title>
            <link>https://finance.yahoo.co.jp/quote/1632.T/forum</link>
            <source url="https://finance.yahoo.co.jp">Yahoo!ファイナンス</source>
          </item>
          <item>
            <title>トヨタ自動車、今期営業利益4兆円超へ 過去最高を更新 - 日本経済新聞</title>
            <link>https://news.google.com/rss/articles/789</link>
            <source url="https://www.nikkei.com">日本経済新聞</source>
          </item>
        </channel></rss>
        """.data(using: .utf8)!

        let articles = GoogleNewsRSSParser.parse(jpSpamRSS)
        XCTAssertEqual(articles.count, 1, "Only real Japanese news article should be parsed, quote and forum pages must be filtered")
        XCTAssertEqual(articles.first?.title, "トヨタ自動車、今期営業利益4兆円超へ 過去最高を更新")
    }

    func testFiltersNumericTickerFalseMatches() {
        // "焼きサンマ1万1489匹" should be rejected for 1489.T
        let falseMatchTitle = "焼きサンマ1万1489匹、ギネス認定 宮城・女川で8時間の挑戦"
        XCTAssertFalse(
            GoogleNewsRSSParser.isRelevantForNumericTicker(ticker: "1489.T", title: falseMatchTitle),
            "Quantity counter in Japanese (1万1489匹) must not be matched to 1489.T"
        )

        // Real news for 1489.T
        let realTitle = "ＮＥＸＴ ＦＵＮＤＳ 日経平均高配当株５０指数連動型上場投信[1489]：ETFの収益分配のお知らせ"
        XCTAssertTrue(
            GoogleNewsRSSParser.isRelevantForNumericTicker(ticker: "1489.T", title: realTitle),
            "Genuine financial ETF story must be accepted"
        )
    }

    func testNormalizedTitleKeyDeduplication() {
        let title1 = "焼きサンマ1万1489匹、ギネス認定 宮城・女川で8時間の挑戦 [宮城県]"
        let title2 = "焼きサンマ1万1489匹、ギネス認定 宮城・女川で8時間の挑戦（朝日新聞）"
        let title3 = "焼きサンマ1万1489匹、ギネス認定 宮城・女川で8時間の挑戦 - Yahoo!ニュース"

        let key1 = GoogleNewsRSSParser.normalizedTitleKey(title1)
        let key2 = GoogleNewsRSSParser.normalizedTitleKey(title2)
        let key3 = GoogleNewsRSSParser.normalizedTitleKey(title3)

        XCTAssertEqual(key1, key2)
        XCTAssertEqual(key2, key3)
    }

    @MainActor
    func testCollectPrioritizedSymbols() {
        let storage = StorageService()
        storage.portfolios = [
            Portfolio(name: "Test", holdings: [
                Holding(symbol: "NVDA", quantity: 10, avgPrice: 100),
                Holding(symbol: "AAPL", quantity: 5, avgPrice: 150)
            ])
        ]
        storage.watchlists = [
            Watchlist(name: "Favorite", symbols: ["FPT", "NVDA", "VIC"]),
            Watchlist(name: "Tech", symbols: ["MSFT", "AAPL", "GOOG"])
        ]

        let prioritized = StockService.collectPrioritizedSymbols(storageService: storage)

        // Portfolio holdings first
        XCTAssertEqual(Array(prioritized.prefix(2)), ["NVDA", "AAPL"])
        // First watchlist next (excluding duplicates already added)
        XCTAssertTrue(prioritized.contains("FPT"))
        XCTAssertTrue(prioritized.contains("VIC"))
        // Other watchlists next
        XCTAssertTrue(prioritized.contains("MSFT"))
        XCTAssertTrue(prioritized.contains("GOOG"))
        // Deduplicated
        XCTAssertEqual(prioritized.count, Set(prioritized.map { $0.uppercased() }).count)
    }

    func testNewsTranslationHelpers() {
        // Vietnamese text detection
        XCTAssertTrue(NewsTranslationService.isVietnameseText("Cổ phiếu VinFast tăng mạnh phiên đầu tuần"))
        XCTAssertTrue(NewsTranslationService.isVietnameseText("Thị trường chứng khoán hôm nay"))
        XCTAssertFalse(NewsTranslationService.isVietnameseText("Apple unveils new M4 chip with AI boost"))

        // Target language names
        XCTAssertEqual(NewsTranslationService.targetLanguageName(for: "vi"), "Vietnamese")
        XCTAssertEqual(NewsTranslationService.targetLanguageName(for: "ja"), "Japanese")
        XCTAssertEqual(NewsTranslationService.targetLanguageName(for: "en"), "English")

        // JSON Dictionary parsing for headlines
        let sampleDict = """
        ```json
        {
          "0": "Nvidia công bố chip AI mới",
          "1": "Cổ phiếu Apple lập đỉnh"
        }
        ```
        """
        let parsedDict = NewsTranslationService.parseJSONDictionary(from: sampleDict)
        XCTAssertEqual(parsedDict?["0"], "Nvidia công bố chip AI mới")
        XCTAssertEqual(parsedDict?["1"], "Cổ phiếu Apple lập đỉnh")

        // JSON Article parsing
        let sampleArticle = """
        {
          "title": "Nvidia dẫn đầu làn sóng AI",
          "paragraphs": [
            "Doanh thu quý 3 của Nvidia vượt dự báo.",
            "CEO Jensen Huang nhấn mạnh nhu cầu chip GPU vẫn rất lớn."
          ]
        }
        """
        let parsedArticle = NewsTranslationService.parseArticleJSON(from: sampleArticle)
        XCTAssertEqual(parsedArticle?.title, "Nvidia dẫn đầu làn sóng AI")
        XCTAssertEqual(parsedArticle?.paragraphs.count, 2)
    }

    @MainActor
    func testAutoTranslateNewsStoragePersistence() {
        let storage = StorageService()
        XCTAssertTrue(storage.autoTranslateNews, "Default autoTranslateNews must be true")

        storage.autoTranslateNews = false
        let exported = storage.exportAppData()
        XCTAssertEqual(exported.autoTranslateNews, false)

        let newStorage = StorageService()
        newStorage.applyAppData(exported)
        XCTAssertFalse(newStorage.autoTranslateNews)
    }
}
