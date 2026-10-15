import Foundation

/// Fundamental valuation, profitability, and risk statistics retrieved from Yahoo Finance quoteSummary.
struct KeyStatistics: Codable, Sendable, Equatable {
    let pegRatio: Double?
    let enterpriseToEbitda: Double?
    let beta: Double?
    /// Return on Equity in percent (e.g. 14.8 for 14.8%)
    let returnOnEquity: Double?
    /// Return on Assets in percent (e.g. 8.5 for 8.5%)
    let returnOnAssets: Double?
    /// Return on Invested Capital in percent (e.g. 27.1 for 27.1%)
    let roic: Double?
    /// Net profit margin in percent (e.g. 25.4 for 25.4%)
    let profitMargins: Double?
    /// Debt to Equity ratio in percent (e.g. 78.4 for 78.4%)
    let debtToEquity: Double?
    let fetchedAt: Date

    init(
        pegRatio: Double? = nil,
        enterpriseToEbitda: Double? = nil,
        beta: Double? = nil,
        returnOnEquity: Double? = nil,
        returnOnAssets: Double? = nil,
        roic: Double? = nil,
        profitMargins: Double? = nil,
        debtToEquity: Double? = nil,
        fetchedAt: Date = Date()
    ) {
        self.pegRatio = pegRatio
        self.enterpriseToEbitda = enterpriseToEbitda
        self.beta = beta
        self.returnOnEquity = returnOnEquity
        self.returnOnAssets = returnOnAssets
        self.roic = roic
        self.profitMargins = profitMargins
        self.debtToEquity = debtToEquity
        self.fetchedAt = fetchedAt
    }

    /// Cache TTL: 24 hours
    var isExpired: Bool {
        Date().timeIntervalSince(fetchedAt) >= 86400
    }

    /// True if at least one metric is present
    var hasData: Bool {
        pegRatio != nil ||
        enterpriseToEbitda != nil ||
        beta != nil ||
        returnOnEquity != nil ||
        returnOnAssets != nil ||
        roic != nil ||
        profitMargins != nil ||
        debtToEquity != nil
    }

    /// True if profitability or risk metrics exist
    var hasProfitabilityOrRisk: Bool {
        returnOnEquity != nil ||
        returnOnAssets != nil ||
        roic != nil ||
        profitMargins != nil ||
        debtToEquity != nil ||
        beta != nil
    }
}
