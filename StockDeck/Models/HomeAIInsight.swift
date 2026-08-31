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

    /// Native time zone for each market category.
    var timeZone: TimeZone {
        switch self {
        case .us: return TimeZone(identifier: "America/New_York") ?? .current
        case .japan: return TimeZone(identifier: "Asia/Tokyo") ?? .current
        case .vietnam: return TimeZone(identifier: "Asia/Ho_Chi_Minh") ?? .current
        case .crypto: return TimeZone(identifier: "UTC") ?? .current
        }
    }

    /// Returns true if the market is active / in its current trading cycle on the given date.
    /// Crypto is 24/7/365.
    /// For stock exchanges (US, JP, VN):
    /// - Saturday & Sunday in the market's native timezone are closed.
    /// - Monday before the market opens (e.g. before 09:00 JST for JP, 09:00 ICT for VN, 04:00 EDT pre-market for US) is closed (weekend break until opening bell).
    /// - On weekdays during and after trading hours until next morning's open, the day's session is active.
    func isTradingDay(at date: Date = Date(), customTimeZone: TimeZone? = nil) -> Bool {
        if self == .crypto { return true }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = customTimeZone ?? self.timeZone

        let components = calendar.dateComponents([.weekday, .hour, .minute], from: date)
        guard let weekday = components.weekday, let hour = components.hour, let minute = components.minute else {
            return false
        }

        // 1 = Sunday, 7 = Saturday in Gregorian calendar
        if weekday == 1 || weekday == 7 {
            return false
        }

        // On Monday, market remains closed until the opening bell of the first session of the week:
        if weekday == 2 {
            let currentMinutes = hour * 60 + minute
            switch self {
            case .japan:
                // TSE opens at 09:00 JST
                if currentMinutes < 9 * 60 { return false }
            case .vietnam:
                // HOSE/HNX opens at 09:00 ICT
                if currentMinutes < 9 * 60 { return false }
            case .us:
                // US pre-market starts at 04:00 EDT (09:30 EDT for regular session)
                if currentMinutes < 4 * 60 { return false }
            case .crypto:
                return true
            }
        }

        return true
    }

    /// Resolved market timezone and Monday open minutes for any given symbol (including global indices & stocks).
    static func marketSchedule(for symbol: String, isCrypto: Bool = false) -> (timeZone: TimeZone, mondayOpenMinutes: Int) {
        if isCrypto || HomeAIInsightService.cryptoBaseAsset(for: symbol) != nil {
            return (TimeZone(identifier: "UTC") ?? .current, 0)
        }
        let upper = symbol.uppercased()

        // Vietnam (HOSE/HNX): ICT (UTC+7), opens at 09:00 ICT (540 mins)
        if StockService.isVietnameseStock(upper) || upper.hasSuffix(".VN") || upper == "^VNINDEX.VN" || upper == "VNINDEX" || upper == "HNX" {
            return (TimeZone(identifier: "Asia/Ho_Chi_Minh") ?? .current, 9 * 60)
        }

        // Japan (TSE): JST (UTC+9), opens at 09:00 JST (540 mins)
        if StockService.isJapaneseStock(upper) || StockService.isJapaneseMutualFund(upper) || upper.hasSuffix(".T") || upper == "^N225" || upper == "^TPX" {
            return (TimeZone(identifier: "Asia/Tokyo") ?? .current, 9 * 60)
        }

        // South Korea (KRX): KST (UTC+9), opens at 09:00 KST (540 mins)
        if upper == "^KS11" || upper == "^KQ11" || upper.hasSuffix(".KS") || upper.hasSuffix(".KQ") {
            return (TimeZone(identifier: "Asia/Seoul") ?? .current, 9 * 60)
        }

        // Hong Kong, Taiwan, China: HKT/CST (UTC+8), opens at 09:00 HKT (540 mins)
        if upper == "^HSI" || upper == "^HSCE" || upper == "^TWII" || upper.hasSuffix(".HK") || upper.hasSuffix(".TW") || upper.hasSuffix(".SS") || upper.hasSuffix(".SZ") {
            return (TimeZone(identifier: "Asia/Hong_Kong") ?? .current, 9 * 60)
        }

        // India (NSE/BSE): IST (UTC+5:30), opens at 09:15 IST (555 mins)
        if upper == "^NSEI" || upper == "^BSESN" || upper.hasSuffix(".NS") || upper.hasSuffix(".BO") {
            return (TimeZone(identifier: "Asia/Kolkata") ?? .current, 9 * 60 + 15)
        }

        // UK & Europe: GMT/BST/CET, opens at 08:00 or 09:00 local
        if upper == "^FTSE" || upper.hasSuffix(".L") {
            return (TimeZone(identifier: "Europe/London") ?? .current, 8 * 60)
        }
        if upper == "^GDAXI" || upper == "^FCHI" || upper == "^STOXX50E" || upper.hasSuffix(".DE") || upper.hasSuffix(".PA") || upper.hasSuffix(".AS") || upper.hasSuffix(".MI") || upper.hasSuffix(".MC") {
            return (TimeZone(identifier: "Europe/Berlin") ?? .current, 9 * 60)
        }

        // US & Default: America/New_York (EDT/EST), pre-market starts at 04:00 EDT (240 mins)
        return (TimeZone(identifier: "America/New_York") ?? .current, 4 * 60)
    }

    /// Determines the market category for a given symbol.
    static func detect(symbol: String, isCrypto: Bool = false) -> MarketCategory {
        HomeAIInsightService.detectMarketCategory(symbol: symbol, isCrypto: isCrypto)
    }

    /// Returns true if the symbol is trading / active on the given calendar date.
    /// 1. For crypto, always returns true (24/7/365).
    /// 2. For stocks/funds/indices, checks timezone-aware trading days and pre-open hours:
    ///    - Saturday & Sunday in the market's timezone are always CLOSED.
    ///    - Monday before the opening bell of the week is always CLOSED.
    ///    - On weekdays during/after market hours, returns true (active trading day).
    static func isTradingDay(
        symbol: String,
        quote: StockQuote? = nil,
        isCrypto: Bool = false,
        at date: Date = Date(),
        customTimeZone: TimeZone? = nil
    ) -> Bool {
        if isCrypto || HomeAIInsightService.cryptoBaseAsset(for: symbol) != nil {
            return true
        }

        let schedule = marketSchedule(for: symbol, isCrypto: isCrypto)
        let tz = customTimeZone ?? schedule.timeZone

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = tz

        let components = calendar.dateComponents([.weekday, .hour, .minute], from: date)
        guard let weekday = components.weekday, let hour = components.hour, let minute = components.minute else {
            return false
        }

        // 1 = Sunday, 7 = Saturday in Gregorian calendar -> 100% closed on weekends
        if weekday == 1 || weekday == 7 {
            return false
        }

        // On Monday, market remains closed until the opening bell of the first session of the week:
        if weekday == 2 {
            let currentMinutes = hour * 60 + minute
            if currentMinutes < schedule.mondayOpenMinutes {
                return false
            }
        }

        return true
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

    func makeNewsArticle(for url: URL, timestamp: Date = Date()) -> NewsArticle {
        let matchedPub = sources.first(where: { $0.url == url.absoluteString })?.publisher
        let pub = matchedPub?.isEmpty == false ? matchedPub! : name
        return NewsArticle(
            id: url.absoluteString,
            title: "\(symbol): \(coreDriver)",
            content: coreDriver,
            publisher: pub,
            link: url.absoluteString,
            publishTime: Int(timestamp.timeIntervalSince1970),
            thumbnailURL: nil,
            relatedTickers: [symbol],
            sourceSymbol: symbol
        )
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
