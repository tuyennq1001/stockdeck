import Foundation

/// Fear & Greed Index data from CNN (stocks) or Alternative.me (crypto).
struct FearGreedData: Codable, Equatable {
    let score: Int           // 0-100
    let label: String        // "Extreme Fear", "Fear", "Neutral", "Greed", "Extreme Greed"
    let previousClose: Int?  // score yesterday
    let weekAgo: Int?        // score 1 week ago
    let monthAgo: Int?       // score 1 month ago
    let fetchedAt: Date

    enum Market: String, Codable {
        case stock = "stock"    // CNN Fear & Greed
        case crypto = "crypto"  // Alternative.me Fear & Greed

        var displayName: String {
            switch self {
            case .stock: return "Stocks"
            case .crypto: return "Crypto"
            }
        }

        var sourceName: String {
            switch self {
            case .stock: return "CNN Fear & Greed"
            case .crypto: return "Alternative.me"
            }
        }

        var sourceURL: String {
            switch self {
            case .stock: return "https://edition.cnn.com/markets/fear-and-greed"
            case .crypto: return "https://alternative.me/crypto/fear-and-greed-index/"
            }
        }
    }

    /// Classification label from score.
    static func label(for score: Int) -> String {
        switch score {
        case 0...24: return "Extreme Fear"
        case 25...44: return "Fear"
        case 45...55: return "Neutral"
        case 56...74: return "Greed"
        default: return "Extreme Greed"
        }
    }

    /// Vietnamese label for display.
    static func vietnameseLabel(for score: Int) -> String {
        switch score {
        case 0...24: return "Cực kỳ Sợ hãi"
        case 25...44: return "Sợ hãi"
        case 45...55: return "Trung lập"
        case 56...74: return "Tham lam"
        default: return "Cực kỳ Tham lam"
        }
    }

    /// Color representation for the score.
    var scoreColor: FearGreedColor {
        Self.color(for: score)
    }

    static func color(for score: Int) -> FearGreedColor {
        switch score {
        case 0...24: return .extremeFear
        case 25...44: return .fear
        case 45...55: return .neutral
        case 56...74: return .greed
        default: return .extremeGreed
        }
    }

    enum FearGreedColor {
        case extremeFear, fear, neutral, greed, extremeGreed
    }

    /// Change from previous day.
    var dailyChange: Int? {
        guard let prev = previousClose else { return nil }
        return score - prev
    }
}
