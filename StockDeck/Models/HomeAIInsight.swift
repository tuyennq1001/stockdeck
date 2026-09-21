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
        case .us: return "US Stocks"
        case .japan: return "Japan Stocks & Funds"
        case .vietnam: return "Vietnam Stocks"
        case .crypto: return "Crypto"
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

        // On Monday, market remains closed until the opening bell of the first regular session of the week:
        if weekday == 2 {
            let currentMinutes = hour * 60 + minute
            switch self {
            case .japan:
                // TSE regular session opens at 09:00 JST (540 mins)
                if currentMinutes < 9 * 60 { return false }
            case .vietnam:
                // HOSE/HNX regular session opens at 09:00 ICT (540 mins)
                if currentMinutes < 9 * 60 { return false }
            case .us:
                // US regular session opens at 09:30 EDT/EST (570 mins)
                if currentMinutes < (9 * 60 + 30) { return false }
            case .crypto:
                return true
            }
        }

        return true
    }

    /// Resolved market timezone, Monday open minutes, and regular close minutes for any given symbol (including global indices & stocks).
    static func marketSchedule(for symbol: String, isCrypto: Bool = false) -> (timeZone: TimeZone, mondayOpenMinutes: Int, regularCloseMinutes: Int) {
        if isCrypto || HomeAIInsightService.cryptoBaseAsset(for: symbol) != nil {
            return (TimeZone(identifier: "UTC") ?? .current, 0, 24 * 60)
        }
        let upper = symbol.uppercased()

        // Vietnam (HOSE/HNX): ICT (UTC+7), regular session opens at 09:00 ICT (540 mins), closes 15:00 ICT (900 mins)
        if StockService.isVietnameseStock(upper) || upper.hasSuffix(".VN") || upper == "^VNINDEX.VN" || upper == "VNINDEX" || upper == "HNX" {
            return (TimeZone(identifier: "Asia/Ho_Chi_Minh") ?? .current, 9 * 60, 15 * 60)
        }

        // Japan (TSE): JST (UTC+9), regular session opens at 09:00 JST (540 mins), closes 15:30 JST (930 mins)
        if StockService.isJapaneseStock(upper) || StockService.isJapaneseMutualFund(upper) || upper.hasSuffix(".T") || upper == "^N225" || upper == "^TPX" {
            return (TimeZone(identifier: "Asia/Tokyo") ?? .current, 9 * 60, 15 * 60 + 30)
        }

        // South Korea (KRX): KST (UTC+9), regular session opens at 09:00 KST (540 mins), closes 15:30 KST (930 mins)
        if upper == "^KS11" || upper == "^KQ11" || upper.hasSuffix(".KS") || upper.hasSuffix(".KQ") {
            return (TimeZone(identifier: "Asia/Seoul") ?? .current, 9 * 60, 15 * 60 + 30)
        }

        // Hong Kong (HKEX): HKT (UTC+8), regular session opens at 09:30 HKT (570 mins), closes 16:00 HKT (960 mins)
        if upper == "^HSI" || upper == "^HSCE" || upper.hasSuffix(".HK") {
            return (TimeZone(identifier: "Asia/Hong_Kong") ?? .current, 9 * 60 + 30, 16 * 60)
        }

        // Taiwan (TWSE): CST (UTC+8), regular session opens at 09:00 CST (540 mins), closes 13:30 CST (810 mins)
        if upper == "^TWII" || upper.hasSuffix(".TW") {
            return (TimeZone(identifier: "Asia/Taipei") ?? .current, 9 * 60, 13 * 60 + 30)
        }

        // China (SSE/SZSE): CST (UTC+8), regular session opens at 09:30 CST (570 mins), closes 15:00 CST (900 mins)
        if upper.hasSuffix(".SS") || upper.hasSuffix(".SZ") {
            return (TimeZone(identifier: "Asia/Shanghai") ?? .current, 9 * 60 + 30, 15 * 60)
        }

        // Australia (ASX): AEST/AEDT (UTC+10/+11), regular session opens at 10:00 AEST (600 mins), closes 16:00 AEST (960 mins)
        if upper == "^AXJO" || upper.hasSuffix(".AX") {
            return (TimeZone(identifier: "Australia/Sydney") ?? .current, 10 * 60, 16 * 60)
        }

        // India (NSE/BSE): IST (UTC+5:30), regular session opens at 09:15 IST (555 mins), closes 15:30 IST (930 mins)
        if upper == "^NSEI" || upper == "^BSESN" || upper.hasSuffix(".NS") || upper.hasSuffix(".BO") {
            return (TimeZone(identifier: "Asia/Kolkata") ?? .current, 9 * 60 + 15, 15 * 60 + 30)
        }

        // UK (LSE): GMT/BST, regular session opens at 08:00 local (480 mins), closes 16:30 local (990 mins)
        if upper == "^FTSE" || upper.hasSuffix(".L") {
            return (TimeZone(identifier: "Europe/London") ?? .current, 8 * 60, 16 * 60 + 30)
        }

        // Europe (XETRA, Euronext): CET/CEST, regular session opens at 09:00 local (540 mins), closes 17:30 local (1050 mins)
        if upper == "^GDAXI" || upper == "^FCHI" || upper == "^STOXX50E" || upper.hasSuffix(".DE") || upper.hasSuffix(".PA") || upper.hasSuffix(".AS") || upper.hasSuffix(".MI") || upper.hasSuffix(".MC") {
            return (TimeZone(identifier: "Europe/Berlin") ?? .current, 9 * 60, 17 * 60 + 30)
        }

        // Canada (TSX): EDT/EST, regular session opens at 09:30 local (570 mins), closes 16:00 local (960 mins)
        if upper == "^GSPTSE" || upper.hasSuffix(".TO") || upper.hasSuffix(".V") {
            return (TimeZone(identifier: "America/Toronto") ?? .current, 9 * 60 + 30, 16 * 60)
        }

        // Futures & FX: CME Globex / Forex trades on Eastern Time (America/New_York)
        if upper.hasSuffix("=F") || upper.hasSuffix("=X") {
            return (TimeZone(identifier: "America/New_York") ?? .current, 0, 24 * 60)
        }

        // US & Default: America/New_York (EDT/EST), regular session opens at 09:30 EDT/EST (570 mins), closes 16:00 EDT/EST (960 mins)
        return (TimeZone(identifier: "America/New_York") ?? .current, 9 * 60 + 30, 16 * 60)
    }

    /// Determines the market category for a given symbol.
    static func detect(symbol: String, isCrypto: Bool = false) -> MarketCategory {
        HomeAIInsightService.detectMarketCategory(symbol: symbol, isCrypto: isCrypto)
    }

    /// Returns true if the symbol is trading / active on the given calendar date.
    /// 1. For crypto, always returns true (24/7/365).
    /// 2. For futures & FX, trades Sunday 18:00 ET through Friday 17:00 ET.
    /// 3. For stocks/funds/indices, checks timezone-aware trading days and pre-open hours:
    ///    - Saturday & Sunday in the market's timezone are always CLOSED.
    ///    - Monday before the opening bell of the week is always CLOSED.
    ///    - On weekdays during/after market hours, returns true (active trading day).
    ///    - Real-time provider awareness: if market is during regular hours but state is CLOSED, marks as CLOSED (holiday/halt).
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

        let upper = symbol.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let isFuture = upper.hasSuffix("=F")
        let isFX = upper.hasSuffix("=X")

        let schedule = marketSchedule(for: symbol, isCrypto: isCrypto)
        let tz = customTimeZone ?? schedule.timeZone

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = tz

        let components = calendar.dateComponents([.weekday, .hour, .minute], from: date)
        guard let weekday = components.weekday, let hour = components.hour, let minute = components.minute else {
            return false
        }
        let currentMinutes = hour * 60 + minute

        // Futures & FX trading schedule (opens Sunday 18:00 ET, closes Friday 17:00 ET)
        if isFuture || isFX {
            // Saturday (7): completely closed
            if weekday == 7 {
                return false
            }
            // Sunday (1): opens at 18:00 ET (1080 mins)
            if weekday == 1 {
                return currentMinutes >= 18 * 60
            }
            // Friday (6): closes at 17:00 ET (1020 mins) for weekend
            if weekday == 6 {
                return currentMinutes < 17 * 60
            }
            // Monday - Thursday (2..5): active trading days
            return true
        }

        // Standard stock & index market schedule:
        // 1 = Sunday, 7 = Saturday in Gregorian calendar -> 100% closed on weekends
        if weekday == 1 || weekday == 7 {
            return false
        }

        // On Monday, market remains closed until the opening bell of the first session of the week:
        if weekday == 2 {
            if currentMinutes < schedule.mondayOpenMinutes {
                return false
            }
        }

        // Live provider market state & holiday awareness:
        if let quote = quote {
            let state = quote.marketState.uppercased()
            let isDuringRegularHours = currentMinutes >= schedule.mondayOpenMinutes && currentMinutes <= schedule.regularCloseMinutes

            if isDuringRegularHours {
                // If it is currently during the regular session hours of the exchange,
                // but the provider explicitly reports CLOSED, the exchange is observing a holiday or is halted.
                if state == "CLOSED" {
                    return false
                }
                if state == "REGULAR" || state == "PRE" || state == "POST" {
                    return true
                }
            } else if currentMinutes > schedule.regularCloseMinutes {
                // If after regular market hours on a weekday:
                // Check if any trades actually occurred today. If regularMarketTime is present and from a prior date,
                // it indicates today had no session (e.g. today was a full-day holiday).
                if let rmt = quote.regularMarketTime {
                    if !calendar.isDate(rmt, inSameDayAs: date) {
                        return false
                    }
                }
            }
        }

        return true
    }
}

enum InsightRiskLevel: String, Codable, CaseIterable {
    case low = "low"
    case moderate = "moderate"
    case high = "high"
    case extreme = "extreme"

    var displayLabel: String {
        switch self {
        case .low: return "Rủi ro thấp"
        case .moderate: return "Rủi ro TB"
        case .high: return "Rủi ro cao"
        case .extreme: return "Rủi ro cực cao"
        }
    }

    var icon: String {
        switch self {
        case .low: return "🟢"
        case .moderate: return "🟡"
        case .high: return "🟠"
        case .extreme: return "🔴"
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
    let riskLevel: InsightRiskLevel?
    let actionableNote: String?
    let currency: String?

    init(
        symbol: String,
        name: String,
        changePercent: Double,
        currentPrice: Double? = nil,
        currency: String? = nil,
        coreDriver: String,
        bulletPoints: [String],
        sentiment: SymbolInsightSentiment,
        sources: [InsightSourceRef] = [],
        marketCategory: MarketCategory = .us,
        riskLevel: InsightRiskLevel? = nil,
        actionableNote: String? = nil
    ) {
        self.symbol = symbol
        self.name = name
        self.changePercent = changePercent
        self.currentPrice = currentPrice
        self.currency = currency
        self.coreDriver = coreDriver
        self.bulletPoints = bulletPoints
        self.sentiment = sentiment
        self.sources = sources
        self.marketCategory = marketCategory
        self.riskLevel = riskLevel
        self.actionableNote = actionableNote
    }

    /// Formats the price with native currency symbol and market-appropriate decimals.
    var formattedPrice: String? {
        guard let p = currentPrice, p.isFinite else { return nil }
        let curr = currency ?? (marketCategory == .vietnam ? "VND" : (marketCategory == .japan ? "JPY" : "USD"))
        let sym = StorageService.currencySymbol(for: curr)
        let dec: Int
        if curr == "VND" || curr == "JPY" {
            dec = 0
        } else if p >= 1000 {
            dec = 2
        } else if p < 1 {
            dec = 4
        } else {
            dec = 2
        }
        let formatted = StorageService.formatNumber(p, decimals: dec)
        if curr == "VND" {
            return "\(formatted) \(sym)"
        } else {
            return "\(sym)\(formatted)"
        }
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
        case symbol, name, changePercent, currentPrice, currency, coreDriver, bulletPoints, sentiment, sources, marketCategory, riskLevel, actionableNote
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        symbol = try container.decode(String.self, forKey: .symbol)
        name = try container.decode(String.self, forKey: .name)
        changePercent = try container.decode(Double.self, forKey: .changePercent)
        currentPrice = try container.decodeIfPresent(Double.self, forKey: .currentPrice)
        currency = try container.decodeIfPresent(String.self, forKey: .currency)
        coreDriver = try container.decode(String.self, forKey: .coreDriver)
        bulletPoints = try container.decodeIfPresent([String].self, forKey: .bulletPoints) ?? []
        sentiment = try container.decodeIfPresent(SymbolInsightSentiment.self, forKey: .sentiment) ?? .neutral
        sources = try container.decodeIfPresent([InsightSourceRef].self, forKey: .sources) ?? []
        marketCategory = try container.decodeIfPresent(MarketCategory.self, forKey: .marketCategory) ?? .us
        riskLevel = try container.decodeIfPresent(InsightRiskLevel.self, forKey: .riskLevel)
        actionableNote = try container.decodeIfPresent(String.self, forKey: .actionableNote)
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
    let language: String?
    let generatedAt: Date

    init(
        date: Date = Date(),
        dateString: String? = nil,
        portfolioSummary: String,
        marketOverviews: [String: String]? = nil,
        items: [SymbolInsightItem],
        language: String? = nil,
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
        self.language = language
        self.generatedAt = generatedAt
    }

    enum CodingKeys: String, CodingKey {
        case date, dateString, portfolioSummary, marketOverviews, items, language, generatedAt
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
        self.language = try container.decodeIfPresent(String.self, forKey: .language)
        self.generatedAt = try container.decodeIfPresent(Date.self, forKey: .generatedAt) ?? Date()
    }

    func overview(for category: MarketCategory) -> String? {
        marketOverviews?[category.rawValue] ?? marketOverviews?[category.rawValue.lowercased()]
    }
}
