import Foundation

/// A single finance news story from Google News' public RSS search feed.
/// Built by `GoogleNewsRSSParser` from the RSS `<item>` elements — no API key
/// required, consistent with the rest of the app.
struct NewsArticle: Identifiable, Hashable {
    let id: String            // RSS "<guid>" (unique per story)
    let title: String
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

    init(id: String, title: String, publisher: String, link: String,
         publishTime: Int, thumbnailURL: String?, relatedTickers: [String],
         sourceSymbol: String? = nil) {
        self.id = id
        self.title = title
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

    private final class ParserDelegate: NSObject, XMLParserDelegate {
        var articles: [NewsArticle] = []

        private var inItem = false
        private var currentElement = ""
        private var itemTitle = ""
        private var itemLink = ""
        private var itemGuid = ""
        private var itemPubDate = ""
        private var itemSource = ""
        private var textBuffer = ""

        func parser(_ parser: XMLParser, didStartElement elementName: String,
                    namespaceURI: String?, qualifiedName qName: String?,
                    attributes attributeDict: [String: String] = [:]) {
            if elementName == "item" {
                inItem = true
                itemTitle = ""; itemLink = ""; itemGuid = ""
                itemPubDate = ""; itemSource = ""
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
            case "item":
                defer { inItem = false }
                guard !itemTitle.isEmpty, !itemLink.isEmpty else { return }
                articles.append(NewsArticle(
                    id: itemGuid.isEmpty ? itemLink : itemGuid,
                    title: itemTitle,
                    publisher: itemSource,
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
