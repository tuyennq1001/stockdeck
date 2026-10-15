import Foundation

/// Centralized configuration for Vietnam stock market data provider.
/// Decouples market API endpoints from provider vendor names.
struct VNMarketConfig {
    /// Base URL for Vietnam market daily history & quote API
    static var apiBaseURL: String = "https://dchart-api.vndirect.com.vn/dchart/history"
    /// Base URL for Vietnam market search API
    static var searchBaseURL: String = "https://dchart-api.vndirect.com.vn/dchart/search"
    /// Base URL for Simplize company summary API (fallback for HNX/UPCoM fundamentals)
    static var simplizeCompanyBaseURL: String = "https://api2.simplize.vn/api/company/summary"
    /// Base URL for Simplize sector performance API (for VN-Index market P/E)
    static var simplizeSectorBaseURL: String = "https://api2.simplize.vn/api/company/se/sector-performance"
    /// Base URL for Simplize historical quote API (for VN-Index total traded value)
    static var simplizeQuoteBaseURL: String = "https://api.simplize.vn/api/historical/quote"
}
