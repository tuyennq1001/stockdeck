import Foundation

/// Extracted article content representation for native reader mode.
public struct CrawledArticle: Sendable, Equatable {
    public let url: String
    public let title: String?
    public let leadImageURL: String?
    public let publisher: String?
    public let publishDate: Date?
    public let paragraphs: [String]
    public let canonicalURL: String?

    public init(
        url: String,
        title: String? = nil,
        leadImageURL: String? = nil,
        publisher: String? = nil,
        publishDate: Date? = nil,
        paragraphs: [String] = [],
        canonicalURL: String? = nil
    ) {
        self.url = url
        self.title = title
        self.leadImageURL = leadImageURL
        self.publisher = publisher
        self.publishDate = publishDate
        self.paragraphs = paragraphs
        self.canonicalURL = canonicalURL
    }
}

/// Service that fetches and parses news articles into a clean, lightweight Reader Mode structure.
/// Features in-memory caching and resilient HTML cleaning to avoid loading heavyweight web pages.
public actor ArticleCrawlerService {
    public static let shared = ArticleCrawlerService()

    private var cache: [String: CrawledArticle] = [:]
    private let session: URLSession

    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 6.0
            config.timeoutIntervalForResource = 10.0
            config.httpAdditionalHeaders = [
                "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
                "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
                "Accept-Language": "en-US,en;q=0.9,vi;q=0.8,ja;q=0.7"
            ]
            self.session = URLSession(configuration: config)
        }
    }

    /// Fetches article content from a web URL or Google News redirect URL.
    /// Returns cached content if already crawled in this session.
    public func fetchArticle(for urlString: String, fallbackTitle: String = "", fallbackPublisher: String = "") async -> CrawledArticle {
        let key = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            return CrawledArticle(url: urlString, title: fallbackTitle, publisher: fallbackPublisher)
        }

        if let cached = cache[key] {
            return cached
        }

        guard let url = URL(string: key) else {
            return CrawledArticle(url: key, title: fallbackTitle, publisher: fallbackPublisher)
        }

        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 6.0

            let (data, response) = try await session.data(for: request)
            let finalURL = (response as? HTTPURLResponse)?.url?.absoluteString ?? key

            let html = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1)
                ?? String(decoding: data, as: UTF8.self)

            let extracted = Self.parseHTML(
                html,
                sourceURL: key,
                finalURL: finalURL,
                fallbackTitle: fallbackTitle,
                fallbackPublisher: fallbackPublisher
            )

            cache[key] = extracted
            if finalURL != key {
                cache[finalURL] = extracted
            }
            return extracted
        } catch {
            let fallback = CrawledArticle(
                url: key,
                title: fallbackTitle.isEmpty ? nil : fallbackTitle,
                publisher: fallbackPublisher.isEmpty ? nil : fallbackPublisher
            )
            cache[key] = fallback
            return fallback
        }
    }

    /// Parses raw HTML into a structured `CrawledArticle`.
    public static func parseHTML(
        _ html: String,
        sourceURL: String,
        finalURL: String? = nil,
        fallbackTitle: String = "",
        fallbackPublisher: String = ""
    ) -> CrawledArticle {
        guard !html.isEmpty else {
            return CrawledArticle(url: sourceURL, title: fallbackTitle, publisher: fallbackPublisher)
        }

        let isGoogleNewsHost = sourceURL.contains("news.google.com") || (finalURL?.contains("news.google.com") ?? false)

        // 1. Extract og:image or twitter:image
        var leadImage = extractMetaContent(html: html, properties: ["og:image", "twitter:image", "twitter:image:src"])
        if let img = leadImage, (img.contains("googleusercontent.com") || img.contains("gstatic.com") || isGoogleNewsHost) {
            leadImage = nil
        }

        // 2. Extract og:title or <title>
        var title = extractMetaContent(html: html, properties: ["og:title", "twitter:title"])
        if title == nil || title?.isEmpty == true {
            title = extractTagContent(html: html, tagName: "title")
        }
        if let t = title {
            let clean = cleanText(t)
            if isGoogleNewsHost || clean.lowercased() == "google news" || clean.lowercased() == "google tin tức" {
                title = nil
            } else {
                title = clean
            }
        }
        let resolvedTitle = (title?.isEmpty == false ? title : nil) ?? (fallbackTitle.isEmpty ? nil : fallbackTitle)

        // 3. Extract og:site_name or publisher
        var publisher = extractMetaContent(html: html, properties: ["og:site_name", "twitter:site", "author"])
        if let p = publisher {
            let cleanPub = cleanText(p)
            if isGoogleNewsHost || cleanPub.lowercased() == "google news" || cleanPub.lowercased() == "google tin tức" {
                publisher = nil
            } else {
                publisher = cleanPub
            }
        }
        let resolvedPublisher = publisher ?? (fallbackPublisher.isEmpty ? nil : fallbackPublisher)

        // 4. Extract og:url or canonical
        let canonical = isGoogleNewsHost ? nil : (extractMetaContent(html: html, properties: ["og:url"])
            ?? extractLinkHref(html: html, rel: "canonical")
            ?? finalURL)

        // 5. Isolate main article body container & sanitize HTML
        var paragraphs: [String] = []
        var seenParagraphs = Set<String>()

        if !isGoogleNewsHost {
            let isolatedHTML = isolateArticleContainer(html)
            let sanitizedHTML = sanitizeHTML(isolatedHTML)

            // Match all <p> tags across the sanitized article body
            let pPattern = "<p[^>]*>([\\s\\S]*?)</p>"
            let rawParagraphs = matchRegex(html: sanitizedHTML, pattern: pPattern)

            for rawP in rawParagraphs {
                let cleanP = cleanText(rawP)
                if isValidParagraph(cleanP, articleTitle: resolvedTitle) && seenParagraphs.insert(cleanP).inserted {
                    paragraphs.append(cleanP)
                }
            }

            // If container isolation yielded too few paragraphs, fallback to scanning sanitized full document
            if paragraphs.isEmpty && isolatedHTML != html {
                let fullSanitized = sanitizeHTML(html)
                let fallbackRaw = matchRegex(html: fullSanitized, pattern: pPattern)
                for rawP in fallbackRaw {
                    let cleanP = cleanText(rawP)
                    if isValidParagraph(cleanP, articleTitle: resolvedTitle) && seenParagraphs.insert(cleanP).inserted {
                        paragraphs.append(cleanP)
                    }
                }
            }

            // If still no <p> tags met the threshold, fallback to meta description
            if paragraphs.isEmpty {
                let metaDesc = extractMetaContent(html: html, properties: ["og:description", "description", "twitter:description"])
                if let desc = metaDesc, !desc.isEmpty {
                    let cleanDesc = cleanText(desc)
                    if isValidParagraph(cleanDesc, articleTitle: resolvedTitle) {
                        paragraphs.append(cleanDesc)
                    }
                }
            }
        }

        return CrawledArticle(
            url: sourceURL,
            title: resolvedTitle,
            leadImageURL: leadImage,
            publisher: resolvedPublisher,
            publishDate: nil,
            paragraphs: paragraphs,
            canonicalURL: canonical
        )
    }

    // MARK: - HTML Extraction & Sanitization Helpers

    /// Isolates primary article container from full HTML page to prevent capturing site headers, menus, sidebars, or footers.
    private static func isolateArticleContainer(_ html: String) -> String {
        // Priority 1: Semantic <article>...</article>
        let articlePattern = "(?i)<article[^>]*>([\\s\\S]*?)</article>"
        if let match = matchFirstGroup(html: html, pattern: articlePattern), match.count >= 150 {
            return match
        }

        // Priority 2: Yahoo Finance caas-body or main content container
        let caasPattern = "(?i)<div[^>]+class=[\"'][^\"']*\\b(?:caas-body|caas-content|article-body|story-body|article__body|article-content|story-content|entry-content|post-content)\\b[^\"']*[\"'][^>]*>([\\s\\S]*?)(?:<footer|<div[^>]+class=[\"'][^\"']*\\b(?:caas-comments|comments|related|sidebar)\\b|$)"
        if let match = matchFirstGroup(html: html, pattern: caasPattern), match.count >= 150 {
            return match
        }

        // Priority 3: Semantic <main>...</main>
        let mainPattern = "(?i)<main[^>]*>([\\s\\S]*?)</main>"
        if let match = matchFirstGroup(html: html, pattern: mainPattern), match.count >= 150 {
            return match
        }

        return html
    }

    /// Strips non-content tags, accessibility skip links, bylines, tickers, and advertising DOM nodes.
    public static func sanitizeHTML(_ html: String) -> String {
        var res = html

        // 1. Remove non-content tags
        let tagsToRemove = [
            "script", "style", "nav", "header", "footer", "aside", "form",
            "noscript", "svg", "button", "figure", "figcaption", "iframe",
            "select", "option", "canvas", "dialog", "audio", "video"
        ]
        for tag in tagsToRemove {
            res = res.replacingOccurrences(
                of: "(?i)<\(tag)[^>]*>[\\s\\S]*?</\(tag)>",
                with: "",
                options: .regularExpression
            )
        }

        // 2. Remove role-based navigation / banner / complementary / alert containers
        let rolePattern = "(?i)<(?:div|section|aside|nav|header|footer|p|span|ul|ol)[^>]+role=[\"'](?:navigation|banner|contentinfo|complementary|dialog|alert|tooltip)[\"'][^>]*>[\\s\\S]*?</(?:div|section|aside|nav|header|footer|p|span|ul|ol)>"
        res = res.replacingOccurrences(of: rolePattern, with: "", options: .regularExpression)

        // 3. Remove known junk DOM containers by class/id (skip-links, bylines, tickers, social, ads, promos, comments)
        let junkClassKeywords = [
            "skip-link", "skip-nav", "a11y", "sr-only", "screen-reader",
            "caas-attr", "caas-byline", "caas-ticker", "caas-da-wrapper", "caas-share-buttons",
            "author-bio", "byline", "article-meta", "story-meta", "publish-date", "reading-time",
            "ticker-container", "market-summary", "quote-lookup", "stock-ticker",
            "social-share", "share-bar", "sharing-tools", "share-buttons", "social-links",
            "ad-container", "advertisement", "sponsored", "outbrain", "taboola", "promo-box",
            "newsletter-signup", "subscription-banner", "paywall-prompt",
            "related-articles", "read-next", "recommended-stories", "trending-articles",
            "comments-container", "disqus", "user-comments", "feedback-form"
        ]
        let junkClassPattern = "(?i)<(?:div|section|aside|header|footer|p|ul|ol)[^>]+(?:class|id)=[\"'][^\"']*\\b(?:" + junkClassKeywords.joined(separator: "|") + ")\\b[^\"']*[\"'][^>]*>[\\s\\S]*?</(?:div|section|aside|header|footer|p|ul|ol)>"
        res = res.replacingOccurrences(of: junkClassPattern, with: "", options: .regularExpression)

        return res
    }

    private static func extractMetaContent(html: String, properties: [String]) -> String? {
        for prop in properties {
            // Match double-quoted: <meta ... property="og:title" ... content="..." ...>
            let p1 = "(?i)<meta[^>]+(?:property|name)=[\"']\(prop)[\"'][^>]+content=\"([^\"]*)\""
            if let match = matchFirstGroup(html: html, pattern: p1) {
                return decodeHTMLEntities(match)
            }
            // Match single-quoted: <meta ... property='og:title' ... content='...' ...>
            let p2 = "(?i)<meta[^>]+(?:property|name)=[\"']\(prop)[\"'][^>]+content='([^']*)'"
            if let match = matchFirstGroup(html: html, pattern: p2) {
                return decodeHTMLEntities(match)
            }
            // Match <meta ... content="..." ... property="og:title" ...>
            let p3 = "(?i)<meta[^>]+content=\"([^\"]*)\"[^>]+(?:property|name)=[\"']\(prop)[\"']"
            if let match = matchFirstGroup(html: html, pattern: p3) {
                return decodeHTMLEntities(match)
            }
            // Match <meta ... content='...' ... property='og:title' ...>
            let p4 = "(?i)<meta[^>]+content='([^']*)'[^>]+(?:property|name)=[\"']\(prop)[\"']"
            if let match = matchFirstGroup(html: html, pattern: p4) {
                return decodeHTMLEntities(match)
            }
        }
        return nil
    }

    private static func extractTagContent(html: String, tagName: String) -> String? {
        let pattern = "(?i)<\(tagName)[^>]*>([\\s\\S]*?)</\(tagName)>"
        if let match = matchFirstGroup(html: html, pattern: pattern) {
            return decodeHTMLEntities(match)
        }
        return nil
    }

    private static func extractLinkHref(html: String, rel: String) -> String? {
        let p1 = "(?i)<link[^>]+rel=[\"']\(rel)[\"'][^>]+href=\"([^\"]*)\""
        if let match = matchFirstGroup(html: html, pattern: p1) { return match }
        let p2 = "(?i)<link[^>]+rel=[\"']\(rel)[\"'][^>]+href='([^']*)'"
        if let match = matchFirstGroup(html: html, pattern: p2) { return match }
        return nil
    }

    private static func matchFirstGroup(html: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        if let match = regex.firstMatch(in: html, options: [], range: range), match.numberOfRanges > 1 {
            if let groupRange = Range(match.range(at: 1), in: html) {
                return String(html[groupRange])
            }
        }
        return nil
    }

    private static func matchRegex(html: String, pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        let matches = regex.matches(in: html, options: [], range: range)
        return matches.compactMap { match in
            if match.numberOfRanges > 1, let groupRange = Range(match.range(at: 1), in: html) {
                return String(html[groupRange])
            }
            return nil
        }
    }

    /// Strips HTML tags and decodes entities.
    public static func cleanText(_ text: String) -> String {
        guard !text.isEmpty else { return "" }
        var res = text
        // Remove nested HTML tags
        res = res.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        res = decodeHTMLEntities(res)
        // Normalize whitespaces
        let parts = res.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        return parts.joined(separator: " ")
    }

    /// Decodes HTML entities including named and numerical character references.
    public static func decodeHTMLEntities(_ str: String) -> String {
        guard !str.isEmpty else { return "" }
        var text = str
        let entities = [
            ("&quot;", "\""),
            ("&apos;", "'"),
            ("&#39;", "'"),
            ("&lt;", "<"),
            ("&gt;", ">"),
            ("&amp;", "&"),
            ("&nbsp;", " "),
            ("&#160;", " "),
            ("&mdash;", "—"),
            ("&ndash;", "–"),
            ("&hellip;", "…"),
            ("&bull;", "•"),
            ("&rsquo;", "'"),
            ("&lsquo;", "'"),
            ("&rdquo;", "\""),
            ("&ldquo;", "\""),
            ("&yen;", "¥"),
            ("&euro;", "€"),
            ("&pound;", "£"),
            ("&copy;", "©"),
            ("&reg;", "®"),
            ("&trade;", "™"),
            ("&plusmn;", "±"),
            ("&times;", "×"),
            ("&divide;", "÷")
        ]
        for (ent, rep) in entities {
            text = text.replacingOccurrences(of: ent, with: rep)
        }

        // Numeric entity decoding &#123; and &#x1f;
        let regex = try? NSRegularExpression(pattern: "&#(x?[0-9a-fA-F]+);", options: [])
        if let regex {
            let nsString = text as NSString
            let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: nsString.length))
            for match in matches.reversed() {
                if let codeRange = Range(match.range(at: 1), in: text) {
                    let codeStr = String(text[codeRange])
                    let code: UInt32?
                    if codeStr.lowercased().hasPrefix("x") {
                        code = UInt32(codeStr.dropFirst(), radix: 16)
                    } else {
                        code = UInt32(codeStr, radix: 10)
                    }
                    if let code, let scalar = UnicodeScalar(code) {
                        let replacement = String(Character(scalar))
                        text = (text as NSString).replacingCharacters(in: match.range, with: replacement)
                    }
                }
            }
        }
        return text
    }

    /// Evaluates if a text paragraph is substantive news content rather than boilerplate, ads, skip-links, or metadata.
    public static func isValidParagraph(_ text: String, articleTitle: String? = nil) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 25 else { return false }
        return !isBoilerplate(trimmed, articleTitle: articleTitle)
    }

    /// Detects boilerplate, ads, skip navigation links, author/byline/ticker dumps, and financial promotional widgets.
    public static func isBoilerplate(_ text: String, articleTitle: String? = nil) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        let lower = trimmed.lowercased()

        // 1. Accessibility / Skip navigation
        if lower.contains("skip to navigation") ||
           lower.contains("skip to main content") ||
           lower.contains("skip to right column") ||
           lower.contains("skip to content") ||
           lower.contains("skip to primary navigation") ||
           lower.hasPrefix("skip to ") {
            return true
        }

        // 2. Syndication / Attribution headers & footers
        if lower.contains("this article first appeared on") ||
           lower.contains("originally published on") ||
           lower.contains("this story was originally published") ||
           lower.contains("this post appeared first on") ||
           lower.contains("reprinted with permission") ||
           lower.contains("reposted with permission") ||
           lower.contains("first published on") {
            return true
        }

        // 3. Financial promo widgets & warning sign ads
        // GuruFocus
        if (lower.contains("warning!") && lower.contains("warning signs")) ||
           lower.contains("warning signs with") ||
           (lower.contains("has detected") && lower.contains("warning signs")) ||
           lower.contains("test your thesis with our free dcf calculator") ||
           lower.contains("free dcf calculator") ||
           lower.contains("is fairly valued? test your thesis") ||
           lower.contains("fairly valued? test your thesis") ||
           lower.contains("gurufocus has detected") ||
           lower.contains("view gurufocus portfolio") {
            return true
        }

        // Zacks
        if lower.contains("zacks investment research") ||
           lower.contains("7 best stocks for the next 30 days") ||
           lower.contains("zacks rank") ||
           lower.contains("free report from zacks") {
            return true
        }

        // Motley Fool & Disclosures
        if lower.contains("the motley fool has a disclosure policy") ||
           lower.contains("the motley fool has positions in") ||
           lower.contains("recommends the following options") ||
           lower.contains("holds no position in any of the stocks mentioned") ||
           lower.contains("the author has no position in") ||
           lower.contains("the author owns shares in") ||
           lower.contains("the author holds shares in") ||
           lower.contains("has a position in any stock mentioned") {
            return true
        }

        // 4. Byline / Timestamp / Read duration / Ticker quotes composite line
        // E.g.: "Apple Makes Costly Move Subscribers Won't Miss Moz Farooque ACCA Sat, August 29, 2026 at 7:24 AM GMT+9 2 min read AAPL +1.63% NVDA -4.57% This article first appeared on GuruFocus ."
        if lower.contains("min read") && (
            lower.contains("gmt") || lower.contains("est") || lower.contains("edt") ||
            lower.contains("pst") || lower.contains("pdt") || lower.contains("utc") ||
            lower.contains("am ") || lower.contains("pm ") || lower.contains("202")
        ) {
            return true
        }

        // Paragraph matching title + extra metadata
        if let title = articleTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            let cleanTitleLower = title.lowercased()
            if lower == cleanTitleLower || (lower.contains(cleanTitleLower) && lower.count < cleanTitleLower.count + 80) {
                if lower.contains("min read") || lower.contains("by ") || lower.contains("published") || lower.contains("+") || lower.contains("%") {
                    return true
                }
            }
        }

        // 5. Calls to action (CTAs) & Newsletters
        if lower.contains("sign up for our newsletter") ||
           lower.contains("sign up for our free newsletter") ||
           lower.contains("subscribe to our newsletter") ||
           lower.contains("subscribe to unlock") ||
           lower.contains("subscribe to read the full") ||
           lower.contains("click here to download") ||
           lower.contains("click here to see") ||
           lower.contains("click here to read") ||
           lower.contains("click here to join") ||
           lower.contains("click here for more") ||
           lower.contains("download our free report") ||
           lower.contains("get our top stock picks") ||
           lower.contains("register for free") ||
           lower.contains("join premium today") ||
           lower.contains("try it free for 30 days") {
            return true
        }

        // 6. Social sharing & follow prompts
        if lower.hasPrefix("follow us on ") ||
           lower.hasPrefix("share this article") ||
           lower.hasPrefix("share on ") ||
           lower.contains("follow us on twitter") ||
           lower.contains("follow us on x") ||
           lower.contains("follow us on facebook") ||
           lower.contains("follow us on linkedin") {
            return true
        }

        // 7. Navigation / Related articles headings
        if lower.hasPrefix("read next:") ||
           lower.hasPrefix("read more:") ||
           lower.hasPrefix("related stories:") ||
           lower.hasPrefix("related articles:") ||
           lower.hasPrefix("see also:") ||
           lower.hasPrefix("trending:") ||
           lower.hasPrefix("editor's pick:") ||
           lower.hasPrefix("don't miss:") ||
           lower.hasPrefix("top stories:") ||
           lower.hasPrefix("what to read next:") {
            return true
        }

        // 8. Image & Photo Credits
        if (lower.hasPrefix("photo by ") && lower.contains("on unsplash")) ||
           lower.hasPrefix("image source:") ||
           lower.hasPrefix("image credit:") ||
           lower.hasPrefix("photo credit:") ||
           lower.hasPrefix("photo:") ||
           lower.hasPrefix("source: ap") ||
           lower.hasPrefix("source: reuters") ||
           lower.hasPrefix("source: bloomberg") ||
           lower.hasPrefix("source: getty") {
            return true
        }

        // 9. Legal & Cookie Boilerplate
        let triggers = [
            "cookie policy", "privacy policy", "terms of use", "terms and conditions",
            "all rights reserved", "advertisement", "sponsored content", "sponsored post",
            "for educational purposes only", "not financial advice",
            "past performance is no guarantee of future results",
            "all contents ©", "copyright ©", "reuters news agency. all rights reserved",
            "the views and opinions expressed herein are the views and opinions of the author"
        ]
        if triggers.contains(where: { lower.contains($0) }) {
            return true
        }

        // 10. Disclaimers
        if lower.hasPrefix("disclaimer:") ||
           lower.hasPrefix("disclosures:") ||
           lower.hasPrefix("editorial disclosure:") ||
           lower.hasPrefix("advertiser disclosure:") ||
           lower.hasPrefix("disclosure:") {
            return true
        }

        return false
    }
}
