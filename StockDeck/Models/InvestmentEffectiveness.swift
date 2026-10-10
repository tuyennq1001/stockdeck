import Foundation

enum InvestmentEffectiveness {
    struct Result: Sendable {
        let portfolioXIRR: Double?   // Annualized %, e.g. 14.2
        let benchmarkXIRR: Double?   // SPX-equivalent annualized %
        let excludedHoldingsCount: Int
        let isYoungerThan30Days: Bool
    }

    struct PositionInput: Sendable {
        let purchaseDate: Date
        let costBasisLocal: Double
        let costRate: Double
        let currentPrice: Double
        let scale: Double
        let quantity: Double
        let leverage: Double
        let currentRate: Double
        let usdCostRate: Double
        let spxPriceOnPurchase: Double?
    }

    struct Inputs: @unchecked Sendable {
        let positions: [PositionInput]
        let excludedHoldingsCount: Int
        let spxPoints: [PricePoint]
        let spxCurrentPrice: Double?
        let usdCurrentRate: Double
        let today: Date
    }

    @MainActor
    static func evaluate(holdings: [Holding],
                         stockService: StockService,
                         storageService: StorageService,
                         today: Date = Date()) -> Result {
        evaluate(inputs(holdings: holdings, stockService: stockService, today: today))
    }

    @MainActor
    static func inputs(holdings: [Holding], stockService: StockService,
                       today: Date = Date()) -> Inputs {
        let validHoldings = holdings.filter { $0.purchaseDate != nil }
        let excludedHoldingsCount = holdings.count - validHoldings.count
        let spxPoints = stockService.priceHistoryMax["^GSPC"] ?? stockService.priceHistory["^GSPC"] ?? []
        func spxPrice(on date: Date) -> Double? {
            guard !spxPoints.isEmpty else { return nil }
            let graceCutoff = date.addingTimeInterval(7 * 86400)
            if let point = spxPoints.last(where: { $0.date <= date }) ?? spxPoints.first(where: { $0.date <= graceCutoff }),
               abs(point.close) > 1e-9 {
                return point.close
            }
            return nil
        }
        let positions = validHoldings.compactMap { h -> PositionInput? in
            guard let pDate = h.purchaseDate else { return nil }
            let symbolCurrency = stockService.detectedCurrency(for: h.symbol)
            let costRate = stockService.rate(from: symbolCurrency, for: pDate)
            let liveQuote = stockService.quotes[h.symbol] ?? stockService.quotes[h.symbol.uppercased()] ?? StockQuote(
                symbol: h.symbol,
                name: h.symbol,
                price: h.avgPrice,
                change: 0,
                changePercent: 0,
                currency: symbolCurrency
            )
            let currRate = stockService.rate(from: symbolCurrency)
            let isJpFund = liveQuote.isJapaneseFund || stockService.isJapaneseMutualFund(h.symbol) || h.isJapaneseFund
            let scale = isJpFund ? 10000.0 : 1.0
            return PositionInput(purchaseDate: pDate, costBasisLocal: h.costBasisLocal,
                                 costRate: costRate, currentPrice: liveQuote.price, scale: scale,
                                 quantity: h.quantity, leverage: h.effectiveLeverage,
                                 currentRate: currRate, usdCostRate: stockService.rate(from: "USD", for: pDate),
                                 spxPriceOnPurchase: spxPrice(on: pDate))
        }
        return Inputs(positions: positions, excludedHoldingsCount: excludedHoldingsCount,
                      spxPoints: spxPoints, spxCurrentPrice: spxPoints.last?.close,
                      usdCurrentRate: stockService.rate(from: "USD"), today: today)
    }

    nonisolated static func evaluate(_ inputs: Inputs) -> Result {
        let positions = inputs.positions
        guard !positions.isEmpty else {
            return Result(portfolioXIRR: nil, benchmarkXIRR: nil,
                          excludedHoldingsCount: inputs.excludedHoldingsCount, isYoungerThan30Days: false)
        }
        let earliestDate = positions.map(\.purchaseDate).min() ?? inputs.today
        if inputs.today.timeIntervalSince(earliestDate) / 86400.0 < 30 {
            return Result(portfolioXIRR: nil, benchmarkXIRR: nil,
                          excludedHoldingsCount: inputs.excludedHoldingsCount, isYoungerThan30Days: true)
        }
        var portfolioFlows: [CashFlow] = []
        var spxFlows: [CashFlow] = []
        var portfolioTerminalValue = 0.0
        var totalSPXUnits = 0.0
        for position in positions {
            let outflowPreferred = -position.costBasisLocal * position.costRate
            portfolioFlows.append(CashFlow(date: position.purchaseDate, amount: outflowPreferred))
            portfolioTerminalValue += (position.currentPrice / position.scale)
                * position.quantity * position.leverage * position.currentRate
            if position.usdCostRate > 1e-9,
               let spxPrice = position.spxPriceOnPurchase, spxPrice > 1e-9 {
                let outflowUSD = (-outflowPreferred) / position.usdCostRate
                totalSPXUnits += outflowUSD / spxPrice
                spxFlows.append(CashFlow(date: position.purchaseDate, amount: outflowPreferred))
            }
        }
        portfolioFlows.append(CashFlow(date: inputs.today, amount: portfolioTerminalValue))
        if let spxToday = inputs.spxCurrentPrice, abs(spxToday) > 1e-9 {
            spxFlows.append(CashFlow(date: inputs.today,
                                     amount: totalSPXUnits * spxToday * inputs.usdCurrentRate))
        }
        let pRate = XIRR.rate(portfolioFlows).map { $0 * 100.0 }
        let sRate = (spxFlows.count >= 2) ? XIRR.rate(spxFlows).map { $0 * 100.0 } : nil
        return Result(
            portfolioXIRR: pRate,
            benchmarkXIRR: sRate,
            excludedHoldingsCount: inputs.excludedHoldingsCount,
            isYoungerThan30Days: false
        )
    }
}
