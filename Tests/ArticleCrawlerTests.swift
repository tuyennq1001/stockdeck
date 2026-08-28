import XCTest
@testable import StockDeck

final class ArticleCrawlerTests: XCTestCase {

    func testParseHTMLWithOpenGraphMeta() {
        let sampleHTML = """
        <!DOCTYPE html>
        <html>
        <head>
            <title>Ignored Raw Title - Publisher Name</title>
            <meta property="og:title" content="Apple Unveils M4 Chip with Incredible AI Power">
            <meta property="og:image" content="https://example.com/images/apple-m4.jpg">
            <meta property="og:site_name" content="TechCrunch">
            <meta property="og:description" content="Apple today introduced the brand new M4 chip featuring powerful neural accelerators.">
            <link rel="canonical" href="https://techcrunch.com/2026/08/apple-m4-chip">
        </head>
        <body>
            <nav><a href="/">Home</a></nav>
            <article>
                <p>Apple today introduced the brand new M4 chip featuring powerful neural accelerators designed for AI workloads.</p>
                <p>The new chip delivers up to 50% faster CPU performance compared to the previous generation.</p>
                <p>Cookie policy: We use cookies to improve user experience.</p>
                <p>Developers will be able to take advantage of the expanded unified memory architecture starting next month.</p>
            </article>
            <footer><p>Copyright 2026 TechCrunch. All rights reserved.</p></footer>
        </body>
        </html>
        """

        let article = ArticleCrawlerService.parseHTML(
            sampleHTML,
            sourceURL: "https://techcrunch.com/2026/08/apple-m4-chip",
            fallbackTitle: "Fallback Title",
            fallbackPublisher: "Fallback Pub"
        )

        XCTAssertEqual(article.title, "Apple Unveils M4 Chip with Incredible AI Power")
        XCTAssertEqual(article.leadImageURL, "https://example.com/images/apple-m4.jpg")
        XCTAssertEqual(article.publisher, "TechCrunch")
        XCTAssertEqual(article.canonicalURL, "https://techcrunch.com/2026/08/apple-m4-chip")
        XCTAssertEqual(article.paragraphs.count, 3)
        XCTAssertEqual(article.paragraphs[0], "Apple today introduced the brand new M4 chip featuring powerful neural accelerators designed for AI workloads.")
        XCTAssertEqual(article.paragraphs[1], "The new chip delivers up to 50% faster CPU performance compared to the previous generation.")
        XCTAssertEqual(article.paragraphs[2], "Developers will be able to take advantage of the expanded unified memory architecture starting next month.")
    }

    func testCleanHTMLEntities() {
        let raw = "Stocks rally &amp; surge &#39;higher&#39; &quot;across&quot; Wall St &mdash; tech leads &#x24;"
        let cleaned = ArticleCrawlerService.cleanText(raw)
        XCTAssertEqual(cleaned, "Stocks rally & surge 'higher' \"across\" Wall St — tech leads $")
    }

    func testFallbackToMetaDescriptionWhenNoParagraphs() {
        let sampleHTML = """
        <html>
        <head>
            <meta property="og:title" content="Short News Bite">
            <meta property="og:description" content="A concise summary of breaking market movements this afternoon.">
        </head>
        <body>
            <div>Short div</div>
        </body>
        </html>
        """

        let article = ArticleCrawlerService.parseHTML(
            sampleHTML,
            sourceURL: "https://example.com/short"
        )

        XCTAssertEqual(article.title, "Short News Bite")
        XCTAssertEqual(article.paragraphs.count, 1)
        XCTAssertEqual(article.paragraphs.first, "A concise summary of breaking market movements this afternoon.")
    }

    func testFiltersGoogleNewsWrapperPlaceholder() {
        let googleNewsHTML = """
        <html>
        <head>
            <meta property="og:title" content="Google News">
            <meta property="og:image" content="https://lh3.googleusercontent.com/J6_coFbogxhRI9iM86wEHioJ0ubO2QGeWwpqG">
            <meta property="og:site_name" content="Google News">
        </head>
        <body>
            <p>Comprehensive up-to-date news coverage, aggregated from sources all over the world by Google News.</p>
        </body>
        </html>
        """

        let article = ArticleCrawlerService.parseHTML(
            googleNewsHTML,
            sourceURL: "https://news.google.com/rss/articles/CBMi12345",
            fallbackTitle: "Apple Stock Breaks New Record",
            fallbackPublisher: "Yahoo Finance"
        )

        XCTAssertEqual(article.title, "Apple Stock Breaks New Record")
        XCTAssertEqual(article.publisher, "Yahoo Finance")
        XCTAssertNil(article.leadImageURL)
        XCTAssertTrue(article.paragraphs.isEmpty)
    }
}
