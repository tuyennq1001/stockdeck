import Foundation

/// Mode for the Home tab: AI-driven insights vs traditional news feed.
enum HomeViewMode: String, CaseIterable {
    case insights = "AI Insights"
    case news = "News Feed"
}

/// Sentiment classification for a symbol's movement.
enum SymbolInsightSentiment: String, Codable, CaseIterable {
    case positive = "positive"
    case negative = "negative"
    case neutral = "neutral"

    var displayLabel: String {
        switch self {
        case .positive: return "Tích cực"
        case .negative: return "Tiêu cực"
        case .neutral: return "Trung lập"
        }
    }
}

/// A reference to a source article used in generating the insight.
struct InsightSourceRef: Codable, Equatable, Hashable, Identifiable {
    var id: String { articleId.isEmpty ? (url ?? title) : articleId }
    let articleId: String
    let title: String
    let publisher: String
    let url: String?

    init(articleId: String = "", title: String, publisher: String, url: String? = nil) {
        self.articleId = articleId
        self.title = title
        self.publisher = publisher
        self.url = url
    }
}

/// Market category classification for grouping insight cards.
enum MarketCategory: String, Codable, CaseIterable, Identifiable {
    case us = "US"
    case japan = "JP"
    case vietnam = "VN"
    case crypto = "CRYPTO"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .us: return "Chứng khoán Mỹ"
        case .japan: return "Chứng khoán & Quỹ Nhật"
        case .vietnam: return "Chứng khoán Việt Nam"
        case .crypto: return "Tiền mã hóa (Crypto)"
        }
    }

    var icon: String {
        switch self {
        case .us: return "🇺🇸"
        case .japan: return "🇯🇵"
        case .vietnam: return "🇻🇳"
        case .crypto: return "🪙"
        }
    }

    var benchmarkSymbols: [(name: String, symbol: String)] {
        switch self {
        case .us:
            return [
                ("S&P 500", "^GSPC"),
                ("Nasdaq", "^IXIC"),
                ("Dow Jones", "^DJI")
            ]
        case .japan:
            return [
                ("Nikkei 225", "^N225")
            ]
        case .vietnam:
            return [
                ("VN-Index", "^VNINDEX.VN")
            ]
        case .crypto:
            return [
                ("Bitcoin", "BTC-USD"),
                ("Ethereum", "ETH-USD")
            ]
        }
    }
}

/// Explanation for a single symbol's price movement.
struct SymbolInsightItem: Codable, Equatable, Identifiable {
    var id: String { symbol }
    let symbol: String
    let name: String
    let changePercent: Double
    let currentPrice: Double?
    let coreDriver: String
    let bulletPoints: [String]
    let sentiment: SymbolInsightSentiment
    let sources: [InsightSourceRef]
    let marketCategory: MarketCategory

    init(
        symbol: String,
        name: String,
        changePercent: Double,
        currentPrice: Double? = nil,
        coreDriver: String,
        bulletPoints: [String],
        sentiment: SymbolInsightSentiment,
        sources: [InsightSourceRef] = [],
        marketCategory: MarketCategory = .us
    ) {
        self.symbol = symbol
        self.name = name
        self.changePercent = changePercent
        self.currentPrice = currentPrice
        self.coreDriver = coreDriver
        self.bulletPoints = bulletPoints
        self.sentiment = sentiment
        self.sources = sources
        self.marketCategory = marketCategory
    }

    enum CodingKeys: String, CodingKey {
        case symbol, name, changePercent, currentPrice, coreDriver, bulletPoints, sentiment, sources, marketCategory
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        symbol = try container.decode(String.self, forKey: .symbol)
        name = try container.decode(String.self, forKey: .name)
        changePercent = try container.decode(Double.self, forKey: .changePercent)
        currentPrice = try container.decodeIfPresent(Double.self, forKey: .currentPrice)
        coreDriver = try container.decode(String.self, forKey: .coreDriver)
        bulletPoints = try container.decodeIfPresent([String].self, forKey: .bulletPoints) ?? []
        sentiment = try container.decodeIfPresent(SymbolInsightSentiment.self, forKey: .sentiment) ?? .neutral
        sources = try container.decodeIfPresent([InsightSourceRef].self, forKey: .sources) ?? []
        marketCategory = try container.decodeIfPresent(MarketCategory.self, forKey: .marketCategory) ?? .us
    }
}

/// Daily aggregated market/portfolio insights.
struct HomeAIInsight: Codable, Equatable, Identifiable {
    var id: String { dateString }
    let date: Date
    let dateString: String // YYYY-MM-DD
    let portfolioSummary: String
    let marketOverviews: [String: String]? // [MarketCategory.rawValue: "Overview of SPX/Nasdaq/DJI/Nikkei/VNINDEX..."]
    let items: [SymbolInsightItem]
    let generatedAt: Date

    init(
        date: Date = Date(),
        dateString: String? = nil,
        portfolioSummary: String,
        marketOverviews: [String: String]? = nil,
        items: [SymbolInsightItem],
        generatedAt: Date = Date()
    ) {
        self.date = date
        if let ds = dateString {
            self.dateString = ds
        } else {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            self.dateString = f.string(from: date)
        }
        self.portfolioSummary = portfolioSummary
        self.marketOverviews = marketOverviews
        self.items = items
        self.generatedAt = generatedAt
    }

    enum CodingKeys: String, CodingKey {
        case date, dateString, portfolioSummary, marketOverviews, items, generatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.date = try container.decodeIfPresent(Date.self, forKey: .date) ?? Date()
        if let ds = try container.decodeIfPresent(String.self, forKey: .dateString) {
            self.dateString = ds
        } else {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            self.dateString = f.string(from: self.date)
        }
        self.portfolioSummary = try container.decode(String.self, forKey: .portfolioSummary)
        self.marketOverviews = try container.decodeIfPresent([String: String].self, forKey: .marketOverviews)
        self.items = try container.decodeIfPresent([SymbolInsightItem].self, forKey: .items) ?? []
        self.generatedAt = try container.decodeIfPresent(Date.self, forKey: .generatedAt) ?? Date()
    }

    func overview(for category: MarketCategory) -> String? {
        marketOverviews?[category.rawValue] ?? marketOverviews?[category.rawValue.lowercased()]
    }
}
