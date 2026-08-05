import Foundation

/// Centralized configuration for Vietnam stock market data provider.
/// Decouples market API endpoints from provider vendor names.
struct VNMarketConfig {
    /// Base URL for Vietnam market daily history & quote API
    static var apiBaseURL: String = "https://dchart-api.vndirect.com.vn/dchart/history"
}
