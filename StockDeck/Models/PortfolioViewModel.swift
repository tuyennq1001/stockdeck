import SwiftUI
import Combine

/// Hero chart range — a pure UI filter over the value series.
enum ChartRange: String, CaseIterable {
    case week = "7D", month = "1M", threeMonths = "3M", sixMonths = "6M", ytd = "YTD", year = "1Y", threeYears = "3Y", fiveYears = "5Y", all = "All"
    var days: Int? {
        switch self {
        case .week: return 7
        case .month: return 30
        case .threeMonths: return 90
        case .sixMonths: return 180
        case .ytd:
            let cal = Calendar.current
            let now = Date()
            let jan1 = cal.date(from: cal.dateComponents([.year], from: now)) ?? now
            return max(1, cal.dateComponents([.day], from: jan1, to: now).day ?? 30)
        case .year: return 365
        case .threeYears: return 365 * 3
        case .fiveYears: return 365 * 5
        case .all: return nil
        }
    }
    /// Suffix for the hero pill, describing the span it measures.
    var changeLabel: String {
        switch self {
        case .week: return "past 7d"
        case .month: return "past 1M"
        case .threeMonths: return "past 3M"
        case .sixMonths: return "past 6M"
        case .ytd: return "YTD"
        case .year: return "past 1Y"
        case .threeYears: return "past 3Y"
        case .fiveYears: return "past 5Y"
        case .all: return "all-time"
        }
    }
    var performancePeriod: PortfolioOverview.PerformancePeriod? {
        switch self {
        case .month: return .m1
        case .threeMonths: return .m3
        case .sixMonths: return .m6
        case .ytd: return .ytd
        case .year: return .y1
        case .threeYears: return .y3
        case .fiveYears: return .y5
        case .week, .all: return nil
        }
    }
}

/// Cached, throttled view model for PortfolioOverview to eliminate redundant
/// heavy computation on every real-time quote update during market hours.
@MainActor
@Observable
final class PortfolioViewModel {
    var scope: PortfolioScope {
        didSet {
            recomputeValuation()
        }
    }

    private var stockService: StockService?
    private var storageService: StorageService?

    /// Debounced, pre-computed valuation — updated at most once per ~500ms, not per tick.
    private(set) var valuationCache: ValuationBundle = .empty

    /// Cached sorted holding list, computed once per valuation update.
    private(set) var sortedValuedHoldings: [ValuedHolding] = []

    /// Aggregated per-symbol data for position rows, piggybacked on valuation.
    private(set) var symbolAggregates: [String: SymbolAggregate] = [:]

    struct AllocationSlice: Identifiable, Sendable {
        let id: String
        let symbol: String
        let value: Double
        let fraction: Double
    }
    private(set) var allocation: [AllocationSlice] = []
    private(set) var topGainers: [ValuedHolding] = []
    private(set) var topLosers: [ValuedHolding] = []

    public struct RealizedStats: Sendable {
        public let realizedPnl: Double
        public let closedCost: Double
        public let winRate: Double
        public let totalClosed: Int

        public static let empty = RealizedStats(realizedPnl: 0, closedCost: 0, winRate: 0, totalClosed: 0)
    }

    private(set) var realizedStats: RealizedStats = .empty
    private(set) var transactionsCount: Int = 0
    private(set) var typeBreakdown: [(label: String, fraction: Double)] = []
    private(set) var activeSymbolsCount: Int = 0

    /// Performance & benchmark matrix — session-cached.
    private(set) var cachedPerformance: (portfolio: [PortfolioOverview.PerformancePeriod: Double?], spx: [PortfolioOverview.PerformancePeriod: Double?])? = nil

    /// Money-weighted return — session-cached.
    private(set) var moneyWeightedResult: InvestmentEffectiveness.Result? = nil
    
    /// Cached display series per chart range, cleared on valuation update.
    @ObservationIgnored
    private var displaySeriesCache: [ChartRange: [ValuePoint]] = [:]
    
    /// Pre-grouped holdings by canonical symbol, cached on valuation update.
    private(set) var groupedHoldings: [String: [ValuedHolding]] = [:]

    @ObservationIgnored
    private var dailyPnlCache: [DailyPnlRange: [DailyPnlRow]] = [:]
    @ObservationIgnored
    private var monthlyPnlCache: [MonthlyPnlRange: [MonthlyPnlRow]] = [:]
    @ObservationIgnored
    private var sortedSymbolsCache: (key: String, result: [String])? = nil
    
    private var refreshTask: Task<Void, Never>?

    /// Subscription bag for Combine observation of quote changes.
    private var cancellable: AnyCancellable?

    init(scope: PortfolioScope) {
        self.scope = scope
    }

    func setup(stockService: StockService, storageService: StorageService) {
        guard self.stockService == nil else { return } // Setup only once
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
        guard let storageService = storageService else { return [] }
        switch scope {
        case .all: return storageService.portfolios
        case .portfolio(let id): return storageService.portfolios.filter { $0.id == id }
        }
    }

    var title: String {
        guard let storageService = storageService else { return "Portfolio" }
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

    var currencySymbol: String {
        guard let storageService = storageService else { return "$" }
        return StorageService.currencySymbol(for: storageService.preferredCurrency) 
    }
    var decimals: Int { storageService?.percentDecimals ?? 2 }

    var totalValue: Double { valuationCache.totalValue }
    var totalCost: Double { valuationCache.totalCost }
    var totalPnl: Double { valuationCache.totalPnl }
    var totalPnlPercent: Double { valuationCache.totalPnlPercent }
    var dayChangeValue: Double { valuationCache.dayChangeValue }
    var dayChangePercent: Double { valuationCache.dayChangePercent }

    var symbols: [String] { Array(Set(portfolios.flatMap { $0.holdings.map(\.symbol) })).sorted() }

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

    struct SymbolAggregate: Sendable, Identifiable {
        let id: String
        var symbol: String { id }
        let value: Double
        let cost: Double
        let pnl: Double
        let pnlPercent: Double
        let nativeCost: Double
        let nativeValue: Double
        let nativePnl: Double
        let nativePnlPercent: Double
        /// Weighted-average buy price in the asset's native currency (JPY funds
        /// divided by the 10,000 scale so the number is a per-口 price).
        let avgPrice: Double
        let totalQuantity: Double
        let todayPnl: Double
        let changePercent: Double
        let extendedChangePercent: Double?
        let nativeCurrencySymbol: String
        let lotsCount: Int
        let hasCostBasis: Bool
        let isMarketActive: Bool
        let quote: StockQuote?
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
        guard let stockService = stockService, let storageService = storageService else { return }
        displaySeriesCache.removeAll(keepingCapacity: true)
        dailyPnlCache.removeAll(keepingCapacity: true)
        monthlyPnlCache.removeAll(keepingCapacity: true)
        sortedSymbolsCache = nil
        var valued: [ValuedHolding] = []
        var totalVal = 0.0
        var todayInputs: [TodayPerformance.Input] = []
        var bySymbol: [String: (value: Double, cost: Double, pnl: Double, nativeCost: Double, nativeValue: Double, nativePnl: Double, nativeQty: Double, totalQty: Double, todayPnl: Double, changePercent: Double, extendedChangePercent: Double?, lotsCount: Int, isMarketActive: Bool, quote: StockQuote?)] = [:]
        var missingCostSymbols: Set<String> = []

        for portfolio in portfolios {
            for holding in portfolio.holdings {
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
                let value = price.isFinite ? (price / scale) * qty * lev * rate : 0
                let cost = hasCost
                    ? (holding.avgPrice / scale) * qty * lev * costRate
                    : 0

                totalVal += value

                let nativeVal = price.isFinite ? holding.marketValue(currentPrice: price) : 0
                let nativeCst = holding.costBasisLocal
                let nativePnl = holding.pnl(currentPrice: price)

                let sym = StockService.canonicalSymbol(for: holding.symbol)
                let isCrypto = storageService.type(for: holding.symbol) == "CRYPTOCURRENCY" || HomeAIInsightService.cryptoBaseAsset(for: holding.symbol) != nil
                let isMarketActive = MarketCategory.isTradingDay(symbol: holding.symbol, quote: quote, isCrypto: isCrypto)

                if !hasCost {
                    missingCostSymbols.insert(sym)
                }
                var existing = bySymbol[sym] ?? (0, 0, 0, 0, 0, 0, 0, 0, 0, isMarketActive ? quote.changePercent : 0, isMarketActive ? quote.extendedChangePercent : nil, 0, isMarketActive, quote)
                existing.value += value
                existing.cost += cost
                existing.pnl += (hasCost && price.isFinite) ? (value - cost) : 0
                existing.nativeCost += nativeCst
                existing.nativeValue += nativeVal
                existing.nativePnl += nativePnl
                if hasCost {
                    existing.nativeQty += abs(qty * lev)
                }
                existing.totalQty += qty
                existing.todayPnl += isMarketActive ? ((quote.change / scale) * qty * lev) : 0
                existing.lotsCount += 1
                bySymbol[sym] = existing

                valued.append(ValuedHolding(
                    id: holding.id, portfolioId: portfolio.id, holding: holding, quote: quote,
                    value: value, cost: cost, dayChangePercent: isMarketActive ? quote.changePercent : 0,
                    type: storageService.type(for: holding.symbol)
                ))

                if let liveQuote = stockService.quotes[holding.symbol] ?? stockService.quotes[holding.symbol.uppercased()] {
                    todayInputs.append(TodayPerformance.Input(
                        holding: holding,
                        regularPrice: liveQuote.price,
                        previousClose: liveQuote.previousClose,
                        rate: rate,
                        isMarketActiveToday: isMarketActive
                    ))
                }
            }
        }

        valued.sort { abs($0.value) > abs($1.value) }
        sortedValuedHoldings = valued
        groupedHoldings = Dictionary(grouping: valued) { StockService.canonicalSymbol(for: $0.symbol) }

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
            let nativePnlPct = abs(data.nativeCost) >= 0.01 ? (data.nativePnl / abs(data.nativeCost)) * 100 : 0
            let avg = data.nativeQty > 0 ? data.nativeCost / data.nativeQty : .nan
            let curr = stockService.detectedCurrency(for: sym)
            symAggs[sym] = SymbolAggregate(
                id: sym,
                value: data.value,
                cost: data.cost,
                pnl: data.pnl,
                pnlPercent: nativePnlPct,
                nativeCost: data.nativeCost,
                nativeValue: data.nativeValue,
                nativePnl: data.nativePnl,
                nativePnlPercent: nativePnlPct,
                avgPrice: avg,
                totalQuantity: data.totalQty,
                todayPnl: data.todayPnl,
                changePercent: data.changePercent,
                extendedChangePercent: data.extendedChangePercent,
                nativeCurrencySymbol: StorageService.currencySymbol(for: curr),
                lotsCount: data.lotsCount,
                hasCostBasis: !missingCostSymbols.contains(sym),
                isMarketActive: data.isMarketActive,
                quote: data.quote
            )
        }
        symbolAggregates = symAggs

        // Compute Allocation
        if abs(totalVal) >= 0.01 {
            var allocMap: [String: Double] = [:]
            for (sym, agg) in symAggs {
                allocMap[sym] = abs(agg.value)
            }
            allocation = allocMap.map { AllocationSlice(id: $0.key, symbol: $0.key, value: $0.value, fraction: $0.value / abs(totalVal)) }
                .sorted { $0.value > $1.value }
        } else {
            allocation = []
        }

        // Compute Top Gainers / Losers
        var seen = Set<String>()
        var gainers: [ValuedHolding] = []
        var losers: [ValuedHolding] = []
        let sortedDesc = valued.sorted { $0.dayChangePercent > $1.dayChangePercent }
        
        for h in sortedDesc {
            if seen.insert(h.symbol).inserted {
                if h.dayChangePercent > 0 { gainers.append(h) }
            }
        }
        topGainers = Array(gainers.prefix(5))

        seen.removeAll()
        for h in sortedDesc.reversed() {
            if seen.insert(h.symbol).inserted {
                if h.dayChangePercent < 0 { losers.append(h) }
            }
        }
        topLosers = Array(losers.prefix(5))

        // Realized PnL stats (cached once per valuation)
        var rawClosed: [(trade: ClosedTrade, portfolioId: UUID, portfolioName: String)] = []
        for p in portfolios {
            for t in p.closedTrades {
                rawClosed.append((t, p.id, p.name))
            }
        }
        let consolidatedClosed = ConsolidatedClosedTrade.consolidate(tradesWithPortfolio: rawClosed)
        var totalRealized: Double = 0
        var totalClosedCost: Double = 0
        var winCount: Int = 0

        for ct in consolidatedClosed {
            let curr = stockService.detectedCurrency(for: ct.symbol)
            let rate = stockService.rate(from: curr)
            totalRealized += ct.realizedPnl * rate
            totalClosedCost += ct.costBasis * rate
            if ct.realizedPnl > 0 {
                winCount += 1
            }
        }
        let totalClosed = consolidatedClosed.count
        let winRate = totalClosed > 0 ? (Double(winCount) / Double(totalClosed)) * 100.0 : 0.0
        realizedStats = RealizedStats(
            realizedPnl: totalRealized,
            closedCost: totalClosedCost,
            winRate: winRate,
            totalClosed: totalClosed
        )

        // Transactions count (cached once per valuation)
        var rawTx: [(tx: Transaction, portfolioId: UUID, portfolioName: String)] = []
        for p in portfolios {
            for tx in p.transactions {
                rawTx.append((tx, p.id, p.name))
            }
        }
        transactionsCount = ConsolidatedTransaction.consolidate(transactionsWithPortfolio: rawTx).count

        // Active symbols count (unique canonical symbols in active holdings)
        activeSymbolsCount = symAggs.count

        // Type diversification breakdown (cached once per valuation)
        let totalValForTypes = valued.reduce(0) { $0 + abs($1.value) }
        if totalValForTypes >= 0.01 {
            var byType: [String: Double] = [:]
            for h in valued {
                byType[Self.typeLabel(h.type), default: 0] += abs(h.value)
            }
            typeBreakdown = byType.map { ($0.key, $0.value / totalValForTypes) }.sorted { $0.1 > $1.1 }
        } else {
            typeBreakdown = []
        }
    }

    public static func typeLabel(_ type: String) -> String {
        switch type.uppercased() {
        case "EQUITY": return "Stocks"
        case "ETF": return "ETFs"
        case "CRYPTOCURRENCY": return "Crypto"
        case "INDEX": return "Indices"
        case "FUTURE": return "Futures"
        case "MUTUALFUND": return "Funds"
        case "CURRENCY": return "Currency"
        case "": return "Other"
        default: return type.capitalized
        }
    }

    func sortedSymbols(column: PortfolioOverview.PositionSortColumn, ascending: Bool, manualOrder: [String]) -> [String] {
        let cacheKey = "\(column.rawValue):\(ascending):\(manualOrder.hashValue):\(symbolAggregates.count):\(totalValue)"
        if let cached = sortedSymbolsCache, cached.key == cacheKey {
            return cached.result
        }
        if column == .manual {
            let result = manualOrder.filter { symbolAggregates[$0] != nil }
            sortedSymbolsCache = (cacheKey, result)
            return result
        }
        let result = symbolAggregates.keys.sorted { sym1, sym2 in
            let isAsc = ascending
            switch column {
            case .manual:
                return false
            case .symbol:
                return isAsc ? sym1 < sym2 : sym1 > sym2
            case .avgPrice:
                let a1 = symbolAggregates[sym1]?.avgPrice ?? .nan
                let a2 = symbolAggregates[sym2]?.avgPrice ?? .nan
                return isAsc ? a1 < a2 : a1 > a2
            case .price:
                let p1 = symbolAggregates[sym1]?.changePercent ?? 0
                let p2 = symbolAggregates[sym2]?.changePercent ?? 0
                return isAsc ? p1 < p2 : p1 > p2
            case .extended:
                let e1 = symbolAggregates[sym1]?.extendedChangePercent
                let e2 = symbolAggregates[sym2]?.extendedChangePercent
                switch (e1, e2) {
                case let (l?, r?): return isAsc ? l < r : l > r
                case (_?, nil): return true
                case (nil, _?): return false
                case (nil, nil): return isAsc ? sym1 < sym2 : sym1 > sym2
                }
            case .cost:
                let c1 = symbolAggregates[sym1]?.nativeCost ?? 0
                let c2 = symbolAggregates[sym2]?.nativeCost ?? 0
                return isAsc ? c1 < c2 : c1 > c2
            case .value:
                let v1 = symbolAggregates[sym1]?.value ?? 0
                let v2 = symbolAggregates[sym2]?.value ?? 0
                return isAsc ? v1 < v2 : v1 > v2
            case .todayPnl:
                let t1 = symbolAggregates[sym1]?.todayPnl ?? 0
                let t2 = symbolAggregates[sym2]?.todayPnl ?? 0
                return isAsc ? t1 < t2 : t1 > t2
            case .pnl:
                let pnl1 = symbolAggregates[sym1]?.pnl ?? 0
                let pnl2 = symbolAggregates[sym2]?.pnl ?? 0
                return isAsc ? pnl1 < pnl2 : pnl1 > pnl2
            case .shares:
                let s1 = symbolAggregates[sym1]?.totalQuantity ?? 0
                let s2 = symbolAggregates[sym2]?.totalQuantity ?? 0
                return isAsc ? s1 < s2 : s1 > s2
            case .weight:
                let w1 = abs(totalValue) >= 0.01 ? (abs(symbolAggregates[sym1]?.value ?? 0) / abs(totalValue) * 100) : 0
                let w2 = abs(totalValue) >= 0.01 ? (abs(symbolAggregates[sym2]?.value ?? 0) / abs(totalValue) * 100) : 0
                return isAsc ? w1 < w2 : w1 > w2
            }
        }
        sortedSymbolsCache = (cacheKey, result)
        return result
    }

    // MARK: - Performance & Benchmark

    private func recomputePerformance() {
        guard let stockService = stockService else { return }
        let hs = portfolios.flatMap { $0.holdings }
        let holdingsFingerprint = hs.map {
            "\($0.symbol):\($0.quantity):\($0.avgPrice):\($0.effectiveLeverage):\($0.purchaseDate?.timeIntervalSince1970 ?? 0)"
        }.joined(separator: ";")
        let fullKey = "\(scopeKey):\(holdingsFingerprint)"

        let inception = earliestPurchaseDate
        let svc = stockService

        cachedPerformance = PerformanceBenchmarkCache.performance(for: fullKey) {
            var pDict: [PortfolioOverview.PerformancePeriod: Double?] = [:]
            var sDict: [PortfolioOverview.PerformancePeriod: Double?] = [:]
            for period in PortfolioOverview.PerformancePeriod.allCases {
                pDict[period] = Self.portfolioPerformance(for: period, holdings: hs, stockService: svc, inception: inception)
                sDict[period] = Self.spxPerformance(for: period, stockService: svc)
            }
            return (pDict, sDict)
        }
    }

    static func portfolioPerformance(for period: PortfolioOverview.PerformancePeriod,
                                      holdings: [Holding],
                                      stockService: StockService,
                                      inception: Date?) -> Double? {
        guard !holdings.isEmpty else { return nil }
        let cutoff = period.cutoffDate()
        let graceCutoff = cutoff.addingTimeInterval(7 * 86400)

        // Only enforce inception limit if ALL holdings have known purchase dates
        let hasUndatedHoldings = holdings.contains(where: { $0.purchaseDate == nil })
        if let inception, !hasUndatedHoldings {
            guard inception <= graceCutoff else { return nil }
        }

        var currentTotalValue = 0.0
        var cutoffTotalValue = 0.0
        var hasValidCutoffData = false

        for h in holdings {
            let scale = (h.isJapaneseFund || StockService.codeToFundNameMap[h.symbol] != nil) ? 10000.0 : 1.0
            let rate = stockService.rate(from: stockService.detectedCurrency(for: h.symbol))
            let qty = h.quantity.isFinite ? h.quantity : 0
            let lev = h.effectiveLeverage.isFinite ? h.effectiveLeverage : 1

            // Current price
            let liveQuote = stockService.quotes[h.symbol] ?? stockService.quotes[h.symbol.uppercased()]
            let rawCurrentPrice = liveQuote?.price ?? (h.avgPrice.isFinite && h.avgPrice > 0 ? h.avgPrice : nil)

            let points = (stockService.priceHistory[h.symbol] ?? stockService.priceHistoryMax[h.symbol] ?? [])
                .filter { $0.close.isFinite && $0.close > 0 }
                .sorted { $0.date < $1.date }

            let currPrice: Double
            if let raw = rawCurrentPrice, raw.isFinite, raw > 0 {
                currPrice = raw
            } else if let lastPoint = points.last {
                currPrice = lastPoint.close
            } else {
                continue
            }

            let curVal = (currPrice / scale) * qty * lev * rate
            currentTotalValue += curVal

            // Cutoff price from daily price history (exact daily closes)
            let baselinePoint = points.last(where: { $0.date <= cutoff })
                ?? points.first(where: { $0.date <= graceCutoff })

            let cutoffPrice: Double
            if let base = baselinePoint {
                cutoffPrice = base.close
                hasValidCutoffData = true
            } else if let firstPoint = points.first {
                cutoffPrice = firstPoint.close
            } else if h.avgPrice.isFinite && h.avgPrice > 0 {
                cutoffPrice = h.avgPrice
            } else {
                cutoffPrice = currPrice
            }

            let cutVal = (cutoffPrice / scale) * qty * lev * rate
            cutoffTotalValue += cutVal
        }

        guard hasValidCutoffData, cutoffTotalValue > 1e-9, currentTotalValue > 1e-9 else { return nil }
        return ((currentTotalValue - cutoffTotalValue) / cutoffTotalValue) * 100
    }

    static func spxPerformance(for period: PortfolioOverview.PerformancePeriod,
                                stockService: StockService) -> Double? {
        let points = (stockService.priceHistory["^GSPC"] ?? stockService.priceHistoryMax["^GSPC"] ?? [])
            .filter { $0.close.isFinite && $0.close > 0 }
            .sorted { $0.date < $1.date }
        guard points.count >= 2, let lastPrice = points.last?.close, abs(lastPrice) > 1e-9 else { return nil }
        let cutoff = period.cutoffDate()
        let graceCutoff = cutoff.addingTimeInterval(7 * 86400)
        guard let startPoint = points.last(where: { $0.date <= cutoff }) ?? points.first(where: { $0.date <= graceCutoff }),
              abs(startPoint.close) > 1e-9 else { return nil }
        return ((lastPrice - startPoint.close) / abs(startPoint.close)) * 100
    }

    // MARK: - Money-weighted return

    private func recomputeMoneyWeightedReturn() {
        guard let stockService = stockService, let storageService = storageService else { return }
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
        guard let stockService = stockService else { return [] }
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

    /// Daily value curve (2y) for 1M/1Y; monthly full history for 3Y, 5Y, and "All".
    /// Uses the unified valueSeries representing the true market value trajectory of the portfolio.
    func dailyPnlRows(for range: DailyPnlRange) -> [DailyPnlRow] {
        if let cached = dailyPnlCache[range] { return cached }
        guard let stockService = stockService else { return [] }
        let hs = portfolios.flatMap { $0.holdings }
        let closed = portfolios.flatMap { $0.closedTrades }
        var histBySymbol: [String: [PricePoint]] = [:]
        for h in hs {
            histBySymbol[h.symbol] = stockService.priceHistory[h.symbol] ?? []
        }
        var rateBySymbol: [String: Double] = [:]
        for h in hs {
            rateBySymbol[h.symbol] = stockService.rate(from: stockService.detectedCurrency(for: h.symbol))
        }
        for ct in closed {
            if rateBySymbol[ct.symbol] == nil {
                rateBySymbol[ct.symbol] = stockService.rate(from: stockService.detectedCurrency(for: ct.symbol))
            }
        }
        let rows = DailyPnl.rows(
            holdings: hs,
            closedTrades: closed,
            historyBySymbol: histBySymbol,
            rateBySymbol: rateBySymbol,
            dayCount: range.dayCount
        )
        dailyPnlCache[range] = rows
        return rows
    }

    func monthlyPnlRows(for range: MonthlyPnlRange) -> [MonthlyPnlRow] {
        if let cached = monthlyPnlCache[range] { return cached }
        guard let stockService = stockService else { return [] }
        let hs = portfolios.flatMap { $0.holdings }
        let closed = portfolios.flatMap { $0.closedTrades }
        var histBySymbol: [String: [PricePoint]] = [:]
        for h in hs {
            histBySymbol[h.symbol] = stockService.priceHistoryMax[h.symbol]
                ?? stockService.priceHistory[h.symbol]
                ?? []
        }
        let monthCount: Int
        if let fixed = range.fixedMonthCount {
            monthCount = fixed
        } else {
            let today = Date()
            let calendar = Calendar.current
            var span = 1
            let earliestDate = (hs.compactMap(\.purchaseDate) + closed.compactMap(\.buyDate)).min()
            if let earliest = earliestDate,
               let months = calendar.dateComponents([.month], from: earliest, to: today).month {
                span = max(span, months + 1)
            }
            let historySpan = MonthlyPnl.monthCount(for: histBySymbol, today: today, calendar: calendar, maxMonths: 240)
            monthCount = min(max(span, historySpan), 240)
        }
        var rateBySymbol: [String: Double] = [:]
        for h in hs {
            rateBySymbol[h.symbol] = stockService.rate(from: stockService.detectedCurrency(for: h.symbol))
        }
        for ct in closed {
            if rateBySymbol[ct.symbol] == nil {
                rateBySymbol[ct.symbol] = stockService.rate(from: stockService.detectedCurrency(for: ct.symbol))
            }
        }
        let rows = MonthlyPnl.rows(
            holdings: hs,
            closedTrades: closed,
            historyBySymbol: histBySymbol,
            rateBySymbol: rateBySymbol,
            monthCount: monthCount
        )
        monthlyPnlCache[range] = rows
        return rows
    }

    func displaySeries(for chartRange: ChartRange) -> [ValuePoint] {
        guard let stockService = stockService else { return [] }
        if let cached = displaySeriesCache[chartRange] {
            return cached
        }

        let computed: [ValuePoint]
        if chartRange == .week {
            computed = valueSeries(from: stockService.intradayWeek)
        } else {
            var cutoff: Date? = nil
            if let days = chartRange.days {
                cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date())
            } else if chartRange == .all {
                if let purchaseDate = earliestPurchaseDate {
                    cutoff = Calendar.current.startOfDay(for: purchaseDate)
                } else {
                    cutoff = Calendar.current.date(byAdding: .year, value: -5, to: Date())
                }
            }

            let allHoldingsDated = !portfolios.flatMap(\.holdings).contains(where: { $0.purchaseDate == nil })
            if allHoldingsDated, let purchaseDate = earliestPurchaseDate {
                let absoluteCutoff = Calendar.current.startOfDay(for: purchaseDate)
                if let current = cutoff {
                    cutoff = max(current, absoluteCutoff)
                } else {
                    cutoff = absoluteCutoff
                }
            }

            let daysSpan: Int
            if let c = cutoff {
                daysSpan = Calendar.current.dateComponents([.day], from: c, to: Date()).day ?? 9999
            } else {
                daysSpan = 9999
            }

            let useMax = daysSpan > 730
            let originalSource = useMax ? stockService.priceHistoryMax : stockService.priceHistory

            var source = originalSource
            if let cutoffDate = cutoff {
                var hasData = false
                for (sym, points) in source {
                    var filtered = points.filter { $0.date >= cutoffDate }
                    if let before = points.last(where: { $0.date < cutoffDate }) {
                        filtered.insert(before, at: 0)
                    }
                    source[sym] = filtered
                    if filtered.count > 1 { hasData = true }
                }

                if !hasData && chartRange == .all {
                    if let fallbackCutoff = Calendar.current.date(byAdding: .year, value: -5, to: Date()) {
                        source = originalSource
                        for (sym, points) in source {
                            var filtered = points.filter { $0.date >= fallbackCutoff }
                            if let before = points.last(where: { $0.date < fallbackCutoff }) {
                                filtered.insert(before, at: 0)
                            }
                            source[sym] = filtered
                        }
                    }
                }
            }
            computed = valueSeries(from: source)
        }

        displaySeriesCache[chartRange] = computed
        return computed
    }
}