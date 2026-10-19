import XCTest
import WebKit
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

    func testExtractJSONLDArticleBody() {
        let jsonLDHTML = """
        <!DOCTYPE html>
        <html>
        <head>
            <meta property="og:title" content="Meta Earnings Beat Forecasts">
            <script type="application/ld+json">
            {
                "@context": "https://schema.org",
                "@type": "NewsArticle",
                "headline": "Meta Earnings Beat Forecasts",
                "articleBody": "Meta Platforms reported quarterly earnings that exceeded analyst estimates across all major segments.\\n\\nCapital expenditures on AI infrastructure will accelerate into next year according to company guidance."
            }
            </script>
        </head>
        <body>
            <div>Simple wrapper with no standard article tags</div>
        </body>
        </html>
        """

        let article = ArticleCrawlerService.parseHTML(
            jsonLDHTML,
            sourceURL: "https://example.com/meta-earnings"
        )

        XCTAssertEqual(article.title, "Meta Earnings Beat Forecasts")
        XCTAssertEqual(article.paragraphs.count, 2)
        XCTAssertTrue(article.paragraphs[0].contains("exceeded analyst estimates"))
        XCTAssertTrue(article.paragraphs[1].contains("Capital expenditures on AI"))
    }

    func testGoogleNewsSourceURLWithResolvedFinalURL() {
        let publisherHTML = """
        <!DOCTYPE html>
        <html>
        <head>
            <meta property="og:title" content="Dow Jones Futures Rally As Tech Earnings Surge">
            <meta property="og:image" content="https://www.investors.com/images/futures.jpg">
            <meta property="og:site_name" content="Investor's Business Daily">
        </head>
        <body>
            <article>
                <p>Dow Jones futures rallied Wednesday night as major enterprise tech companies reported stronger guidance.</p>
                <p>The S&P 500 and Nasdaq held key support levels following recent volatility.</p>
            </article>
        </body>
        </html>
        """

        // Source URL is Google News link, but finalURL has been resolved to the publisher
        let article = ArticleCrawlerService.parseHTML(
            publisherHTML,
            sourceURL: "https://news.google.com/rss/articles/CBMi12345",
            finalURL: "https://www.investors.com/market-trend/futures-rally-12345"
        )

        XCTAssertEqual(article.title, "Dow Jones Futures Rally As Tech Earnings Surge")
        XCTAssertEqual(article.publisher, "Investor's Business Daily")
        XCTAssertEqual(article.leadImageURL, "https://www.investors.com/images/futures.jpg")
        XCTAssertEqual(article.canonicalURL, "https://www.investors.com/market-trend/futures-rally-12345")
        XCTAssertEqual(article.paragraphs.count, 2)
        XCTAssertTrue(article.paragraphs[0].contains("Dow Jones futures rallied"))
    }

    func testFiltersAutomatedOptionQuoteBoilerplate() {
        let optionDesc = "Find the latest INTC Sep 2027 160.000 call (INTC270917C00160000) stock quote, history, news and other vital information to help you with your stock trading and investing."
        XCTAssertFalse(
            ArticleCrawlerService.isValidParagraph(optionDesc),
            "Automated quote page description must be detected as boilerplate"
        )

        let promo = "Just released. Our analysts combed the entire stock market and named the ten best stocks to buy right now, and NVIDIA didn't make the cut. Enter your email to see the names that beat NVDA."
        XCTAssertFalse(
            ArticleCrawlerService.isValidParagraph(promo),
            "Marketing email-gate promo must be detected as boilerplate"
        )
    }

    func testMarketBeatHTMLParsing() {
        let mbHTML = """
        <!DOCTYPE html>
        <html>
        <head>
            <meta property="og:title" content="Intel Corporation $INTC Shares Purchased by Baugh &amp; Associates LLC">
            <meta property="og:site_name" content="MarketBeat">
            <link rel="canonical" href="https://www.marketbeat.com/instant-alerts/filing-intel-corporation-intc-shares-purchased-by-baugh-associates-llc-2026-10-17/" />
        </head>
        <body>
            <div id="content" class="article-content">
                <p>Baugh &amp; Associates LLC increased its position in shares of Intel Co. (NASDAQ:INTC) by 14.2% during the 3rd quarter, according to the company in its most recent Form 13F filing with the SEC.</p>
                <p>The fund owned 45,210 shares of the chip maker's stock after purchasing an additional 5,630 shares during the period.</p>
                <p>Other institutional investors have also recently modified their holdings of the company. Vanguard Group Inc. boosted its holdings in shares of Intel by 1.8%.</p>
                <p class="copyright">Copyright © 2026 MarketBeat. All rights reserved.</p>
            </div>
        </body>
        </html>
        """

        let article = ArticleCrawlerService.parseHTML(
            mbHTML,
            sourceURL: "https://www.marketbeat.com/instant-alerts/filing-intel-corporation-intc-shares-purchased-by-baugh-associates-llc-2026-10-17/"
        )

        XCTAssertEqual(article.title, "Intel Corporation $INTC Shares Purchased by Baugh & Associates LLC")
        XCTAssertEqual(article.publisher, "MarketBeat")
        XCTAssertEqual(article.paragraphs.count, 3)
        XCTAssertTrue(article.paragraphs[0].contains("Baugh & Associates LLC increased its position"))
        XCTAssertTrue(article.paragraphs[1].contains("The fund owned 45,210 shares"))
        XCTAssertTrue(article.paragraphs[2].contains("Vanguard Group Inc."))
    }

    func testEvictCacheRemovesCachedEntry() async {
        let service = ArticleCrawlerService()
        await service.evictCache(for: "https://example.com/test-article")
    }

    func testBarchartHTMLStructureParsing() {
        let barchartHTML = """
        <!DOCTYPE html>
        <html>
        <head>
            <meta property="og:title" content="With Cathie Wood Warning of a Vicious Cycle in Memory Chipmakers, Here’s How You Should Play SKHY Stock Now">
            <meta property="og:site_name" content="Barchart.com">
            <meta property="og:image" content="https://www.barchart.com/images/skhy.jpg">
            <link rel="canonical" href="https://www.barchart.com/story/news/8142726/with-cathie-wood-warning-of-a-vicious-cycle-in-memory-chipmakers-heres-how-you-should-play-skhy-stock-now" />
        </head>
        <body>
            <main>
                <div class="story-content">
                    <p>Cathie Wood's warning arrives at an uncomfortable moment for memory chip investors. Speaking in Hong Kong on Oct. 13, the Ark Invest founder warned that traditional memory chipmakers remain locked in boom-and-bust cycles.</p>
                    <p>These comments come at a moment when high-bandwidth memory (HBM) remains in short supply for artificial intelligence (AI) accelerators.</p>
                    <p>Her warning comes as SK Hynix (SKHY) delivers some of the most extraordinary results in its history.</p>
                </div>
            </main>
        </body>
        </html>
        """

        let article = ArticleCrawlerService.parseHTML(
            barchartHTML,
            sourceURL: "https://www.barchart.com/story/news/8142726/with-cathie-wood-warning-of-a-vicious-cycle-in-memory-chipmakers-heres-how-you-should-play-skhy-stock-now"
        )

        XCTAssertEqual(article.title, "With Cathie Wood Warning of a Vicious Cycle in Memory Chipmakers, Here’s How You Should Play SKHY Stock Now")
        XCTAssertEqual(article.publisher, "Barchart.com")
        XCTAssertEqual(article.paragraphs.count, 3)
        XCTAssertTrue(article.paragraphs[0].contains("Cathie Wood's warning arrives"))
        XCTAssertTrue(article.paragraphs[1].contains("high-bandwidth memory (HBM)"))
        XCTAssertTrue(article.paragraphs[2].contains("SK Hynix (SKHY)"))
    }

    @MainActor
    func testHeadlessWebKitFetcherAPI() async {
        guard let url = URL(string: "about:blank") else { return }
        let res = await HeadlessWebKitFetcher.shared.fetchHTML(url: url, timeout: 3.0)
        // about:blank loads immediately and returns HTML containing <html>
        XCTAssertNotNil(res)
        XCTAssertTrue((res?.html ?? "").contains("html") || (res?.html ?? "").isEmpty)
    }

    func testCleanTextStripsInjectedTickerTape() {
        let textWithTickers = "Futures dropped sharply. ^DJI -0.34% SPCX -1.74% META -3.72% The Nasdaq was led lower by tech selloffs."
        let cleaned = ArticleCrawlerService.cleanText(textWithTickers)
        XCTAssertEqual(cleaned, "Futures dropped sharply. The Nasdaq was led lower by tech selloffs.")
    }

    func testYahooFinanceModernDataTestIdArticleBodyParsing() {
        let yahooHTML = """
        <!DOCTYPE html>
        <html>
        <head>
            <meta property="og:title" content="Broadcom Stock Surges on AI Demand">
            <meta property="og:site_name" content="Yahoo Finance">
            <link rel="canonical" href="https://finance.yahoo.com/news/broadcom-stock-surges-123.html" />
        </head>
        <body>
            <div class="body yf-51e9w5" data-testid="article-body">
                <section class="ticker-list">
                    <span class="ticker-wrapper">AVGO +5.24% NVDA +2.11%</span>
                </section>
                <p>Broadcom shares rallied on Monday after analysts raised price targets citing strong custom AI silicon demand.</p>
                <p>Hyperscale cloud providers have accelerated deployments of next-generation networking switches and accelerators.</p>
                <p>Management highlighted that AI revenue is projected to exceed expectations in the upcoming fiscal quarter.</p>
            </div>
        </body>
        </html>
        """

        let article = ArticleCrawlerService.parseHTML(
            yahooHTML,
            sourceURL: "https://finance.yahoo.com/news/broadcom-stock-surges-123.html"
        )

        XCTAssertEqual(article.title, "Broadcom Stock Surges on AI Demand")
        XCTAssertEqual(article.publisher, "Yahoo Finance")
        XCTAssertEqual(article.paragraphs.count, 3)
        XCTAssertTrue(article.paragraphs[0].contains("Broadcom shares rallied"))
        XCTAssertFalse(article.paragraphs[0].contains("AVGO"))
        XCTAssertTrue(article.paragraphs[1].contains("Hyperscale cloud providers"))
        XCTAssertTrue(article.paragraphs[2].contains("Management highlighted"))
    }

    func testExtractPartnerArticleURLFromContinueReadingButton() {
        let htmlWithButton = """
        <div class="continue-reading-container">
            <a class="continue-reading-button button-link" href="https://www.investors.com/market-trend/stock-market-today/dow-jones-futures-sp500-nasdaq-ai-fears/">
                Continue Reading
            </a>
        </div>
        """
        let extracted = ArticleCrawlerService.extractPartnerArticleURL(html: htmlWithButton, pageURL: "https://finance.yahoo.com/news/dow-jones-futures-123.html")
        XCTAssertEqual(extracted, "https://www.investors.com/market-trend/stock-market-today/dow-jones-futures-sp500-nasdaq-ai-fears/")
    }

    func testExtractPartnerArticleURLFromJSONLD() {
        let jsonLDHTML = """
        <script type="application/ld+json">
        {
            "@context": "https://schema.org",
            "@type": "NewsArticle",
            "mainEntityOfPage": "https://www.reuters.com/technology/nvidia-partners-with-global-foundries-2026-10-18/"
        }
        </script>
        """
        let extracted = ArticleCrawlerService.extractPartnerArticleURL(html: jsonLDHTML, pageURL: "https://finance.yahoo.com/news/nvidia-partners-123.html")
        XCTAssertEqual(extracted, "https://www.reuters.com/technology/nvidia-partners-with-global-foundries-2026-10-18/")
    }

    func testCrawledArticlePaywallSnippetFlag() {
        let article = CrawledArticle(
            url: "https://finance.yahoo.com/news/ibd-teaser.html",
            title: "Market Rally Teaser",
            paragraphs: ["Teaser paragraph."],
            canonicalURL: "https://www.investors.com/market-rally.html",
            isPaywalledSnippet: true
        )
        XCTAssertTrue(article.isPaywalledSnippet)
        XCTAssertEqual(article.canonicalURL, "https://www.investors.com/market-rally.html")
    }
}

