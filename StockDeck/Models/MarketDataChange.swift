import Foundation

/// A small invalidation message for views and view models that only need one
/// part of the market-data store. It deliberately carries no quote/history
/// payload so consumers take a fresh snapshot after publication.
struct MarketDataChange: Sendable, Equatable {
    enum Kind: String, Sendable, Hashable {
        case regularQuote
        case extendedQuote
        case dailyHistory
        case maxHistory
        case intradayHistory
        case watchlistHistory
        case fx
        case metadata
    }

    let kind: Kind
    let symbols: Set<String>
    let revision: UInt64
}
