import SwiftUI
import Combine

/// Hero chart range — a pure UI filter over the value series.
enum ChartRange: String, CaseIterable {
    case month = "1M", threeMonths = "3M", sixMonths = "6M", ytd = "YTD", year = "1Y", threeYears = "3Y", fiveYears = "5Y", sevenYears = "7Y", tenYears = "10Y", all = "All"
    var days: Int? {
        switch self {
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
        case .sevenYears: return 365 * 7
        case .tenYears: return 365 * 10
        case .all: return nil
        }
    }

    /// Calendar-accurate period start date matching PerformancePeriod.cutoffDate().
    func startDate(from now: Date = Date(), calendar: Calendar = .current) -> Date? {
        switch self {
        case .month:
            return calendar.date(byAdding: .month, value: -1, to: now)
        case .threeMonths:
            return calendar.date(byAdding: .month, value: -3, to: now)
        case .sixMonths:
            return calendar.date(byAdding: .month, value: -6, to: now)
        case .ytd:
            return calendar.date(from: calendar.dateComponents([.year], from: now))
        case .year:
            return calendar.date(byAdding: .year, value: -1, to: now)
        case .threeYears:
            return calendar.date(byAdding: .year, value: -3, to: now)
        case .fiveYears:
            return calendar.date(byAdding: .year, value: -5, to: now)
        case .sevenYears:
            return calendar.date(byAdding: .year, value: -7, to: now)
        case .tenYears:
            return calendar.date(byAdding: .year, value: -10, to: now)
        case .all:
            return nil
        }
    }
    /// Suffix for the hero pill, describing the span it measures.
    var changeLabel: String {
        switch self {
        case .month: return "past 1M"
        case .threeMonths: return "past 3M"
        case .sixMonths: return "past 6M"
        case .ytd: return "YTD"
        case .year: return "past 1Y"
        case .threeYears: return "past 3Y"
        case .fiveYears: return "past 5Y"
        case .sevenYears: return "past 7Y"
        case .tenYears: return "past 10Y"
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
        case .sevenYears: return .y7
        case .tenYears: return .y10
        case .all: return nil
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

    struct AllocationSlice: Identifiable, Sendable, Equatable {
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
    /// Changes when a historical series arrives so SwiftUI invalidates cached charts.
    private(set) var historyRevision = 0
    private(set) var valuationRevision: UInt64 = 0
    private(set) var preparedSeriesRevision: UInt64 = 0
    private(set) var historicalRowsRevision: UInt64 = 0

    /// Performance & benchmark matrix — session-cached.
    private(set) var cachedPerformance: (portfolio: [PortfolioOverview.PerformancePeriod: Double?], spx: [PortfolioOverview.PerformancePeriod: Double?])? = nil

    /// Money-weighted return — session-cached.
    private(set) var moneyWeightedResult: InvestmentEffectiveness.Result? = nil
    
    /// Cached display series per chart range, cleared on valuation update.
    @ObservationIgnored
    private var displaySeriesCache: [ChartRange: [ValuePoint]] = [:]
    @ObservationIgnored private var displaySeriesTasks: [ChartRange: Task<Void, Never>] = [:]
    @ObservationIgnored private var chartGeneration: UInt64 = 0
    
    /// Pre-grouped holdings by canonical symbol, cached on valuation update.
    private(set) var groupedHoldings: [String: [ValuedHolding]] = [:]

    @ObservationIgnored
    private var dailyPnlCache: [DailyPnlRange: [DailyPnlRow]] = [:]
    @ObservationIgnored
    private var monthlyPnlCache: [MonthlyPnlRange: [MonthlyPnlRow]] = [:]
    @ObservationIgnored private var dailyPnlTasks: [DailyPnlRange: Task<Void, Never>] = [:]
    @ObservationIgnored private var monthlyPnlTasks: [MonthlyPnlRange: Task<Void, Never>] = [:]
    @ObservationIgnored private var historicalRowsGeneration: UInt64 = 0
    @ObservationIgnored
    private var sortedSymbolsCache: (key: String, result: [String])? = nil
    
    private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var valuationGeneration: UInt64 = 0
    @ObservationIgnored private var performanceTask: Task<Void, Never>?
    @ObservationIgnored private var performanceGeneration: UInt64 = 0
    @ObservationIgnored private var moneyWeightedTask: Task<Void, Never>?
    @ObservationIgnored private var moneyWeightedGeneration: UInt64 = 0

    /// Observe only the inputs used for valuation; news and history-cache
    /// publications must not trigger a live portfolio recomputation.
    @ObservationIgnored private var cancellables = Set<AnyCancellable>()

    init(scope: PortfolioScope) {
        self.scope = scope
    }

    func setup(stockService: StockService, storageService: StorageService) {
        guard self.stockService == nil else { return } // Setup only once
        self.stockService = stockService
        self.storageService = storageService

        stockService.marketDataChanges
            .filter { [weak self] change in
                guard let self else { return false }
                if change.kind == .fx { return true }
                let relevant = Set(self.portfolios.flatMap { portfolio in
                    portfolio.holdings.map(\.symbol) + portfolio.closedTrades.map(\.symbol)
                }.map(StockService.canonicalSymbol(for:)))
                let needsBenchmark = change.symbols.contains(StockService.canonicalSymbol(for: "^GSPC"))
                let relevantHistory = change.kind == .dailyHistory || change.kind == .maxHistory
                    || change.kind == .intradayHistory
                let relevantQuote = change.kind == .regularQuote || change.kind == .extendedQuote
                return (!change.symbols.isDisjoint(with: relevant))
                    && (relevantQuote || relevantHistory)
                    || (needsBenchmark && relevantHistory)
            }
            .throttle(for: .milliseconds(500), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] change in
                guard let self else { return }
                switch change.kind {
                case .regularQuote:
                    self.invalidateValuation()
                case .extendedQuote:
                    self.updateExtendedQuotes(for: change.symbols)
                case .dailyHistory, .maxHistory, .intradayHistory:
                    self.clearHistoricalCaches()
                    self.historyRevision &+= 1
                    self.recomputePerformance()
                case .fx:
                    self.recomputePortfolioHistoryStats()
                    self.invalidateValuation()
                    self.recomputePerformance()
                    self.recomputeMoneyWeightedReturn()
                case .watchlistHistory, .metadata:
                    break
                }
            }
            .store(in: &cancellables)

        let portfolioChanges = storageService.$portfolios.map { _ in () }.eraseToAnyPublisher()
        let currencyChanges = storageService.$preferredCurrency.map { _ in () }.eraseToAnyPublisher()
        let secondaryCurrencyChanges = storageService.$secondaryCurrency.map { _ in () }.eraseToAnyPublisher()
        let typeChanges = storageService.$symbolType.map { _ in () }.eraseToAnyPublisher()
        Publishers.MergeMany([portfolioChanges, currencyChanges, secondaryCurrencyChanges, typeChanges])
            .debounce(for: .milliseconds(150), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.recomputeAll() }
            .store(in: &cancellables)

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

    var secondaryCurrency: String { storageService?.secondaryCurrency ?? "" }
    var secondaryCurrencySymbol: String? { valuationCache.secondaryCurrencySymbol }
    var secondaryTotalValue: Double? { valuationCache.secondaryTotalValue }
    var secondaryTotalPnl: Double? { valuationCache.secondaryTotalPnl }
    var secondaryDayChangeValue: Double? { valuationCache.secondaryDayChangeValue }
    var secondaryDecimals: Int {
        let sec = secondaryCurrency
        guard !sec.isEmpty else { return 2 }
        return StorageService.defaultDecimals(for: sec)
    }

    var symbols: [String] { Array(Set(portfolios.flatMap { $0.holdings.map(\.symbol) })).sorted() }

    var earliestPurchaseDate: Date? {
        let dates = portfolios.flatMap { $0.holdings }.compactMap(\.purchaseDate)
        return dates.min()
    }

    /// Returns true if the portfolio has enough historical depth for the specified chart range.
    /// Dimmed and disabled when the portfolio's earliest purchase date is more recent than
    /// the range's start date (with a 7-day grace window for weekend/holiday offsets).
    func isRangeAvailable(_ range: ChartRange, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        if range == .all { return true }
        guard let cutoff = range.startDate(from: now, calendar: calendar) else { return true }
        guard let inception = earliestPurchaseDate else { return true }
        let graceCutoff = cutoff.addingTimeInterval(7 * 86400)
        return inception <= graceCutoff
    }

    // MARK: - Invalidation & recomputation

    /// Called when scope changes (e.g. user switches portfolios).
    func scopeChanged() {
        clearHistoricalCaches()
        recomputeAll()
    }

    func clearHistoricalCaches() {
        chartGeneration &+= 1
        historicalRowsGeneration &+= 1
        displaySeriesTasks.values.forEach { $0.cancel() }
        displaySeriesTasks.removeAll()
        dailyPnlTasks.values.forEach { $0.cancel() }
        dailyPnlTasks.removeAll()
        monthlyPnlTasks.values.forEach { $0.cancel() }
        monthlyPnlTasks.removeAll()
        displaySeriesCache.removeAll(keepingCapacity: true)
        dailyPnlCache.removeAll(keepingCapacity: true)
        monthlyPnlCache.removeAll(keepingCapacity: true)
        sortedSymbolsCache = nil
    }

    private func invalidateValuation() {
        recomputeValuation()
    }

    /// Update only extended-session cells. Their values are display metadata and
    /// never participate in the regular-session valuation or P&L calculation.
    private func updateExtendedQuotes(for symbols: Set<String>) {
        guard let stockService else { return }
        var updated = symbolAggregates
        var changed = false
        for symbol in symbols {
            let quote = stockService.quotes[symbol]
                ?? stockService.quotes.first(where: { StockService.canonicalSymbol(for: $0.key) == symbol })?.value
            guard let quote, var aggregate = updated[symbol] else { continue }
            aggregate = SymbolAggregate(
                id: aggregate.id, value: aggregate.value, cost: aggregate.cost, pnl: aggregate.pnl,
                pnlPercent: aggregate.pnlPercent, nativeCost: aggregate.nativeCost,
                nativeValue: aggregate.nativeValue, nativePnl: aggregate.nativePnl,
                nativePnlPercent: aggregate.nativePnlPercent, avgPrice: aggregate.avgPrice,
                totalQuantity: aggregate.totalQuantity, todayPnl: aggregate.todayPnl,
                changePercent: aggregate.changePercent, extendedChangePercent: quote.extendedChangePercent,
                nativeCurrencySymbol: aggregate.nativeCurrencySymbol, lotsCount: aggregate.lotsCount,
                hasCostBasis: aggregate.hasCostBasis, isMarketActive: aggregate.isMarketActive, quote: quote
            )
            updated[symbol] = aggregate
            changed = true
        }
        if changed {
            symbolAggregates = updated
            sortedSymbolsCache = nil
        }
    }

    func recomputeAll() {
        refreshTask?.cancel()
        clearHistoricalCaches()
        recomputeValuation()
        recomputePortfolioHistoryStats()
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
        /// Weighted-average buy price in the asset's native currency (per-share for
        /// stocks, per-10,000 口 for Japanese mutual funds to match quoted NAV / 基準価額).
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

    struct ValuationBundle: Sendable {
        let totalValue: Double
        let totalCost: Double
        let totalPnl: Double
        let totalPnlPercent: Double
        let dayChangeValue: Double
        let dayChangePercent: Double
        let secondaryTotalValue: Double?
        let secondaryTotalPnl: Double?
        let secondaryDayChangeValue: Double?
        let secondaryCurrencySymbol: String?

        static let empty = ValuationBundle(
            totalValue: 0, totalCost: 0, totalPnl: 0,
            totalPnlPercent: 0, dayChangeValue: 0, dayChangePercent: 0,
            secondaryTotalValue: nil, secondaryTotalPnl: nil,
            secondaryDayChangeValue: nil, secondaryCurrencySymbol: nil
        )
    }

    struct ValuationPosition: @unchecked Sendable {
        let holding: Holding
        let portfolioId: UUID
        let quote: StockQuote
        let currency: String
        let rate: Double
        let costRate: Double
        let isJapaneseFund: Bool
        let isMarketActive: Bool
        let type: String
        let hasLiveQuote: Bool
    }

    struct ValuationSnapshot: @unchecked Sendable {
        let positions: [ValuationPosition]
        let secondaryCurrency: String
        let secondaryRate: Double?
    }

    struct ValuationResult: @unchecked Sendable {
        let totals: ValuationBundle
        let sortedHoldings: [ValuedHolding]
        let groupedHoldings: [String: [ValuedHolding]]
        let aggregates: [String: SymbolAggregate]
        let allocation: [AllocationSlice]
        let gainers: [ValuedHolding]
        let losers: [ValuedHolding]
        let typeBreakdown: [(label: String, fraction: Double)]
    }

    private func recomputeValuation() {
        guard let stockService, let storageService else { return }
        let scopedPortfolios = portfolios
        let allHoldings = scopedPortfolios.flatMap { portfolio in
            portfolio.holdings.map { (portfolio: portfolio, holding: $0) }
        }
        var positions: [ValuationPosition] = []
        positions.reserveCapacity(allHoldings.count)
        for item in allHoldings {
            let holding = item.holding
            let quote = stockService.quotes[holding.symbol] ?? stockService.quotes[holding.symbol.uppercased()]
            let resolvedQuote = quote ?? StockQuote(
                symbol: holding.symbol, name: holding.symbol, price: .nan, change: 0,
                changePercent: 0, currency: stockService.detectedCurrency(for: holding.symbol)
            )
            let currency = stockService.detectedCurrency(for: holding.symbol)
            let isCrypto = storageService.type(for: holding.symbol) == "CRYPTOCURRENCY"
                || HomeAIInsightService.cryptoBaseAsset(for: holding.symbol) != nil
            positions.append(ValuationPosition(
                holding: holding,
                portfolioId: item.portfolio.id,
                quote: resolvedQuote,
                currency: currency,
                rate: stockService.rate(from: currency, to: storageService.preferredCurrency),
                costRate: stockService.rate(from: currency, to: storageService.preferredCurrency,
                                            for: holding.purchaseDate),
                isJapaneseFund: resolvedQuote.isJapaneseFund
                    || stockService.isJapaneseMutualFund(holding.symbol) || holding.isJapaneseFund,
                isMarketActive: MarketCategory.isTradingDay(symbol: holding.symbol, quote: resolvedQuote,
                                                            isCrypto: isCrypto),
                type: storageService.type(for: holding.symbol),
                hasLiveQuote: quote != nil
            ))
        }
        let secondary = storageService.secondaryCurrency.trimmingCharacters(in: .whitespacesAndNewlines)
        let secondaryRate: Double? = !secondary.isEmpty && secondary != storageService.preferredCurrency
            ? stockService.rate(from: storageService.preferredCurrency, to: secondary)
            : nil
        let snapshot = ValuationSnapshot(positions: positions, secondaryCurrency: secondary,
                                         secondaryRate: secondaryRate)
        valuationGeneration &+= 1
        let generation = valuationGeneration
        refreshTask?.cancel()
        let signpostID = PerformanceSignposts.begin("Portfolio valuation", itemCount: positions.count)
        refreshTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Self.computeValuation(snapshot)
            }.value
            PerformanceSignposts.end("Portfolio valuation", id: signpostID)
            guard let self, !Task.isCancelled, self.valuationGeneration == generation else { return }
            self.valuationCache = result.totals
            self.sortedValuedHoldings = result.sortedHoldings
            self.groupedHoldings = result.groupedHoldings
            self.symbolAggregates = result.aggregates
            self.allocation = result.allocation
            self.topGainers = result.gainers
            self.topLosers = result.losers
            self.typeBreakdown = result.typeBreakdown
            self.activeSymbolsCount = result.aggregates.count
            self.valuationRevision &+= 1
        }
    }

    nonisolated static func computeValuation(_ snapshot: ValuationSnapshot) -> ValuationResult {
        typealias Aggregate = (value: Double, cost: Double, pnl: Double, nativeCost: Double,
                               nativeValue: Double, nativePnl: Double,
                               weightedCostSum: Double, costShares: Double,
                               totalQty: Double, todayPnl: Double, changePercent: Double,
                               extendedChangePercent: Double?, lotsCount: Int,
                               isMarketActive: Bool, quote: StockQuote?, currency: String)
        var valued: [ValuedHolding] = []
        var todayInputs: [TodayPerformance.Input] = []
        var bySymbol: [String: Aggregate] = [:]
        var missingCostSymbols = Set<String>()
        var totalValue = 0.0

        for position in snapshot.positions {
            let holding = position.holding
            let quote = position.quote
            let price = quote.price
            let scale = position.isJapaneseFund ? 10000.0 : 1.0
            let leverage = holding.effectiveLeverage
            let quantity = holding.quantity
            let hasCost = holding.hasKnownCostBasis
            let value = price.isFinite ? (price / scale) * quantity * leverage * position.rate : 0
            let cost = hasCost ? (holding.avgPrice / scale) * quantity * leverage * position.costRate : 0
            totalValue += value

            let nativeValue = price.isFinite ? (price / scale) * quantity * leverage : 0
            let nativeCost = holding.avgPrice.isFinite ? (holding.avgPrice / scale) * quantity * leverage : 0
            let nativePnl = hasCost && price.isFinite
                ? ((price - holding.avgPrice) / scale) * quantity * leverage
                : 0
            let symbol = StockService.canonicalSymbol(for: holding.symbol)
            if !hasCost { missingCostSymbols.insert(symbol) }

            var aggregate = bySymbol[symbol] ?? Aggregate(
                value: 0, cost: 0, pnl: 0, nativeCost: 0, nativeValue: 0, nativePnl: 0,
                weightedCostSum: 0, costShares: 0, totalQty: 0, todayPnl: 0,
                changePercent: position.isMarketActive ? quote.changePercent : 0,
                extendedChangePercent: position.isMarketActive ? quote.extendedChangePercent : nil,
                lotsCount: 0, isMarketActive: position.isMarketActive, quote: quote,
                currency: position.currency
            )
            aggregate.value += value
            aggregate.cost += cost
            aggregate.pnl += hasCost && price.isFinite ? value - cost : 0
            aggregate.nativeCost += nativeCost
            aggregate.nativeValue += nativeValue
            aggregate.nativePnl += nativePnl
            if hasCost {
                aggregate.weightedCostSum += holding.avgPrice * abs(quantity)
                aggregate.costShares += abs(quantity)
            }
            aggregate.totalQty += quantity
            aggregate.todayPnl += position.isMarketActive ? (quote.change / scale) * quantity * leverage : 0
            aggregate.lotsCount += 1
            bySymbol[symbol] = aggregate

            valued.append(ValuedHolding(
                id: holding.id, portfolioId: position.portfolioId, holding: holding, quote: quote,
                value: value, cost: cost,
                dayChangePercent: position.isMarketActive ? quote.changePercent : 0,
                type: position.type
            ))
            if position.hasLiveQuote {
                todayInputs.append(TodayPerformance.Input(
                    holding: holding, regularPrice: quote.price, previousClose: quote.previousClose,
                    rate: position.rate, isMarketActiveToday: position.isMarketActive
                ))
            }
        }

        for symbol in missingCostSymbols {
            guard var aggregate = bySymbol[symbol] else { continue }
            aggregate.cost = 0
            aggregate.pnl = 0
            aggregate.nativeCost = 0
            aggregate.nativePnl = 0
            aggregate.weightedCostSum = 0
            aggregate.costShares = 0
            bySymbol[symbol] = aggregate
        }
        let totalCost = bySymbol.values.reduce(0) { $0 + $1.cost }
        let totalPnl = bySymbol.values.reduce(0) { $0 + $1.pnl }
        let pnlPercent = abs(totalCost) >= 0.01 ? totalPnl / abs(totalCost) * 100 : 0
        let today = TodayPerformance.totals(todayInputs)
        let secondary = snapshot.secondaryRate.flatMap { $0 > 0 ? $0 : nil }
        let totals = ValuationBundle(
            totalValue: totalValue, totalCost: totalCost, totalPnl: totalPnl,
            totalPnlPercent: pnlPercent, dayChangeValue: today.gain, dayChangePercent: today.percent,
            secondaryTotalValue: secondary.map { totalValue * $0 },
            secondaryTotalPnl: secondary.map { totalPnl * $0 },
            secondaryDayChangeValue: secondary.map { today.gain * $0 },
            secondaryCurrencySymbol: secondary.map { _ in StorageService.currencySymbol(for: snapshot.secondaryCurrency) }
        )

        var aggregates: [String: SymbolAggregate] = [:]
        for (symbol, data) in bySymbol {
            let nativePnlPercent = abs(data.nativeCost) >= 0.01 ? data.nativePnl / abs(data.nativeCost) * 100 : 0
            let average = data.costShares > 0 ? data.weightedCostSum / data.costShares : .nan
            aggregates[symbol] = SymbolAggregate(
                id: symbol, value: data.value, cost: data.cost, pnl: data.pnl,
                pnlPercent: nativePnlPercent, nativeCost: data.nativeCost,
                nativeValue: data.nativeValue, nativePnl: data.nativePnl,
                nativePnlPercent: nativePnlPercent, avgPrice: average,
                totalQuantity: data.totalQty, todayPnl: data.todayPnl,
                changePercent: data.changePercent,
                extendedChangePercent: data.extendedChangePercent,
                nativeCurrencySymbol: StorageService.currencySymbol(for: data.currency),
                lotsCount: data.lotsCount, hasCostBasis: !missingCostSymbols.contains(symbol),
                isMarketActive: data.isMarketActive, quote: data.quote
            )
        }

        valued.sort { abs($0.value) > abs($1.value) }
        let grouped = Dictionary(grouping: valued) { StockService.canonicalSymbol(for: $0.symbol) }
        let allocation: [AllocationSlice] = abs(totalValue) >= 0.01
            ? aggregates.map { AllocationSlice(id: $0.key, symbol: $0.key, value: abs($0.value.value),
                                                fraction: abs($0.value.value) / abs(totalValue)) }
                .sorted { $0.value > $1.value }
            : []
        let sortedByDayChange = valued.sorted { $0.dayChangePercent > $1.dayChangePercent }
        var seen = Set<String>()
        let gainers = Array(sortedByDayChange.filter { $0.dayChangePercent > 0 && seen.insert($0.symbol).inserted }.prefix(5))
        seen.removeAll()
        let losers = Array(sortedByDayChange.reversed().filter { $0.dayChangePercent < 0 && seen.insert($0.symbol).inserted }.prefix(5))
        let typeTotal = valued.reduce(0) { $0 + abs($1.value) }
        var typeValues: [String: Double] = [:]
        if typeTotal >= 0.01 {
            for holding in valued { typeValues[typeLabelForWorker(holding.type), default: 0] += abs(holding.value) }
        }
        let typeBreakdown = typeValues.map { (label: $0.key, fraction: $0.value / typeTotal) }
            .sorted { $0.fraction > $1.fraction }
        return ValuationResult(totals: totals, sortedHoldings: valued, groupedHoldings: grouped,
                               aggregates: aggregates, allocation: allocation, gainers: gainers,
                               losers: losers, typeBreakdown: typeBreakdown)
    }

    private nonisolated static func typeLabelForWorker(_ type: String) -> String {
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

    /// Closed-trade and transaction summaries are independent of live quotes.
    /// Rebuild them only when portfolio contents or FX settings change.
    private func recomputePortfolioHistoryStats() {
        guard let stockService else { return }
        let itemCount = portfolios.reduce(0) { $0 + $1.closedTrades.count + $1.transactions.count }
        let signpostID = PerformanceSignposts.begin("Portfolio history stats", itemCount: itemCount)
        defer { PerformanceSignposts.end("Portfolio history stats", id: signpostID) }

        var rawClosed: [(trade: ClosedTrade, portfolioId: UUID, portfolioName: String)] = []
        var rawTransactions: [(tx: Transaction, portfolioId: UUID, portfolioName: String)] = []
        for portfolio in portfolios {
            rawClosed.append(contentsOf: portfolio.closedTrades.map { ($0, portfolio.id, portfolio.name) })
            rawTransactions.append(contentsOf: portfolio.transactions.map { ($0, portfolio.id, portfolio.name) })
        }

        let closed = ConsolidatedClosedTrade.consolidate(tradesWithPortfolio: rawClosed)
        var realized = 0.0
        var closedCost = 0.0
        var winCount = 0
        for trade in closed {
            let rate = stockService.rate(from: stockService.detectedCurrency(for: trade.symbol))
            realized += trade.realizedPnl * rate
            closedCost += trade.costBasis * rate
            if trade.realizedPnl > 0 { winCount += 1 }
        }
        let count = closed.count
        realizedStats = RealizedStats(
            realizedPnl: realized,
            closedCost: closedCost,
            winRate: count > 0 ? Double(winCount) / Double(count) * 100 : 0,
            totalClosed: count
        )
        transactionsCount = ConsolidatedTransaction.consolidate(transactionsWithPortfolio: rawTransactions).count
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
        let cacheKey = "\(column.rawValue):\(ascending):\(manualOrder.joined(separator: ",")):\(valuationRevision)"
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
            case .marketCap:
                let mc1 = symbolAggregates[sym1]?.quote?.marketCap
                let mc2 = symbolAggregates[sym2]?.quote?.marketCap
                switch (mc1, mc2) {
                case let (l?, r?): return isAsc ? l < r : l > r
                case (_?, nil): return true
                case (nil, _?): return false
                case (nil, nil): return isAsc ? sym1 < sym2 : sym1 > sym2
                }
            case .pe:
                let v1 = symbolAggregates[sym1]?.quote?.trailingPE
                let v2 = symbolAggregates[sym2]?.quote?.trailingPE
                switch (v1, v2) {
                case let (l?, r?): return isAsc ? l < r : l > r
                case (_?, nil): return true
                case (nil, _?): return false
                case (nil, nil): return isAsc ? sym1 < sym2 : sym1 > sym2
                }
            case .forwardPe:
                let v1 = symbolAggregates[sym1]?.quote?.forwardPE
                let v2 = symbolAggregates[sym2]?.quote?.forwardPE
                switch (v1, v2) {
                case let (l?, r?): return isAsc ? l < r : l > r
                case (_?, nil): return true
                case (nil, _?): return false
                case (nil, nil): return isAsc ? sym1 < sym2 : sym1 > sym2
                }
            case .pb:
                let v1 = symbolAggregates[sym1]?.quote?.priceToBook
                let v2 = symbolAggregates[sym2]?.quote?.priceToBook
                switch (v1, v2) {
                case let (l?, r?): return isAsc ? l < r : l > r
                case (_?, nil): return true
                case (nil, _?): return false
                case (nil, nil): return isAsc ? sym1 < sym2 : sym1 > sym2
                }
            case .divYield:
                let v1 = symbolAggregates[sym1]?.quote?.dividendYield
                let v2 = symbolAggregates[sym2]?.quote?.dividendYield
                switch (v1, v2) {
                case let (l?, r?): return isAsc ? l < r : l > r
                case (_?, nil): return true
                case (nil, _?): return false
                case (nil, nil): return isAsc ? sym1 < sym2 : sym1 > sym2
                }
            case .eps:
                let v1 = symbolAggregates[sym1]?.quote?.epsTrailingTwelveMonths
                let v2 = symbolAggregates[sym2]?.quote?.epsTrailingTwelveMonths
                switch (v1, v2) {
                case let (l?, r?): return isAsc ? l < r : l > r
                case (_?, nil): return true
                case (nil, _?): return false
                case (nil, nil): return isAsc ? sym1 < sym2 : sym1 > sym2
                }
            }
        }
        sortedSymbolsCache = (cacheKey, result)
        return result
    }

    // MARK: - Performance & Benchmark

    private func recomputePerformance() {
        guard let stockService, let storageService else { return }
        let hs = portfolios.flatMap(\.holdings)
        let holdingsFingerprint = hs.map {
            "\($0.symbol):\($0.quantity):\($0.avgPrice):\($0.effectiveLeverage):\($0.purchaseDate?.timeIntervalSince1970 ?? 0)"
        }.joined(separator: ";")
        let dayKey = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
        let fxRevision = stockService.fxRevision
        let fullKey = "\(scopeKey):\(holdingsFingerprint):h\(stockService.historyRevision):fx\(fxRevision):d\(dayKey)"
        let now = Date()
        let periods = PortfolioOverview.PerformancePeriod.allCases.map { ($0, $0.cutoffDate(now: now)) }
        let positions = hs.map { holding -> PerformancePosition in
            let symbol = holding.symbol
            let quote = stockService.quotes[symbol] ?? stockService.quotes[symbol.uppercased()]
            let history = stockService.priceHistory[symbol] ?? stockService.priceHistoryMax[symbol] ?? []
            let currency = stockService.detectedCurrency(for: symbol)
            return PerformancePosition(
                holding: holding,
                currentPrice: quote?.price,
                scale: (holding.isJapaneseFund || stockService.isJapaneseMutualFund(symbol)) ? 10000 : 1,
                rate: stockService.rate(from: currency, to: storageService.preferredCurrency),
                history: history
            )
        }
        let spxHistory = stockService.priceHistory["^GSPC"] ?? stockService.priceHistoryMax["^GSPC"] ?? []
        let snapshot = PerformanceSnapshot(
            key: fullKey, positions: positions, spxHistory: spxHistory,
            inception: earliestPurchaseDate,
            hasUndatedHoldings: hs.contains { $0.purchaseDate == nil },
            periods: periods
        )
        performanceTask?.cancel()
        performanceGeneration &+= 1
        let generation = performanceGeneration
        let signpostID = PerformanceSignposts.begin("Portfolio Performance and XIRR inputs", itemCount: hs.count + spxHistory.count)
        performanceTask = Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                Self.computePerformance(snapshot)
            }.value
            PerformanceSignposts.end("Portfolio Performance and XIRR inputs", id: signpostID)
            guard let self, !Task.isCancelled, self.performanceGeneration == generation else { return }
            self.cachedPerformance = result
        }
    }

    private struct PerformancePosition: @unchecked Sendable {
        let holding: Holding
        let currentPrice: Double?
        let scale: Double
        let rate: Double
        let history: [PricePoint]
    }

    private struct PerformanceSnapshot: @unchecked Sendable {
        let key: String
        let positions: [PerformancePosition]
        let spxHistory: [PricePoint]
        let inception: Date?
        let hasUndatedHoldings: Bool
        let periods: [(PortfolioOverview.PerformancePeriod, Date)]
    }

    private nonisolated static func computePerformance(
        _ snapshot: PerformanceSnapshot
    ) -> (portfolio: [PortfolioOverview.PerformancePeriod: Double?], spx: [PortfolioOverview.PerformancePeriod: Double?]) {
        PerformanceBenchmarkCache.performance(for: snapshot.key) {
            let positions = snapshot.positions.map { position in
                (position: position, points: position.history.filter { $0.close.isFinite && $0.close > 0 }
                    .sorted { $0.date < $1.date })
            }
            let spxPoints = snapshot.spxHistory.filter { $0.close.isFinite && $0.close > 0 }
                .sorted { $0.date < $1.date }
            var portfolio: [PortfolioOverview.PerformancePeriod: Double?] = [:]
            var benchmark: [PortfolioOverview.PerformancePeriod: Double?] = [:]
            for (period, cutoff) in snapshot.periods {
                let graceCutoff = cutoff.addingTimeInterval(7 * 86400)
                let inceptionAllowsPeriod: Bool = {
                    guard let inception = snapshot.inception, !snapshot.hasUndatedHoldings else { return true }
                    return inception <= graceCutoff
                }()
                var currentValue = 0.0
                var cutoffValue = 0.0
                var hasValidCutoff = false
                for item in (inceptionAllowsPeriod ? positions : []) {
                    let holding = item.position.holding
                    let rawCurrent = item.position.currentPrice
                        ?? (holding.avgPrice.isFinite && holding.avgPrice > 0 ? holding.avgPrice : nil)
                    let currentPrice: Double
                    if let rawCurrent, rawCurrent.isFinite, rawCurrent > 0 {
                        currentPrice = rawCurrent
                    } else if let last = item.points.last {
                        currentPrice = last.close
                    } else { continue }

                    let quantity = holding.quantity.isFinite ? holding.quantity : 0
                    let leverage = holding.effectiveLeverage.isFinite ? holding.effectiveLeverage : 1
                    currentValue += (currentPrice / item.position.scale) * quantity * leverage * item.position.rate
                    let baseline = item.points.last(where: { $0.date <= cutoff })
                        ?? item.points.first(where: { $0.date <= graceCutoff })
                    let cutoffPrice: Double
                    if let baseline {
                        cutoffPrice = baseline.close
                        hasValidCutoff = true
                    } else if let first = item.points.first {
                        cutoffPrice = first.close
                    } else if holding.avgPrice.isFinite && holding.avgPrice > 0 {
                        cutoffPrice = holding.avgPrice
                    } else {
                        cutoffPrice = currentPrice
                    }
                    cutoffValue += (cutoffPrice / item.position.scale) * quantity * leverage * item.position.rate
                }
                if inceptionAllowsPeriod && !snapshot.positions.isEmpty && hasValidCutoff
                    && cutoffValue > 1e-9 && currentValue > 1e-9 {
                    portfolio[period] = ((currentValue - cutoffValue) / cutoffValue) * 100
                } else {
                    portfolio[period] = nil
                }
                if spxPoints.count >= 2, let last = spxPoints.last, abs(last.close) > 1e-9,
                   let start = spxPoints.last(where: { $0.date <= cutoff })
                    ?? spxPoints.first(where: { $0.date <= graceCutoff }), abs(start.close) > 1e-9 {
                    benchmark[period] = ((last.close - start.close) / abs(start.close)) * 100
                } else {
                    benchmark[period] = nil
                }
            }
            return (portfolio, benchmark)
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
        guard let stockService = stockService else { return }
        let hs = portfolios.flatMap { $0.holdings }
        let holdingsFingerprint = hs.map {
            "\($0.symbol):\($0.quantity):\($0.avgPrice):\($0.effectiveLeverage):\($0.purchaseDate?.timeIntervalSince1970 ?? 0)"
        }.joined(separator: ";")
        let fullKey = "\(scopeKey):\(holdingsFingerprint):h\(stockService.historyRevision):fx\(stockService.fxRevision)"

        let inputs = InvestmentEffectiveness.inputs(holdings: hs, stockService: stockService)
        moneyWeightedTask?.cancel()
        moneyWeightedGeneration &+= 1
        let generation = moneyWeightedGeneration
        moneyWeightedTask = Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                MoneyWeightedReturnCache.result(for: fullKey) {
                    InvestmentEffectiveness.evaluate(inputs)
                }
            }.value
            guard let self, !Task.isCancelled, self.moneyWeightedGeneration == generation else { return }
            self.moneyWeightedResult = result
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
        guard dailyPnlTasks[range] == nil, let stockService else { return [] }
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
        let snapshot = HistoricalRowsSnapshot(
            holdings: hs, closedTrades: closed, historyBySymbol: histBySymbol,
            rateBySymbol: rateBySymbol, dayCount: range.dayCount,
            monthCount: 0, today: Date(), calendar: .current
        )
        let generation = historicalRowsGeneration
        dailyPnlTasks[range] = Task { [weak self] in
            let rows = await Task.detached(priority: .userInitiated) {
                DailyPnl.rows(holdings: snapshot.holdings, closedTrades: snapshot.closedTrades,
                              historyBySymbol: snapshot.historyBySymbol, rateBySymbol: snapshot.rateBySymbol,
                              today: snapshot.today, calendar: snapshot.calendar, dayCount: snapshot.dayCount)
            }.value
            guard let self, !Task.isCancelled, self.historicalRowsGeneration == generation else { return }
            self.dailyPnlTasks.removeValue(forKey: range)
            self.dailyPnlCache[range] = rows
            self.historicalRowsRevision &+= 1
        }
        return []
    }

    func monthlyPnlRows(for range: MonthlyPnlRange) -> [MonthlyPnlRow] {
        if let cached = monthlyPnlCache[range] { return cached }
        guard monthlyPnlTasks[range] == nil, let stockService else { return [] }
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
        let snapshot = HistoricalRowsSnapshot(
            holdings: hs, closedTrades: closed, historyBySymbol: histBySymbol,
            rateBySymbol: rateBySymbol, dayCount: 0,
            monthCount: monthCount, today: Date(), calendar: .current
        )
        let generation = historicalRowsGeneration
        monthlyPnlTasks[range] = Task { [weak self] in
            let rows = await Task.detached(priority: .userInitiated) {
                MonthlyPnl.rows(holdings: snapshot.holdings, closedTrades: snapshot.closedTrades,
                                historyBySymbol: snapshot.historyBySymbol, rateBySymbol: snapshot.rateBySymbol,
                                today: snapshot.today, calendar: snapshot.calendar, monthCount: snapshot.monthCount)
            }.value
            guard let self, !Task.isCancelled, self.historicalRowsGeneration == generation else { return }
            self.monthlyPnlTasks.removeValue(forKey: range)
            self.monthlyPnlCache[range] = rows
            self.historicalRowsRevision &+= 1
        }
        return []
    }

    private struct HistoricalRowsSnapshot: @unchecked Sendable {
        let holdings: [Holding]
        let closedTrades: [ClosedTrade]
        let historyBySymbol: [String: [PricePoint]]
        let rateBySymbol: [String: Double]
        let dayCount: Int
        let monthCount: Int
        let today: Date
        let calendar: Calendar
    }

    func displaySeries(for chartRange: ChartRange) -> [ValuePoint] {
        _ = preparedSeriesRevision
        if let cached = displaySeriesCache[chartRange] {
            return cached
        }
        scheduleDisplaySeriesPreparation(for: chartRange)
        return []
    }

    private struct ChartPreparationSnapshot: @unchecked Sendable {
        let holdings: [Holding]
        let histories: [String: [PricePoint]]
        let rates: [String: Double]
    }

    private func scheduleDisplaySeriesPreparation(for range: ChartRange) {
        guard displaySeriesTasks[range] == nil,
              let stockService,
              !portfolios.flatMap(\.holdings).isEmpty else { return }
        let holdings = portfolios.flatMap(\.holdings)
        let generation = chartGeneration
        let revision = stockService.historyRevision
        let chartNow = Date()
        var chartCutoff: Date?
        if range == .all {
            chartCutoff = earliestPurchaseDate.map(Calendar.current.startOfDay(for:))
                ?? Calendar.current.date(byAdding: .year, value: -5, to: chartNow)
        } else {
            chartCutoff = range.startDate(from: chartNow)
        }
        if let purchaseDate = earliestPurchaseDate {
            let purchaseCutoff = Calendar.current.startOfDay(for: purchaseDate)
            chartCutoff = chartCutoff.map { max($0, purchaseCutoff) } ?? purchaseCutoff
        }
        let signpostID = PerformanceSignposts.begin("Portfolio chart preparation", itemCount: holdings.count)
        var histories: [String: [PricePoint]] = [:]
        var rates: [String: Double] = [:]
        for holding in holdings {
            let symbol = holding.symbol
            rates[symbol] = stockService.rate(from: stockService.detectedCurrency(for: symbol),
                                              to: storageService?.preferredCurrency ?? "USD")
            let daySpan = chartCutoff.map { Calendar.current.dateComponents([.day], from: $0, to: chartNow).day ?? 9999 } ?? 9999
            let source = daySpan > 730 ? stockService.priceHistoryMax : stockService.priceHistory
            histories[symbol] = source[symbol] ?? []
        }
        let snapshot = ChartPreparationSnapshot(holdings: holdings, histories: histories, rates: rates)
        let cutoff = chartCutoff
        let task = Task { [weak self] in
            let computed = await Task.detached(priority: .userInitiated) { () -> [ValuePoint] in
                let workerID = signpostID
                defer { PerformanceSignposts.end("Portfolio chart preparation", id: workerID) }
                let source = Self.clippedHistories(snapshot.histories, cutoff: cutoff)
                var points = PortfolioBackfill.series(holdings: snapshot.holdings,
                                                       historyBySymbol: source,
                                                       rateBySymbol: snapshot.rates)
                if range == .all, points.count < 2,
                   let fallback = Calendar.current.date(byAdding: .year, value: -5, to: Date()) {
                    points = PortfolioBackfill.series(
                        holdings: snapshot.holdings,
                        historyBySymbol: Self.clippedHistories(snapshot.histories, cutoff: fallback),
                        rateBySymbol: snapshot.rates
                    )
                }
                return points
            }.value
            guard let self else { return }
            self.displaySeriesTasks.removeValue(forKey: range)
            guard !Task.isCancelled, self.chartGeneration == generation,
                  self.stockService?.historyRevision == revision else { return }
            self.displaySeriesCache[range] = computed
            self.preparedSeriesRevision &+= 1
        }
        displaySeriesTasks[range] = task
    }

    private nonisolated static func clippedHistories(
        _ histories: [String: [PricePoint]], cutoff: Date?
    ) -> [String: [PricePoint]] {
        guard let cutoff else { return histories }
        return histories.mapValues { points in
            var filtered = points.filter { $0.date >= cutoff }
            if let before = points.last(where: { $0.date < cutoff }) { filtered.insert(before, at: 0) }
            return filtered
        }
    }
}
