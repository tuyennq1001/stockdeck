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

    func testParseYahooFinanceArticleWithGuruFocusPromosAndSkipLinks() {
        let yahooFinanceHTML = """
        <!DOCTYPE html>
        <html>
        <head>
            <title>Apple Makes Costly Move Subscribers Won't Miss - Yahoo Finance</title>
            <meta property="og:title" content="Apple Makes Costly Move Subscribers Won't Miss">
            <meta property="og:site_name" content="Yahoo Finance">
            <meta property="og:image" content="https://media.zenfs.com/apple-tv-prices.jpg">
        </head>
        <body>
            <div class="skip-links">
                <a href="#nav">Skip to navigation</a>
                <a href="#main">Skip to main content</a>
                <a href="#right">Skip to right column</a>
            </div>
            <header>
                <div class="search-bar">Search Yahoo Finance</div>
            </header>
            <div class="caas-body">
                <div class="caas-attr">
                    <p>Apple Makes Costly Move Subscribers Won't Miss Moz Farooque ACCA Sat, August 29, 2026 at 7:24 AM GMT+9 2 min read AAPL +1.63% NVDA -4.57% This article first appeared on GuruFocus .</p>
                </div>
                <div class="caas-content">
                    <p>Apple ( NASDAQ:AAPL ) is raising Apple TV subscription prices again, testing how much more consumers will pay as streaming companies increasingly prioritize revenue and profitability over subscriber growth. The monthly U.S. price rises to $14.99 from $12.99 , while the annual plan climbs to $119 from $99 , reinforcing an industrywide shift toward stronger pricing power.</p>
                    <p>Warning! GuruFocus has detected 4 Warning Signs with NVDA.</p>
                    <p>Is NVDA fairly valued? Test your thesis with our free DCF calculator.</p>
                    <p>The new prices take effect Friday for new and existing subscribers across all major international markets.</p>
                    <p>Disclosure: The Motley Fool has positions in and recommends AAPL.</p>
                    <p>Sign up for our free newsletter to get daily market alerts.</p>
                    <p>Read Next: Top 5 tech stocks to watch this earnings season.</p>
                </div>
            </div>
            <footer>
                <p>Copyright © 2026 Yahoo Inc. All rights reserved. Cookie policy.</p>
            </footer>
        </body>
        </html>
        """

        let article = ArticleCrawlerService.parseHTML(
            yahooFinanceHTML,
            sourceURL: "https://finance.yahoo.com/news/apple-makes-costly-move-12345.html",
            fallbackTitle: "Apple Makes Costly Move Subscribers Won't Miss",
            fallbackPublisher: "Yahoo Finance"
        )

        XCTAssertEqual(article.title, "Apple Makes Costly Move Subscribers Won't Miss")
        XCTAssertEqual(article.leadImageURL, "https://media.zenfs.com/apple-tv-prices.jpg")
        XCTAssertEqual(article.paragraphs.count, 2)
        XCTAssertTrue(article.paragraphs[0].contains("raising Apple TV subscription prices again"))
        XCTAssertTrue(article.paragraphs[1].contains("The new prices take effect Friday"))

        // Ensure all junk elements were cleanly stripped
        for para in article.paragraphs {
            XCTAssertFalse(para.contains("Skip to navigation"))
            XCTAssertFalse(para.contains("Moz Farooque ACCA"))
            XCTAssertFalse(para.contains("2 min read"))
            XCTAssertFalse(para.contains("AAPL +1.63%"))
            XCTAssertFalse(para.contains("This article first appeared on GuruFocus"))
            XCTAssertFalse(para.contains("Warning Signs"))
            XCTAssertFalse(para.contains("DCF calculator"))
            XCTAssertFalse(para.contains("Motley Fool"))
            XCTAssertFalse(para.contains("Sign up for our free newsletter"))
            XCTAssertFalse(para.contains("Read Next:"))
            XCTAssertFalse(para.contains("Cookie policy"))
        }
    }

    func testIsBoilerplateFiltersAllCommonJunkPatterns() {
        XCTAssertTrue(ArticleCrawlerService.isBoilerplate("Skip to navigation Skip to main content"))
        XCTAssertTrue(ArticleCrawlerService.isBoilerplate("Warning! GuruFocus has detected 4 Warning Signs with NVDA."))
        XCTAssertTrue(ArticleCrawlerService.isBoilerplate("Is NVDA fairly valued? Test your thesis with our free DCF calculator."))
        XCTAssertTrue(ArticleCrawlerService.isBoilerplate("Want the latest recommendations from Zacks Investment Research? Today, you can download 7 Best Stocks for the Next 30 Days."))
        XCTAssertTrue(ArticleCrawlerService.isBoilerplate("The Motley Fool has a disclosure policy and holds no position in any of the stocks mentioned."))
        XCTAssertTrue(ArticleCrawlerService.isBoilerplate("This article first appeared on GuruFocus ."))
        XCTAssertTrue(ArticleCrawlerService.isBoilerplate("Sign up for our free newsletter to get daily market alerts."))
        XCTAssertTrue(ArticleCrawlerService.isBoilerplate("Read Next: 3 Stocks Warren Buffett Is Buying"))
        XCTAssertTrue(ArticleCrawlerService.isBoilerplate("Photo by John Doe on Unsplash"))
        XCTAssertTrue(ArticleCrawlerService.isBoilerplate("All rights reserved. Terms of use and Privacy policy apply."))

        // Substantive news text should NOT be flagged as boilerplate
        XCTAssertFalse(ArticleCrawlerService.isBoilerplate("Apple Inc. reported fourth-quarter revenue of $94.9 billion, up 6% year-over-year."))
    }
}
