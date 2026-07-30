import Foundation

@MainActor
enum InvestmentEffectiveness {
    struct Result {
        let portfolioXIRR: Double?   // Annualized %, e.g. 14.2
        let benchmarkXIRR: Double?   // SPX-equivalent annualized %
        let excludedHoldingsCount: Int
        let isYoungerThan30Days: Bool
    }

    static func evaluate(holdings: [Holding],
                         stockService: StockService,
                         storageService: StorageService,
                         today: Date = Date()) -> Result {
        let validHoldings = holdings.filter { $0.purchaseDate != nil }
        let excludedHoldingsCount = holdings.count - validHoldings.count
        
        guard !validHoldings.isEmpty else {
            return Result(portfolioXIRR: nil, benchmarkXIRR: nil, excludedHoldingsCount: excludedHoldingsCount, isYoungerThan30Days: false)
        }
        
        let earliestDate = validHoldings.compactMap(\.purchaseDate).min() ?? today
        let daysSinceEarliest = today.timeIntervalSince(earliestDate) / 86400.0
        
        if daysSinceEarliest < 30.0 {
            return Result(portfolioXIRR: nil, benchmarkXIRR: nil, excludedHoldingsCount: excludedHoldingsCount, isYoungerThan30Days: true)
        }
        
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
        
        let spxTodayPrice = spxPoints.last?.close
        
        var portfolioFlows: [CashFlow] = []
        var spxFlows: [CashFlow] = []
        var portfolioTerminalValue: Double = 0.0
        var totalSPXUnits: Double = 0.0
        
        for h in validHoldings {
            guard let pDate = h.purchaseDate else { continue }
            let symbolCurrency = stockService.detectedCurrency(for: h.symbol)
            let costRate = stockService.rate(from: symbolCurrency, for: pDate)
            
            // Outflow on purchase date in preferred currency:
            // costBasisLocal is signed (positive for long, negative for short).
            // CashFlow outflow = -costBasisLocal * costRate
            let outflowPreferred = -h.costBasisLocal * costRate
            portfolioFlows.append(CashFlow(date: pDate, amount: outflowPreferred))
            
            // Terminal value for this lot (signed):
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
            let lotTerminalValue = (liveQuote.price / scale) * h.quantity * h.effectiveLeverage * currRate
            portfolioTerminalValue += lotTerminalValue
            
            // SPX-equivalent flows:
            let usdCostRate = stockService.rate(from: "USD", for: pDate)
            if usdCostRate > 1e-9, let spxPriceOnDate = spxPrice(on: pDate), spxPriceOnDate > 1e-9 {
                // Outflow in USD = (-outflowPreferred) / usdCostRate
                let outflowUSD = (-outflowPreferred) / usdCostRate
                let spxUnits = outflowUSD / spxPriceOnDate
                totalSPXUnits += spxUnits
                spxFlows.append(CashFlow(date: pDate, amount: outflowPreferred))
            }
        }
        
        portfolioFlows.append(CashFlow(date: today, amount: portfolioTerminalValue))
        
        if let spxToday = spxTodayPrice, abs(spxToday) > 1e-9 {
            let usdCurrRate = stockService.rate(from: "USD")
            let spxTerminalValue = totalSPXUnits * spxToday * usdCurrRate
            spxFlows.append(CashFlow(date: today, amount: spxTerminalValue))
        }
        
        let pRate = XIRR.rate(portfolioFlows).map { $0 * 100.0 }
        let sRate = (spxFlows.count >= 2) ? XIRR.rate(spxFlows).map { $0 * 100.0 } : nil
        
        return Result(
            portfolioXIRR: pRate,
            benchmarkXIRR: sRate,
            excludedHoldingsCount: excludedHoldingsCount,
            isYoungerThan30Days: false
        )
    }
}
