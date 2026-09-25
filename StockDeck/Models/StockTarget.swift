import Foundation

public struct StockTarget: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var symbol: String
    public var targetPrice: Double         // Buy Target Price
    public var note: String?               // Optional purchase plan note
    public var notifyWhenReached: Bool     // Auto alert when price drops to or below target
    public var isReached: Bool             // Status: whether price has entered buy zone
    public var reachedAt: Date?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        symbol: String,
        targetPrice: Double,
        note: String? = nil,
        notifyWhenReached: Bool = true,
        isReached: Bool = false,
        reachedAt: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.symbol = symbol
        self.targetPrice = targetPrice
        self.note = note
        self.notifyWhenReached = notifyWhenReached
        self.isReached = isReached
        self.reachedAt = reachedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Calculates percentage distance from current price to buy target price.
    /// E.g. current = 230, target = 210 -> ((210 - 230) / 230) * 100 = -8.69% (needs to drop 8.7% to reach target).
    public func percentDistance(from currentPrice: Double) -> Double? {
        guard currentPrice > 0, targetPrice > 0 else { return nil }
        return ((targetPrice - currentPrice) / currentPrice) * 100.0
    }

    /// Checks if current price has dropped to or below the buy target (in the buy zone).
    public func isInBuyZone(currentPrice: Double) -> Bool {
        guard currentPrice > 0, targetPrice > 0 else { return false }
        return currentPrice <= targetPrice
    }
}
