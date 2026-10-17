import Foundation

/// Trading session during which the earnings are expected to be reported.
public enum EarningsSession: String, Codable, Sendable, Equatable {
    case bmo = "BMO" // Before Market Open
    case amc = "AMC" // After Market Close
    case unspecified = "TBD"

    public var title: String {
        switch self {
        case .bmo: return "Before Open"
        case .amc: return "After Close"
        case .unspecified: return "Time TBD"
        }
    }

    public var badgeText: String {
        switch self {
        case .bmo: return "BMO"
        case .amc: return "AMC"
        case .unspecified: return "TBD"
        }
    }
}

/// Status representing whether actual EPS beat, missed, or matched consensus estimates.
public enum BeatMissStatus: String, Codable, Sendable, Equatable {
    case beat
    case miss
    case inLine = "inline"
    case unknown

    public var title: String {
        switch self {
        case .beat: return "Beat"
        case .miss: return "Miss"
        case .inLine: return "In-Line"
        case .unknown: return "—"
        }
    }
}

/// Results of a single historical quarterly earnings report.
public struct EarningsQuarterResult: Codable, Sendable, Equatable, Identifiable {
    public var id: String {
        if let p = period, !p.isEmpty { return "\(p)-\(quarterFormatted)" }
        return quarterFormatted
    }

    public let quarterDate: Date?
    public let epsActual: Double?
    public let epsEstimate: Double?
    public let epsDifference: Double?
    /// Surprise in percentage, e.g. 0.0452 for 4.52% (or 4.52 directly if normalized)
    public let surprisePercent: Double?
    public let currency: String?
    public let period: String? // e.g. "-1q", "-2q"
    public let revenue: Double?
    public let netIncome: Double?
    public let profitMargin: Double?

    public init(
        quarterDate: Date?,
        epsActual: Double?,
        epsEstimate: Double?,
        epsDifference: Double?,
        surprisePercent: Double?,
        currency: String? = "USD",
        period: String? = nil,
        revenue: Double? = nil,
        netIncome: Double? = nil,
        profitMargin: Double? = nil
    ) {
        self.quarterDate = quarterDate
        self.epsActual = epsActual
        self.epsEstimate = epsEstimate
        self.epsDifference = epsDifference
        self.surprisePercent = surprisePercent
        self.currency = currency
        self.period = period
        self.revenue = revenue
        self.netIncome = netIncome
        self.profitMargin = profitMargin
    }

    public var quarterFormatted: String {
        guard let date = quarterDate else {
            return period?.uppercased() ?? "Quarter"
        }
        let cal = Calendar.current
        let year = cal.component(.year, from: date)
        let month = cal.component(.month, from: date)
        let quarter = (month - 1) / 3 + 1
        return "Q\(quarter) '\(String(year).suffix(2))"
    }

    public var beatMiss: BeatMissStatus {
        guard let actual = epsActual, let est = epsEstimate else {
            if let diff = epsDifference {
                if diff > 0.005 { return .beat }
                if diff < -0.005 { return .miss }
                return .inLine
            }
            return .unknown
        }
        let diff = actual - est
        if diff > 0.005 { return .beat }
        if diff < -0.005 { return .miss }
        return .inLine
    }

    /// Formatted surprise percentage e.g. "+4.5%" or "-2.1%"
    public var surprisePercentFormatted: String {
        guard let sp = surprisePercent else { return "—" }
        // Note: Yahoo returns surprisePercent as a ratio (e.g. 0.0452 for 4.52%)
        let pct = abs(sp) <= 2.0 ? sp * 100.0 : sp
        let sign = pct > 0 ? "+" : ""
        return String(format: "%@%.1f%%", sign, pct)
    }

    /// Formatted net margin percentage, e.g. "23.2%"
    public var profitMarginFormatted: String? {
        guard let pm = profitMargin, pm.isFinite else { return nil }
        let pct = abs(pm) <= 1.5 ? pm * 100.0 : pm
        return String(format: "%.1f%%", pct)
    }
}

/// Forward-looking consensus estimate and growth projection from Wall Street analysts.
public struct EarningsTrendItem: Codable, Sendable, Equatable, Identifiable {
    public var id: String { period }
    public let period: String // e.g. "0q", "+1q", "0y", "+1y"
    public let endDate: String?
    public let epsEstimate: Double?
    public let epsGrowth: Double?
    public let revenueEstimate: Double?
    public let revenueGrowth: Double?
    public let numberOfAnalysts: Int?

    public init(
        period: String,
        endDate: String? = nil,
        epsEstimate: Double? = nil,
        epsGrowth: Double? = nil,
        revenueEstimate: Double? = nil,
        revenueGrowth: Double? = nil,
        numberOfAnalysts: Int? = nil
    ) {
        self.period = period
        self.endDate = endDate
        self.epsEstimate = epsEstimate
        self.epsGrowth = epsGrowth
        self.revenueEstimate = revenueEstimate
        self.revenueGrowth = revenueGrowth
        self.numberOfAnalysts = numberOfAnalysts
    }

    public var periodTitle: String {
        switch period {
        case "0q": return "Quý hiện tại (Upcoming)"
        case "+1q": return "Quý kế tiếp (Next Qtr)"
        case "0y": return "Năm nay (FY)"
        case "+1y": return "Năm tới (Next FY)"
        default: return period.uppercased()
        }
    }
}

/// Comprehensive earnings item for a single ticker.
public struct EarningsReportItem: Codable, Sendable, Equatable, Identifiable {
    public var id: String { symbol }
    public let symbol: String
    public let companyName: String?

    // Upcoming report details
    public let nextDate: Date?
    public let nextDateEnd: Date?
    public let isDateEstimate: Bool
    public let session: EarningsSession

    // Consensus estimates
    public let epsEstimate: Double?
    public let epsLow: Double?
    public let epsHigh: Double?
    public let revenueEstimate: Double?
    public let revenueLow: Double?
    public let revenueHigh: Double?

    // Historical track record (up to 4 recent quarters)
    public let history: [EarningsQuarterResult]

    // Wall Street forward consensus trends (e.g. 0q, +1q, 0y, +1y)
    public let trends: [EarningsTrendItem]

    public let fetchedAt: Date

    enum CodingKeys: String, CodingKey {
        case symbol, companyName, nextDate, nextDateEnd, isDateEstimate, session
        case epsEstimate, epsLow, epsHigh, revenueEstimate, revenueLow, revenueHigh
        case history, trends, fetchedAt
    }

    public init(
        symbol: String,
        companyName: String? = nil,
        nextDate: Date? = nil,
        nextDateEnd: Date? = nil,
        isDateEstimate: Bool = false,
        session: EarningsSession = .unspecified,
        epsEstimate: Double? = nil,
        epsLow: Double? = nil,
        epsHigh: Double? = nil,
        revenueEstimate: Double? = nil,
        revenueLow: Double? = nil,
        revenueHigh: Double? = nil,
        history: [EarningsQuarterResult] = [],
        trends: [EarningsTrendItem] = [],
        fetchedAt: Date = Date()
    ) {
        self.symbol = symbol.uppercased()
        self.companyName = companyName
        self.nextDate = nextDate
        self.nextDateEnd = nextDateEnd
        self.isDateEstimate = isDateEstimate
        self.session = session
        self.epsEstimate = epsEstimate
        self.epsLow = epsLow
        self.epsHigh = epsHigh
        self.revenueEstimate = revenueEstimate
        self.revenueLow = revenueLow
        self.revenueHigh = revenueHigh
        self.history = history
        self.trends = trends
        self.fetchedAt = fetchedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        symbol = try c.decode(String.self, forKey: .symbol)
        companyName = try c.decodeIfPresent(String.self, forKey: .companyName)
        nextDate = try c.decodeIfPresent(Date.self, forKey: .nextDate)
        nextDateEnd = try c.decodeIfPresent(Date.self, forKey: .nextDateEnd)
        isDateEstimate = try c.decodeIfPresent(Bool.self, forKey: .isDateEstimate) ?? false
        session = try c.decodeIfPresent(EarningsSession.self, forKey: .session) ?? .unspecified
        epsEstimate = try c.decodeIfPresent(Double.self, forKey: .epsEstimate)
        epsLow = try c.decodeIfPresent(Double.self, forKey: .epsLow)
        epsHigh = try c.decodeIfPresent(Double.self, forKey: .epsHigh)
        revenueEstimate = try c.decodeIfPresent(Double.self, forKey: .revenueEstimate)
        revenueLow = try c.decodeIfPresent(Double.self, forKey: .revenueLow)
        revenueHigh = try c.decodeIfPresent(Double.self, forKey: .revenueHigh)
        history = try c.decodeIfPresent([EarningsQuarterResult].self, forKey: .history) ?? []
        trends = try c.decodeIfPresent([EarningsTrendItem].self, forKey: .trends) ?? []
        fetchedAt = try c.decodeIfPresent(Date.self, forKey: .fetchedAt) ?? Date()
    }

    /// Cache expiration check: 24h
    public var isExpired: Bool {
        Date().timeIntervalSince(fetchedAt) >= 86400
    }

    public var hasUpcomingDate: Bool {
        nextDate != nil
    }

    public var hasData: Bool {
        hasUpcomingDate || !history.isEmpty || epsEstimate != nil || revenueEstimate != nil
    }

    /// Days remaining until next earnings date from today (can be negative if just passed today)
    public var daysUntilNextEarnings: Int? {
        guard let nextDate else { return nil }
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let target = cal.startOfDay(for: nextDate)
        let components = cal.dateComponents([.day], from: today, to: target)
        return components.day
    }

    public var isToday: Bool {
        guard let days = daysUntilNextEarnings else { return false }
        return days == 0
    }

    public var isTomorrow: Bool {
        guard let days = daysUntilNextEarnings else { return false }
        return days == 1
    }

    /// Whether the report is coming within the specified window of days (e.g. next 7 days or today)
    public func isUpcoming(withinDays days: Int = 7) -> Bool {
        guard let diff = daysUntilNextEarnings else { return false }
        return diff >= 0 && diff <= days
    }

    /// Formatted countdown text for cards/badges
    public var countdownText: String {
        guard let days = daysUntilNextEarnings else { return "TBD" }
        if days < 0 {
            return "Reported"
        } else if days == 0 {
            return "Today"
        } else if days == 1 {
            return "Tomorrow"
        } else {
            return "In \(days)d"
        }
    }

    /// Formatted date string, e.g. "Oct 29, 2026" or "Oct 29 – Nov 02, 2026"
    public var formattedDateRange: String {
        guard let start = nextDate else { return "Date TBD" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d, yyyy"

        if let end = nextDateEnd, Calendar.current.isDate(start, inSameDayAs: end) == false {
            let startFmt = DateFormatter()
            startFmt.locale = Locale(identifier: "en_US_POSIX")
            startFmt.dateFormat = "MMM d"
            return "\(startFmt.string(from: start)) – \(formatter.string(from: end))"
        }

        return formatter.string(from: start)
    }

    /// Short formatted date for timeline lists, e.g. "Oct 29"
    public var shortDateFormatted: String {
        guard let start = nextDate else { return "TBD" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d"
        return formatter.string(from: start)
    }
}
