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
          <title>Apple supplier warning - Reuters</title>
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
        XCTAssertEqual(a.title, "Apple hits new high after earnings beat - Yahoo Finance")
        XCTAssertEqual(a.publisher, "Yahoo Finance")
        XCTAssertEqual(a.link, "https://news.google.com/rss/articles/CBMi-test1?oc=5")
        XCTAssertEqual(a.publishTime, 1786468215)
        XCTAssertNil(a.thumbnailURL, "Google News RSS exposes no thumbnails")
        XCTAssertTrue(a.relatedTickers.isEmpty)
        XCTAssertNil(a.sourceSymbol, "sourceSymbol is not part of the feed; set by the fetcher")
        XCTAssertEqual(a.url?.scheme, "https")
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
}
