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

        // 5. Clean HTML for body text extraction: remove scripts, styles, header, nav, footer, aside, forms
        var cleanedHTML = html
        let tagsToRemove = ["script", "style", "nav", "header", "footer", "aside", "form", "noscript", "svg", "button", "figure", "iframe"]
        for tag in tagsToRemove {
            cleanedHTML = cleanedHTML.replacingOccurrences(
                of: "<\(tag)[^>]*>[\\s\\S]*?</\(tag)>",
                with: "",
                options: .regularExpression
            )
        }

        // 6. Extract paragraphs from cleaned HTML
        var paragraphs: [String] = []
        var seenParagraphs = Set<String>()

        if !isGoogleNewsHost {
            // Match all <p> tags across the entire page body
            let pPattern = "<p[^>]*>([\\s\\S]*?)</p>"
            let rawParagraphs = matchRegex(html: cleanedHTML, pattern: pPattern)

            for rawP in rawParagraphs {
                let cleanP = cleanText(rawP)
                // Filter out boilerplate, short noise, cookie banners, and deduplicate
                if cleanP.count >= 35 && !isBoilerplate(cleanP) && seenParagraphs.insert(cleanP).inserted {
                    paragraphs.append(cleanP)
                }
            }

            // If no <p> tags met the threshold, fallback to meta description
            if paragraphs.isEmpty {
                let metaDesc = extractMetaContent(html: html, properties: ["og:description", "description", "twitter:description"])
                if let desc = metaDesc, !desc.isEmpty {
                    let cleanDesc = cleanText(desc)
                    if cleanDesc.count >= 20 && !isBoilerplate(cleanDesc) {
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

    // MARK: - HTML Extraction Helpers

    private static func extractMetaContent(html: String, properties: [String]) -> String? {
        for prop in properties {
            // Match <meta property="prop" content="value"> or <meta name="prop" content="value">
            let p1 = "<meta[^>]+(?:property|name)=[\"']\(prop)[\"'][^>]+content=[\"']([^\"']+)[\"']"
            if let match = matchFirstGroup(html: html, pattern: p1) {
                return decodeHTMLEntities(match)
            }
            // Match <meta content="value" property="prop">
            let p2 = "<meta[^>]+content=[\"']([^\"']+)[\"'][^>]+(?:property|name)=[\"']\(prop)[\"']"
            if let match = matchFirstGroup(html: html, pattern: p2) {
                return decodeHTMLEntities(match)
            }
        }
        return nil
    }

    private static func extractTagContent(html: String, tagName: String) -> String? {
        let pattern = "<\(tagName)[^>]*>([\\s\\S]*?)</\(tagName)>"
        if let match = matchFirstGroup(html: html, pattern: pattern) {
            return decodeHTMLEntities(match)
        }
        return nil
    }

    private static func extractLinkHref(html: String, rel: String) -> String? {
        let pattern = "<link[^>]+rel=[\"']\(rel)[\"'][^>]+href=[\"']([^\"']+)[\"']"
        return matchFirstGroup(html: html, pattern: pattern)
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
            ("&ldquo;", "\"")
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

    private static func isBoilerplate(_ text: String) -> Bool {
        let lower = text.lowercased()
        let triggers = [
            "cookie policy", "privacy policy", "terms of use", "terms and conditions",
            "all rights reserved", "subscribe to unlock", "sign up for our newsletter",
            "advertisement", "sponsored content", "share this article", "follow us on twitter"
        ]
        return triggers.contains { lower.contains($0) }
    }
}
