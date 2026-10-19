import Foundation

/// A single finance news story from Google News' public RSS search feed.
/// Built by `GoogleNewsRSSParser` from the RSS `<item>` elements — no API key
/// required, consistent with the rest of the app.
struct NewsArticle: Identifiable, Hashable {
    let id: String            // RSS "<guid>" (unique per story)
    let title: String
    let content: String       // 2 ~ 3 lines summary/description text
    let publisher: String
    let link: String          // Google News redirect URL; renders the article in-app
    let publishTime: Int      // Unix seconds, 0 if missing
    let thumbnailURL: String? // Google News RSS v2 exposes no thumbnails — always nil
    let relatedTickers: [String]

    /// The tracked symbol this story was fetched for (the "reference stock").
    /// Set by the fetcher after parsing. nil for general-market news.
    var sourceSymbol: String? = nil

    var url: URL? { URL(string: link) }
    var publishedAt: Date { Date(timeIntervalSince1970: TimeInterval(publishTime)) }

    init(id: String, title: String, content: String = "", publisher: String, link: String,
         publishTime: Int, thumbnailURL: String?, relatedTickers: [String],
         sourceSymbol: String? = nil) {
        self.id = id
        self.title = title
        self.content = content
        self.publisher = publisher
        self.link = link
        self.publishTime = publishTime
        self.thumbnailURL = thumbnailURL
        self.relatedTickers = relatedTickers
        self.sourceSymbol = sourceSymbol
    }
}

/// Parses Google News' RSS v2 search feed (`/rss/search?q=...`) into `NewsArticle`s.
/// Uses Foundation's `XMLParser` — no third-party dependency.
enum GoogleNewsRSSParser {
    static func parse(_ data: Data) -> [NewsArticle] {
        let delegate = ParserDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else { return [] }
        return delegate.articles
    }

    /// Parses the feed and tags each story with the tracked symbol it was
    /// fetched for (the "reference stock"), filtering out false-positive numeric matches.
    static func parse(_ data: Data, sourceSymbol: String) -> [NewsArticle] {
        parse(data).compactMap { a in
            guard isRelevantForNumericTicker(ticker: sourceSymbol, title: a.title, content: a.content) else {
                return nil
            }
            var tagged = a
            tagged.sourceSymbol = sourceSymbol
            return tagged
        }
    }

    /// Strips HTML tags and decodes common HTML entities from description text.
    static func cleanHTML(_ html: String) -> String {
        guard !html.isEmpty else { return "" }
        var text = html
        // Decode common XML/HTML entities first so tags like &lt;strong&gt; become <strong>
        let entities = [
            ("&quot;", "\""),
            ("&apos;", "'"),
            ("&#39;", "'"),
            ("&lt;", "<"),
            ("&gt;", ">"),
            ("&nbsp;", " "),
            ("&#160;", " "),
            ("&amp;", "&")
        ]
        for (entity, replacement) in entities {
            text = text.replacingOccurrences(of: entity, with: replacement)
        }
        // Remove HTML tags <...>
        text = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        // Normalize multiple spaces and newlines
        return text.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Intelligently separates a raw RSS headline and description into a clean
    /// Title (1-2 lines) and Content / Subtitle (2-3 lines).
    static func splitTitleAndContent(rawTitle: String, rawDescription: String, publisher: String) -> (title: String, content: String) {
        var title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanDesc = cleanHTML(rawDescription)

        // Strip trailing " - <Publisher>" from title if present
        if !publisher.isEmpty && title.hasSuffix(" - \(publisher)") {
            title = String(title.dropLast(" - \(publisher)".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        } else if let lastDash = title.range(of: " - ", options: .backwards) {
            let possiblePub = String(title[lastDash.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if possiblePub.count <= 30 && !possiblePub.isEmpty {
                title = String(title[..<lastDash.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        let lowerPub = publisher.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        func isPublisherOrWrapper(_ text: String) -> Bool {
            let lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !lower.isEmpty else { return true }
            if !lowerPub.isEmpty {
                if lower == lowerPub || lower == "- \(lowerPub)" || lower == "– \(lowerPub)" || lower == "— \(lowerPub)" || lower == "| \(lowerPub)" {
                    return true
                }
                if lower.count <= lowerPub.count + 4 && lower.contains(lowerPub) {
                    return true
                }
            }
            return false
        }

        // If description has substantive text that is different from title and publisher
        if !cleanDesc.isEmpty && cleanDesc != title && !isPublisherOrWrapper(cleanDesc) {
            if !cleanDesc.hasPrefix(title) {
                return (title, cleanDesc)
            } else if cleanDesc.count > title.count + 5 {
                var remaining = String(cleanDesc.dropFirst(title.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                for prefix in ["- ", "– ", "— ", "| "] {
                    if remaining.hasPrefix(prefix) {
                        remaining = String(remaining.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
                if !remaining.isEmpty && !isPublisherOrWrapper(remaining) {
                    return (title, remaining)
                }
            }
        }

        // Sentence punctuation splits: ". ", "? ", "! "
        for sep in [". ", "? ", "! "] {
            if let range = title.range(of: sep) {
                let firstPart = String(title[..<range.upperBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                let secondPart = String(title[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if firstPart.count >= 15 && secondPart.count >= 10 {
                    let cleanFirst = firstPart.hasSuffix(".") ? String(firstPart.dropLast()) : firstPart
                    return (cleanFirst, secondPart)
                }
            }
        }

        // Colon split: e.g. "BREAKING: Apple signs major AI deal"
        if let range = title.range(of: ": ") {
            let prefix = String(title[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            let suffix = String(title[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if prefix.count <= 15 && prefix.allSatisfy({ $0.isUppercase || $0.isWhitespace }) {
                return (suffix, "\(prefix): Latest market coverage and insights.")
            }
        }

        // Dash split: " — ", " – "
        for dash in [" — ", " – "] {
            if let range = title.range(of: dash) {
                let firstPart = String(title[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                let secondPart = String(title[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if firstPart.count >= 12 && secondPart.count >= 12 && !isPublisherOrWrapper(secondPart) {
                    return (firstPart, secondPart)
                }
            }
        }

        // Single headline
        let isRedundantDesc = cleanDesc.isEmpty || cleanDesc == title || isPublisherOrWrapper(cleanDesc) || cleanDesc.lowercased() == "\(title.lowercased()) \(lowerPub)"
        return (title, isRedundantDesc ? "" : cleanDesc)
    }

    /// Detects automated financial instruments, option chains, and quote pages indexed by search engines
    /// (e.g. "INTC Sep 2027 160.000 call (INTC270917C00160000) stock price, news, quote and history")
    /// which contain zero news article content and are pure automated quote search results.
    public static func isAutomatedQuoteOrInstrument(title: String, description: String = "", link: String = "") -> Bool {
        let lowerTitle = title.lowercased()
        let lowerDesc = description.lowercased()
        let lowerLink = link.lowercased()

        // 1. General automated quote engines & SEO instrument pages
        if lowerTitle.contains("stock price, news, quote and history") ||
           lowerTitle.contains("interactive stock chart") ||
           lowerDesc.contains("stock quote, history, news and other vital information") ||
           (lowerDesc.contains("find the latest") && lowerDesc.contains("stock quote")) {
            return true
        }

        // 2. Japanese stock quote pages, forums, and time-series data (e.g. Yahoo Finance JP /quote/ pages)
        if lowerTitle.contains("：株価・株式情報") ||
           lowerTitle.contains("：掲示板") ||
           lowerTitle.contains("：時系列") ||
           lowerTitle.contains("：チャート") ||
           lowerTitle.contains(": 掲示板") ||
           lowerTitle.contains(": 株価・株式情報") {
            return true
        }

        // Check if link points directly to a quote or forum page rather than a news article
        if lowerLink.contains("finance.yahoo.co.jp/quote/") && !lowerLink.contains("/news/") {
            return true
        }

        // Option contracts notation: e.g. "160.000 call (INTC270917C00160000)" or "put (INTC261014P00130000)"
        if lowerTitle.range(of: #"(?i)\b(?:call|put)\s*\([A-Z0-9_]+\)"#, options: .regularExpression) != nil {
            return true
        }

        return false
    }

    /// Checks if a purely numeric ticker (like Japanese 4-digit codes "1489", "7203")
    /// is actually mentioned in a genuine financial context rather than as an arbitrary number/quantity
    /// (e.g. "焼きサンマ1万1489匹" which is 11,489 fish).
    public static func isRelevantForNumericTicker(ticker: String, title: String, content: String = "") -> Bool {
        let cleanTicker = ticker.replacingOccurrences(of: ".T", with: "").replacingOccurrences(of: ".JP", with: "")
        // If ticker is not purely numeric (e.g. "AAPL", "285A"), it's not a numeric collision issue
        guard !cleanTicker.isEmpty, cleanTicker.allSatisfy({ $0.isNumber }) else {
            return true
        }

        let combined = "\(title) \(content)"

        // Check for common quantity counters in Japanese preceding or succeeding the number
        // Preceded by 万 or 千 (e.g. 1万1489, 5千1489)
        if combined.contains("万\(cleanTicker)") || combined.contains("千\(cleanTicker)") {
            return false
        }

        // Succeeded by typical non-financial quantity counters: 匹 (animals/fish), 人 (people), 台 (machines), 冊 (books), 名 (persons), 羽, 頭
        let nonFinancialCounters = ["匹", "人", "台", "冊", "名", "羽", "頭", "個", "件", "本"]
        for counter in nonFinancialCounters {
            if combined.contains("\(cleanTicker)\(counter)") {
                return false
            }
        }

        // If ticker is 4 digits, check if it has financial markers or boundaries
        // Financial markers: 【1489】, (1489), 1489.T, [1489], コード1489, or financial keywords in title/content
        let financialKeywords = ["株", "銘柄", "決算", "業績", "ETF", "投信", "ファンド", "配当", "証券", "市場", "上場", "日経", "東証", "指数"]
        let hasFinancialContext = financialKeywords.contains { combined.contains($0) }
        if !hasFinancialContext {
            // Also check if ticker has boundary or brackets
            let hasBrackets = combined.contains("【\(cleanTicker)】") || combined.contains("(\(cleanTicker))") || combined.contains("[\(cleanTicker)]") || combined.contains("\(cleanTicker).T")
            if !hasBrackets {
                return false
            }
        }

        return true
    }

    /// Normalizes a headline for syndication deduplication:
    /// Strips trailing syndication wrappers like "（朝日新聞）", "[宮城県]", " - Yahoo!ニュース",
    /// punctuation, and normalized whitespaces so syndicated copies collapse to the same key.
    public static func normalizedTitleKey(_ title: String) -> String {
        var t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip trailing brackets/parens often added by syndication: e.g. （朝日新聞）, [宮城県], (Bloomberg)
        let patterns = [
            #"\s*[\(（\[【][^\)）\]】]+[\)）\]】]\s*$"#, // Trailing parens / brackets like （朝日新聞） or [宮城県]
            #"\s*-\s*[^-]+$"# // Trailing " - Publisher"
        ]
        for p in patterns {
            if let regex = try? NSRegularExpression(pattern: p, options: []) {
                let range = NSRange(t.startIndex..<t.endIndex, in: t)
                t = regex.stringByReplacingMatches(in: t, options: [], range: range, withTemplate: "")
            }
        }
        return t.lowercased().components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }

    private final class ParserDelegate: NSObject, XMLParserDelegate {
        var articles: [NewsArticle] = []

        private var inItem = false
        private var currentElement = ""
        private var itemTitle = ""
        private var itemLink = ""
        private var itemGuid = ""
        private var itemPubDate = ""
        private var itemSource = ""
        private var itemDescription = ""
        private var textBuffer = ""

        func parser(_ parser: XMLParser, didStartElement elementName: String,
                    namespaceURI: String?, qualifiedName qName: String?,
                    attributes attributeDict: [String: String] = [:]) {
            if elementName == "item" {
                inItem = true
                itemTitle = ""; itemLink = ""; itemGuid = ""
                itemPubDate = ""; itemSource = ""; itemDescription = ""
            }
            if inItem {
                currentElement = elementName
                textBuffer = ""
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if inItem { textBuffer += string }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String,
                    namespaceURI: String?, qualifiedName qName: String?) {
            guard inItem else { return }
            switch elementName {
            case "title": itemTitle = textBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
            case "link": itemLink = textBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
            case "guid": itemGuid = textBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
            case "pubDate": itemPubDate = textBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
            case "source": itemSource = textBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
            case "description": itemDescription = textBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
            case "item":
                defer { inItem = false }
                guard !itemTitle.isEmpty, !itemLink.isEmpty else { return }
                guard !GoogleNewsRSSParser.isAutomatedQuoteOrInstrument(
                    title: itemTitle,
                    description: itemDescription,
                    link: itemLink
                ) else {
                    return
                }
                var publisher = itemSource
                if publisher.isEmpty {
                    if let u = URL(string: itemLink), let host = u.host {
                        let cleanHost = host.replacingOccurrences(of: "www.", with: "")
                        if cleanHost.contains("fool.com") { publisher = "The Motley Fool" }
                        else if cleanHost.contains("finance.yahoo.com") { publisher = "Yahoo Finance" }
                        else if cleanHost.contains("thestreet.com") { publisher = "TheStreet" }
                        else if cleanHost.contains("reuters.com") { publisher = "Reuters" }
                        else if cleanHost.contains("bloomberg.com") { publisher = "Bloomberg" }
                        else if cleanHost.contains("marketwatch.com") { publisher = "MarketWatch" }
                        else if cleanHost.contains("wsj.com") { publisher = "Wall Street Journal" }
                        else if cleanHost.contains("cnbc.com") { publisher = "CNBC" }
                        else if cleanHost.contains("benzinga.com") { publisher = "Benzinga" }
                        else if cleanHost.contains("investors.com") { publisher = "Investor's Business Daily" }
                        else if cleanHost.contains("barrons.com") { publisher = "Barron's" }
                        else if cleanHost.contains("stocktwits.com") { publisher = "Stocktwits" }
                        else if cleanHost.contains("forbes.com") { publisher = "Forbes" }
                        else if cleanHost.contains("barchart.com") { publisher = "Barchart" }
                        else if cleanHost.contains("247wallst.com") { publisher = "24/7 Wall St." }
                        else if cleanHost.contains("marketbeat.com") { publisher = "MarketBeat" }
                        else if cleanHost.contains("gurufocus.com") { publisher = "GuruFocus" }
                        else if cleanHost.contains("zacks.com") { publisher = "Zacks" }
                        else if cleanHost.contains("seekingalpha.com") { publisher = "Seeking Alpha" }
                        else if cleanHost.contains("investing.com") { publisher = "Investing.com" }
                        else if cleanHost.contains("tipranks.com") { publisher = "TipRanks" }
                        else { publisher = cleanHost }
                    }
                }
                let (cleanTitle, content) = GoogleNewsRSSParser.splitTitleAndContent(
                    rawTitle: itemTitle,
                    rawDescription: itemDescription,
                    publisher: publisher
                )
                articles.append(NewsArticle(
                    id: itemGuid.isEmpty ? itemLink : itemGuid,
                    title: cleanTitle.isEmpty ? itemTitle : cleanTitle,
                    content: content,
                    publisher: publisher,
                    link: itemLink,
                    publishTime: Self.unixTime(from: itemPubDate),
                    thumbnailURL: nil,
                    relatedTickers: []
                ))
            default: break
            }
            currentElement = ""
        }

        private static let rfcFormats = [
            "EEE, dd MMM yyyy HH:mm:ss zzz",
            "EEE, dd MMM yyyy HH:mm:ss Z",
            "dd MMM yyyy HH:mm:ss zzz",
            "dd MMM yyyy HH:mm:ss Z",
            "EEE, dd MMM yyyy HH:mm zzz",
            "EEE, dd MMM yyyy HH:mm Z",
            "dd MMM yyyy HH:mm zzz",
            "dd MMM yyyy HH:mm Z"
        ]

        private static let formatters: [DateFormatter] = {
            rfcFormats.map { fmt in
                let f = DateFormatter()
                f.locale = Locale(identifier: "en_US_POSIX")
                f.timeZone = TimeZone(secondsFromGMT: 0)
                f.dateFormat = fmt
                return f
            }
        }()

        private static let isoFormatter = ISO8601DateFormatter()

        /// Parses an RSS pubDate into Unix epoch seconds.
        /// Supports standard RFC 822 / RFC 2822 variations (with/without day-of-week,
        /// with/without seconds, named/numeric timezones) and ISO 8601.
        /// Reuses pre-allocated formatters to optimize allocations and throughput.
        static func unixTime(from dateString: String) -> Int {
            let trimmed = dateString.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return 0 }
            for f in formatters {
                if let date = f.date(from: trimmed) {
                    return Int(date.timeIntervalSince1970)
                }
            }
            if let date = isoFormatter.date(from: trimmed) {
                return Int(date.timeIntervalSince1970)
            }
            return 0
        }
    }
}
