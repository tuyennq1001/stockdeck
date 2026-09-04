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
    /// fetched for (the "reference stock"), mirroring the old Yahoo flow.
    static func parse(_ data: Data, sourceSymbol: String) -> [NewsArticle] {
        parse(data).map { var a = $0; a.sourceSymbol = sourceSymbol; return a }
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

        // If description has substantive text that is different from title and publisher
        if !cleanDesc.isEmpty && cleanDesc != title && cleanDesc != publisher {
            if !cleanDesc.hasPrefix(title) {
                return (title, cleanDesc)
            } else if cleanDesc.count > title.count + 5 {
                let remaining = String(cleanDesc.dropFirst(title.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !remaining.isEmpty {
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

        // Colon split: e.g. "Exclusive: Apple signs major AI deal" or "Apple AI: Why Wall Street is bullish"
        if let range = title.range(of: ": ") {
            let prefix = String(title[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            let suffix = String(title[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if prefix.count <= 15 && prefix.allSatisfy({ $0.isUppercase || $0.isWhitespace }) {
                return (suffix, "\(prefix): Latest market coverage and insights.")
            } else if prefix.count >= 12 && suffix.count >= 12 {
                return (prefix, suffix)
            }
        }

        // Dash split: " — ", " – "
        for dash in [" — ", " – "] {
            if let range = title.range(of: dash) {
                let firstPart = String(title[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                let secondPart = String(title[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if firstPart.count >= 12 && secondPart.count >= 12 {
                    return (firstPart, secondPart)
                }
            }
        }

        // Single headline
        return (title, cleanDesc.isEmpty || cleanDesc == title ? "" : cleanDesc)
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

        /// Parses an RSS pubDate (RFC 822, e.g. "Tue, 11 Aug 2026 17:10:15 GMT").
        private static func unixTime(from rfc822: String) -> Int {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            return f.date(from: rfc822).map { Int($0.timeIntervalSince1970) } ?? 0
        }
    }
}
