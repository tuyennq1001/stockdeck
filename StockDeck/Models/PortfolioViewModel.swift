import SwiftUI
import Combine

/// Cached, throttled view model for PortfolioOverview to eliminate redundant
/// heavy computation on every real-time quote update during market hours.
@MainActor
@Observable
final class PortfolioViewModel {
    let scope: PortfolioWindowView.Scope

    private let stockService: StockService
    private let storageService: StorageService

    /// Debounced, pre-computed valuation — updated at most once per ~500ms, not per tick.
    private(set) var valuationCache: ValuationBundle = .empty

    /// Cached sorted holding list, computed once per valuation update.
    private(set) var sortedValuedHoldings: [ValuedHolding] = []

    /// Aggregated per-symbol data for position rows, piggybacked on valuation.
    private(set) var symbolAggregates: [String: SymbolAggregate] = [:]

    /// Performance & benchmark matrix — session-cached.
    private(set) var cachedPerformance: (portfolio: [PortfolioOverview.PerformancePeriod: Double?], spx: [PortfolioOverview.PerformancePeriod: Double?])? = nil

    /// Money-weighted return — session-cached.
    private(set) var moneyWeightedResult: InvestmentEffectiveness.Result? = nil

    /// Pending task handle for throttled valuation refresh.
    private var refreshTask: Task<Void, Never>?

    /// Subscription bag for Combine observation of quote changes.
    private var cancellable: AnyCancellable?

    init(scope: PortfolioWindowView.Scope, stockService: StockService, storageService: StorageService) {
        self.scope = scope
        self.stockService = stockService
        self.storageService = storageService

        // Debounce: wait 500ms after the last quote change before recomputing.
        cancellable = stockService.objectWillChange
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.invalidateValuation()
            }

        // Compute immediately on first access.
        recomputeAll()
    }

    // MARK: - Derived accessors

    var portfolios: [Portfolio] {
        switch scope {
        case .all: return storageService.portfolios
        case .portfolio(let id): return storageService.portfolios.filter { $0.id == id }
        }
    }

    var title: String {
        switch scope {
        case .all: return "Portfolio"
        case .portfolio(let id): return storageService.portfolios.first { $0.id == id }?.name ?? "Portfolio"
        }
    }

    var scopeKey: String {
        switch scope {
        case .all: return "all"
        case .portfolio(let id): return id.uuidString
        }
    }

    var currencySymbol: String { StorageService.currencySymbol(for: storageService.preferredCurrency) }
    var decimals: Int { storageService.percentDecimals }

    var totalValue: Double { valuationCache.totalValue }
    var totalCost: Double { valuationCache.totalCost }
    var totalPnl: Double { valuationCache.totalPnl }
    var totalPnlPercent: Double { valuationCache.totalPnlPercent }
    var dayChangeValue: Double { valuationCache.dayChangeValue }
    var dayChangePercent: Double { valuationCache.dayChangePercent }

    var symbols: [String] { Array(Set(portfolios.flatMap { $0.holdings.map(\.symbol) })) }

    var earliestPurchaseDate: Date? {
        let dates = sortedValuedHoldings.compactMap(\.holding.purchaseDate)
        return dates.min()
    }

    // MARK: - Invalidation & recomputation

    /// Called when scope changes (e.g. user switches portfolios).
    func scopeChanged() {
        recomputeAll()
    }

    private func invalidateValuation() {
        refreshTask?.cancel()
        refreshTask = Task {
            recomputeValuation()
        }
    }

    private func recomputeAll() {
        refreshTask?.cancel()
        recomputeValuation()
        recomputePerformance()
        recomputeMoneyWeightedReturn()
    }

    // MARK: - Valuation (single-pass, cached)

    struct SymbolAggregate {
        let value: Double
        let cost: Double
        let pnl: Double
        let pnlPercent: Double
        let nativeCost: Double
        let nativeValue: Double
        let nativePnl: Double
        /// Weighted-average buy price in the asset's native currency (JPY funds
        /// divided by the 10,000 scale so the number is a per-口 price).
        let avgPrice: Double
    }

    struct ValuationBundle {
        let totalValue: Double
        let totalCost: Double
        let totalPnl: Double
        let totalPnlPercent: Double
        let dayChangeValue: Double
        let dayChangePercent: Double

        static let empty = ValuationBundle(totalValue: 0, totalCost: 0, totalPnl: 0,
                                           totalPnlPercent: 0, dayChangeValue: 0, dayChangePercent: 0)
    }

    private func recomputeValuation() {
        var valued: [ValuedHolding] = []
        var totalVal = 0.0
        var todayInputs: [TodayPerformance.Input] = []
        var bySymbol: [String: (value: Double, cost: Double, pnl: Double, nativeCost: Double, nativeValue: Double, nativePnl: Double, nativeQty: Double)] = [:]
        var missingCostSymbols: Set<String> = []

        for portfolio in portfolios {
            for holding in portfolio.holdings {
                // Missing live quote → price .nan, identical to
                // PortfolioValuation.resolveInputs(). An unpriced holding must
                // contribute 0 to value/P&L here, exactly like the menu bar,
                // sidebar, and popover — never a phantom value at avgPrice.
                let quote = stockService.quotes[holding.symbol] ?? stockService.quotes[holding.symbol.uppercased()] ?? StockQuote(
                    symbol: holding.symbol,
                    name: holding.symbol,
                    price: .nan,
                    change: 0,
                    changePercent: 0,
                    currency: stockService.detectedCurrency(for: holding.symbol)
                )
                let price = quote.price
                let currency = stockService.detectedCurrency(for: holding.symbol)
                let rate = stockService.rate(from: currency)
                let costRate = stockService.rate(from: currency, for: holding.purchaseDate)
                let isJpFund = quote.isJapaneseFund || stockService.isJapaneseMutualFund(holding.symbol) || holding.isJapaneseFund
                let scale = isJpFund ? 10000.0 : 1.0
                let lev = holding.effectiveLeverage
                let qty = holding.quantity
                let hasCost = holding.hasKnownCostBasis
                // Match PortfolioValuation.totals() exactly: market value depends
                // only on a live price, never on cost basis. A holding with a
                // quote but no known cost (e.g. Binance balances without order
                // history) still counts toward Total Value; only its cost is 0.
                let value = price.isFinite ? (price / scale) * qty * lev * rate : 0
                let cost = hasCost
                    ? (holding.avgPrice / scale) * qty * lev * costRate
                    : 0

                totalVal += value

                // Native-currency aggregates for position rows
                let nativeVal = price.isFinite ? holding.marketValue(currentPrice: price) : 0
                let nativeCst = holding.costBasisLocal
                let nativePnl = holding.pnl(currentPrice: price)

                let sym = StockService.canonicalSymbol(for: holding.symbol)
                if !hasCost {
                    missingCostSymbols.insert(sym)
                }
                var existing = bySymbol[sym] ?? (0, 0, 0, 0, 0, 0, 0)
                existing.value += value
                existing.cost += cost
                // P&L only for holdings with a known cost basis — a Binance
                // balance without order history has cost 0, so value − cost would
                // fabricate the entire market value as profit.
                existing.pnl += (hasCost && price.isFinite) ? (value - cost) : 0
                existing.nativeCost += nativeCst
                existing.nativeValue += nativeVal
                existing.nativePnl += nativePnl
                if hasCost {
                    existing.nativeQty += abs(qty * lev)
                }
                bySymbol[sym] = existing

                // ValuedHolding still stores preferred-currency value/cost for legacy compatibility
                valued.append(ValuedHolding(
                    id: holding.id, portfolioId: portfolio.id, holding: holding, quote: quote,
                    value: value, cost: cost, dayChangePercent: quote.changePercent,
                    type: storageService.type(for: holding.symbol)
                ))

                if let liveQuote = stockService.quotes[holding.symbol] ?? stockService.quotes[holding.symbol.uppercased()] {
                    todayInputs.append(TodayPerformance.Input(
                        holding: holding,
                        regularPrice: liveQuote.price,
                        previousClose: liveQuote.previousClose,
                        rate: rate
                    ))
                }
            }
        }

        valued.sort { abs($0.value) > abs($1.value) }
        sortedValuedHoldings = valued

        // Cost basis is all-or-nothing per symbol: a symbol with ANY lot missing
        // its cost basis (e.g. a Binance balance where one batch has order history
        // and another doesn't) is treated as having an unknown cost — its entire
        // cost basis, P&L, and native aggregates are excluded from the totals so
        // a partially-known profit is never counted. Matches
        // PortfolioValuation.totals().
        for sym in missingCostSymbols {
            guard var data = bySymbol[sym] else { continue }
            data.cost = 0
            data.pnl = 0
            data.nativeCost = 0
            data.nativePnl = 0
            data.nativeQty = 0
            bySymbol[sym] = data
        }

        var totalCst = 0.0
        var pnl = 0.0
        for agg in bySymbol.values {
            totalCst += agg.cost
            pnl += agg.pnl
        }
        let pnlPct = abs(totalCst) >= 0.01 ? (pnl / abs(totalCst)) * 100 : 0
        let todayTotals = TodayPerformance.totals(todayInputs)

        valuationCache = ValuationBundle(
            totalValue: totalVal,
            totalCost: totalCst,
            totalPnl: pnl,
            totalPnlPercent: pnlPct,
            dayChangeValue: todayTotals.gain,
            dayChangePercent: todayTotals.percent
        )

        // Build symbol aggregates from our single pass
        var symAggs: [String: SymbolAggregate] = [:]
        for (sym, data) in bySymbol {
            let pnlPctSym = abs(data.cost) >= 0.01 ? (data.pnl / abs(data.cost)) * 100 : 0
            let avg = data.nativeQty > 0 ? data.nativeCost / data.nativeQty : .nan
            symAggs[sym] = SymbolAggregate(
                value: data.value,
                cost: data.cost,
                pnl: data.pnl,
                pnlPercent: pnlPctSym,
                nativeCost: data.nativeCost,
                nativeValue: data.nativeValue,
                nativePnl: data.nativePnl,
                avgPrice: avg
            )
        }
        symbolAggregates = symAggs
    }

    // MARK: - Performance & Benchmark

    private func recomputePerformance() {
        let hs = portfolios.flatMap { $0.holdings }
        let holdingsFingerprint = hs.map {
            "\($0.symbol):\($0.quantity):\($0.avgPrice):\($0.effectiveLeverage)"
        }.joined(separator: ";")
        let fullKey = "\(scopeKey):\(holdingsFingerprint)"

        let inception = earliestPurchaseDate
        let svc = stockService

        cachedPerformance = PerformanceBenchmarkCache.performance(for: fullKey) {
            var histBySymbol: [String: [PricePoint]] = [:]
            for h in hs {
                histBySymbol[h.symbol] = svc.priceHistoryMax[h.symbol] ?? svc.priceHistory[h.symbol] ?? []
            }
            let maxPoints = valueSeries(from: histBySymbol)
            var pDict: [PortfolioOverview.PerformancePeriod: Double?] = [:]
            var sDict: [PortfolioOverview.PerformancePeriod: Double?] = [:]
            for period in PortfolioOverview.PerformancePeriod.allCases {
                pDict[period] = Self.portfolioPerformance(for: period, points: maxPoints, inception: inception)
                sDict[period] = Self.spxPerformance(for: period, stockService: svc)
            }
            return (pDict, sDict)
        }
    }

    static func portfolioPerformance(for period: PortfolioOverview.PerformancePeriod,
                                      points: [ValuePoint],
                                      inception: Date?) -> Double? {
        guard points.count >= 2, let lastVal = points.last?.value, abs(lastVal) > 1e-9 else { return nil }
        let cutoff = period.cutoffDate()
        let graceCutoff = cutoff.addingTimeInterval(7 * 86400)

        if (period == .y5 || period == .y10), let inception {
            guard inception <= graceCutoff else { return nil }
        }

        guard let startPoint = points.last(where: { $0.date <= cutoff }) ?? points.first(where: { $0.date <= graceCutoff }),
              abs(startPoint.value) > 1e-9 else { return nil }
        return ((lastVal - startPoint.value) / abs(startPoint.value)) * 100
    }

    static func spxPerformance(for period: PortfolioOverview.PerformancePeriod,
                                stockService: StockService) -> Double? {
        let points = stockService.priceHistoryMax["^GSPC"] ?? stockService.priceHistory["^GSPC"] ?? []
        guard points.count >= 2, let lastPrice = points.last?.close, abs(lastPrice) > 1e-9 else { return nil }
        let cutoff = period.cutoffDate()
        let graceCutoff = cutoff.addingTimeInterval(7 * 86400)
        guard let startPoint = points.last(where: { $0.date <= cutoff }) ?? points.first(where: { $0.date <= graceCutoff }),
              abs(startPoint.close) > 1e-9 else { return nil }
        return ((lastPrice - startPoint.close) / abs(startPoint.close)) * 100
    }

    // MARK: - Money-weighted return

    private func recomputeMoneyWeightedReturn() {
        let hs = portfolios.flatMap { $0.holdings }
        let holdingsFingerprint = hs.map {
            "\($0.symbol):\($0.quantity):\($0.avgPrice):\($0.effectiveLeverage):\($0.purchaseDate?.timeIntervalSince1970 ?? 0)"
        }.joined(separator: ";")
        let fullKey = "\(scopeKey):\(holdingsFingerprint)"

        moneyWeightedResult = MoneyWeightedReturnCache.result(for: fullKey) {
            InvestmentEffectiveness.evaluate(
                holdings: hs,
                stockService: stockService,
                storageService: storageService
            )
        }
    }

    // MARK: - Value series helpers (used by PortfolioOverview still)

    func valueSeries(from histBySymbol: [String: [PricePoint]]) -> [ValuePoint] {
        let hs = portfolios.flatMap { $0.holdings }
        var rate: [String: Double] = [:]
        var hist: [String: [PricePoint]] = [:]
        for h in hs {
            let curr = stockService.detectedCurrency(for: h.symbol)
            rate[h.symbol] = stockService.rate(from: curr)
            if let ph = histBySymbol[h.symbol] { hist[h.symbol] = ph }
        }
        return PortfolioBackfill.series(holdings: hs, historyBySymbol: hist, rateBySymbol: rate)
    }
}