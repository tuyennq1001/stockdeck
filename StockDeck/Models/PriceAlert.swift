import Foundation

/// The condition that makes a `PriceAlert` fire.
enum AlertCondition: String, Codable, CaseIterable {
    /// Fires when the price rises to/above the threshold (an absolute price).
    case priceAbove
    /// Fires when the price falls to/below the threshold (an absolute price).
    case priceBelow
    /// Fires when the daily change rises to/above the threshold (a positive percent).
    case dailyChangeUp
    /// Fires when the daily change falls to/below the negative threshold (a positive percent).
    case dailyChangeDown
    /// Fires when the price comes within `threshold`% of the 52-week high.
    case near52WeekHigh
    /// Fires when the price comes within `threshold`% of the 52-week low.
    case near52WeekLow
    /// Fires when the price crosses above the trailing 200-day simple moving average.
    case priceAboveSMA200
    /// Fires when the price crosses below the trailing 200-day simple moving average.
    case priceBelowSMA200
    /// Fires when the price crosses above the trailing 200-day exponential moving average.
    case priceAboveEMA200
    /// Fires when the price crosses below the trailing 200-day exponential moving average.
    case priceBelowEMA200
    /// Fires when the price crosses above the trailing 200-week simple moving average.
    case priceAboveWeeklySMA200
    /// Fires when the price crosses below the trailing 200-week simple moving average.
    case priceBelowWeeklySMA200

    /// Whether the threshold is an absolute price or a percentage.
    /// MA conditions carry no user threshold: the moving average is computed
    /// from price history at evaluation time.
    enum ThresholdKind { case price, percent, ma }

    var thresholdKind: ThresholdKind {
        switch self {
        case .priceAbove, .priceBelow: return .price
        case .dailyChangeUp, .dailyChangeDown, .near52WeekHigh, .near52WeekLow: return .percent
        case .priceAboveSMA200, .priceBelowSMA200,
             .priceAboveEMA200, .priceBelowEMA200,
             .priceAboveWeeklySMA200, .priceBelowWeeklySMA200: return .ma
        }
    }

    /// The rolling-average series this condition tracks.
    var movingAverage: MovingAverage.Kind? {
        switch self {
        case .priceAboveSMA200, .priceBelowSMA200: return .sma(period: 200)
        case .priceAboveEMA200, .priceBelowEMA200: return .ema(period: 200)
        case .priceAboveWeeklySMA200, .priceBelowWeeklySMA200: return .weeklySMA(period: 200)
        case .priceAbove, .priceBelow, .dailyChangeUp, .dailyChangeDown, .near52WeekHigh, .near52WeekLow: return nil
        }
    }

    /// Short label for pickers.
    var label: String {
        switch self {
        case .priceAbove: return "Price rises above"
        case .priceBelow: return "Price drops below"
        case .dailyChangeUp: return "Daily change up by"
        case .dailyChangeDown: return "Daily change down by"
        case .near52WeekHigh: return "Near 52-week high"
        case .near52WeekLow: return "Near 52-week low"
        case .priceAboveSMA200: return "Crosses above SMA 200"
        case .priceBelowSMA200: return "Crosses below SMA 200"
        case .priceAboveEMA200: return "Crosses above EMA 200"
        case .priceBelowEMA200: return "Crosses below EMA 200"
        case .priceAboveWeeklySMA200: return "Crosses above weekly SMA 200"
        case .priceBelowWeeklySMA200: return "Crosses below weekly SMA 200"
        }
    }

    var systemImage: String {
        switch self {
        case .priceAbove, .dailyChangeUp, .near52WeekHigh,
             .priceAboveSMA200, .priceAboveEMA200, .priceAboveWeeklySMA200: return "arrow.up.right"
        case .priceBelow, .dailyChangeDown, .near52WeekLow,
             .priceBelowSMA200, .priceBelowEMA200, .priceBelowWeeklySMA200: return "arrow.down.right"
        }
    }
}

/// A one-shot price alert for a single symbol. After firing, `isEnabled` is set
/// to false so it does not notify again until the user re-arms it. MA-based
/// conditions (`crossing` SMA/EMA) instead stay enabled and fire each time
/// the price moves to the other side of the rolling average, tracked by
/// `lastPositionAboveMA`.
struct PriceAlert: Identifiable, Codable, Equatable {
    var id: UUID
    var symbol: String
    var condition: AlertCondition
    /// Absolute price for price conditions; a positive percent for the others;
    /// unused for MA conditions (the threshold is the moving average itself).
    var threshold: Double
    var isEnabled: Bool
    var createdAt: Date
    var lastTriggeredAt: Date?
    /// Recency state for crossing MA alerts: `true` if the last evaluation
    /// saw the price above the average, `false` if below, `nil` before the first
    /// evaluation. A change of side fires the alert.
    var lastPositionAboveMA: Bool?

    init(id: UUID = UUID(),
         symbol: String,
         condition: AlertCondition,
         threshold: Double,
         isEnabled: Bool = true,
         createdAt: Date = Date(),
         lastTriggeredAt: Date? = nil,
         lastPositionAboveMA: Bool? = nil) {
        self.id = id
        self.symbol = symbol
        self.condition = condition
        self.threshold = threshold
        self.isEnabled = isEnabled
        self.createdAt = createdAt
        self.lastTriggeredAt = lastTriggeredAt
        self.lastPositionAboveMA = lastPositionAboveMA
    }
}

/// Pure, side-effect-free evaluation of alert conditions. This is the unit under test;
/// the app feeds it live quote values and reacts to the boolean result.
enum AlertEvaluator {

    /// Core evaluation over primitive inputs (no model dependencies, fully testable).
    /// - Returns: true when the condition is met. A disabled alert never fires.
    static func shouldFire(condition: AlertCondition,
                           threshold: Double,
                           isEnabled: Bool,
                           price: Double,
                           changePercent: Double,
                           fiftyTwoWeekHigh: Double?,
                           fiftyTwoWeekLow: Double?) -> Bool {
        guard isEnabled, price > 0 else { return false }

        switch condition {
        case .priceAbove:
            return price >= threshold
        case .priceBelow:
            return price <= threshold
        case .dailyChangeUp:
            return changePercent >= threshold
        case .dailyChangeDown:
            return changePercent <= -threshold
        case .near52WeekHigh:
            guard let high = fiftyTwoWeekHigh, high > 0 else { return false }
            return price >= high * (1 - threshold / 100)
        case .near52WeekLow:
            guard let low = fiftyTwoWeekLow, low > 0 else { return false }
            return price <= low * (1 + threshold / 100)
        // MA conditions are evaluated separately (crossing logic in `MovingAverage`)
        // and never pass through this fixed-threshold path.
        case .priceAboveSMA200, .priceBelowSMA200,
             .priceAboveEMA200, .priceBelowEMA200,
             .priceAboveWeeklySMA200, .priceBelowWeeklySMA200:
            return false
        }
    }

    /// Convenience over a live `PriceAlert` + `StockQuote`. Uses `alertPrice`, which
    /// reflects extended-hours moves but is nil during PRE/POST before the real
    /// extended-hours price arrives — so alerts never fire against the stale
    /// previous regular close.
    static func shouldFire(_ alert: PriceAlert, quote: StockQuote) -> Bool {
        guard let price = quote.alertPrice else { return false }
        return shouldFire(condition: alert.condition,
                          threshold: alert.threshold,
                          isEnabled: alert.isEnabled,
                          price: price,
                          changePercent: quote.changePercent,
                          fiftyTwoWeekHigh: quote.fiftyTwoWeekHigh,
                          fiftyTwoWeekLow: quote.fiftyTwoWeekLow)
    }

    /// Human-readable summary, e.g. "Price rises above 200.00" — used in the UI.
    static func describe(_ alert: PriceAlert, currencySymbol: String) -> String {
        switch alert.condition {
        case .priceAboveSMA200, .priceBelowSMA200,
             .priceAboveEMA200, .priceBelowEMA200,
             .priceAboveWeeklySMA200, .priceBelowWeeklySMA200:
            return alert.condition.label
        default:
            break
        }
        switch alert.condition.thresholdKind {
        case .price:
            return "\(alert.condition.label) \(currencySymbol)\(StorageService.formatNumber(alert.threshold, decimals: 2))"
        case .percent:
            switch alert.condition {
            case .near52WeekHigh, .near52WeekLow:
                return "\(alert.condition.label) (\u{2264} \(String(format: "%.1f", alert.threshold))%)"
            default:
                return "\(alert.condition.label) \(String(format: "%.1f", alert.threshold))%"
            }
        case .ma:
            return alert.condition.label
        }
    }
}

/// Pure rolling-average math over daily (or weekly-resampled) closes, plus the
/// cross detection that drives MA-based alerts. Unit under test.
enum MovingAverage {
    enum Kind: Equatable {
        case sma(period: Int)
        case ema(period: Int)
        case weeklySMA(period: Int)
    }

    static func value(kind: Kind, points: [PricePoint]) -> Double? {
        let daily = points.map(\.close)
        switch kind {
        case .sma(let period):
            return sma(daily, period: period)
        case .ema(let period):
            return ema(daily, period: period)
        case .weeklySMA(let period):
            return sma(weeklyCloses(from: points), period: period)
        }
    }

    /// Simple moving average over the last `period` closes. Nil when insufficient.
    static func sma(_ closes: [Double], period: Int) -> Double? {
        guard period > 0, closes.count >= period else { return nil }
        let window = closes.suffix(period)
        return window.reduce(0, +) / Double(period)
    }

    /// Exponential moving average with smoothing factor 2/(period+1), seeded
    /// with the first close and traversed chronologically. Nil when insufficient.
    static func ema(_ closes: [Double], period: Int) -> Double? {
        guard period > 0, !closes.isEmpty else { return nil }
        let k = 2.0 / Double(period + 1)
        var emaValue = closes[0]
        for c in closes.dropFirst() {
            emaValue = c * k + emaValue * (1 - k)
        }
        return emaValue
    }

    /// Resamples daily points into one close per ISO week — the last close of
    /// each week — preserving chronological order.
    static func weeklyCloses(from daily: [PricePoint], calendar: Calendar = .current) -> [Double] {
        let sorted = daily.sorted { $0.date < $1.date }
        var lastCloseByWeek: [Date: Double] = [:]
        for p in sorted where p.close.isFinite {
            let start = calendar.dateInterval(of: .weekOfYear, for: p.date)?.start
                ?? calendar.startOfDay(for: p.date)
            lastCloseByWeek[start] = p.close
        }
        return lastCloseByWeek.sorted { $0.key < $1.key }.map(\.value)
    }

    /// For a given condition, decides whether the price has just crossed the
    /// average AND records the new side. Returns `nil` when there is nothing to
    /// decide (no data, or the first evaluation — which only primes the state).
    /// - Returns: `(fire: Bool, newPositionAbove: Bool)` when evaluated.
    static func evaluateCross(condition: AlertCondition,
                              average: Double?,
                              price: Double,
                              wasAbove: Bool?) -> (fire: Bool, nowAbove: Bool)? {
        guard let average, average > 0, price > 0 else { return nil }
        let nowAbove = price >= average
        if wasAbove == nil {
            return (fire: false, nowAbove: nowAbove) // prime silently
        }
        let crossed = nowAbove != wasAbove
        return (fire: crossed, nowAbove: nowAbove)
    }
}
