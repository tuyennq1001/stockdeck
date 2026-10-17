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
}
