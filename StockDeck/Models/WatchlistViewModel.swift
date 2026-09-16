import SwiftUI
import Combine

@MainActor
@Observable
final class WatchlistViewModel {
    private var stockService: StockService?
    private var storageService: StorageService?
    
    private(set) var rows: [WatchlistWideView.WatchRow] = []
    private(set) var visibleRows: [WatchlistWideView.WatchRow] = []
    private(set) var displaySymbols: [String] = [] // For WatchlistView (compact)
    
    private var refreshTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    
    init() {}
    
    func setup(stockService: StockService, storageService: StorageService) {
        guard self.stockService == nil else { return } // setup only once
        self.stockService = stockService
        self.storageService = storageService
        
        // Debounce updates from stockService
        stockService.objectWillChange
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.invalidate()
            }
            .store(in: &cancellables)
            
        // Also listen to storageService for watchlist changes (add/remove symbol, sorting)
        storageService.objectWillChange
            .debounce(for: .milliseconds(200), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.invalidate()
            }
            .store(in: &cancellables)
            
        recomputeAll()
    }
    
    private func invalidate() {
        refreshTask?.cancel()
        refreshTask = Task {
            recomputeAll()
        }
    }
    
    private func recomputeAll() {
        guard let stockService = stockService, let storageService = storageService else { return }
        let currentWatchlist = storageService.watchlist
        
        // 1. Build WatchlistWideView.WatchRow
        var newRows: [WatchlistWideView.WatchRow] = []
        
        // Re-use current time boundaries to avoid recalculating per symbol
        let calendar = Calendar.current
        let now = Date()
        let monthStart = calendar.date(byAdding: .month, value: -1, to: now) ?? now
        let threeMonthStart = calendar.date(byAdding: .month, value: -3, to: now) ?? now
        let sixMonthStart = calendar.date(byAdding: .month, value: -6, to: now) ?? now
        let yearStart = calendar.date(from: calendar.dateComponents([.year], from: now)) ?? now
        let oneYearStart = calendar.date(byAdding: .year, value: -1, to: now) ?? now
        let twoYearStart = calendar.date(byAdding: .year, value: -2, to: now) ?? now
        let threeYearStart = calendar.date(byAdding: .year, value: -3, to: now) ?? now
        let fiveYearStart = calendar.date(byAdding: .year, value: -5, to: now) ?? now
        let tenYearStart = calendar.date(byAdding: .year, value: -10, to: now) ?? now
        
        for (index, symbol) in currentWatchlist.enumerated() {
            let q = stockService.quotes[symbol]
            let rate = q.map { stockService.priceRate(from: $0.currency) } ?? 1
            let ext: Double? = q.flatMap { $0.isExtendedHours ? $0.effectivePrice * rate : nil }
            let history = stockService.watchlistHistory[symbol] ?? []
            let allTimeHistory = stockService.priceHistoryMax[symbol] ?? []
            let histForPeriods = allTimeHistory.isEmpty ? history : allTimeHistory
            
            let regularPrice = q?.price ?? 0
            let convPrice = regularPrice * rate
            let indexFlag = q.map { StorageService.isIndex(symbol: $0.symbol, type: storageService.type(for: $0.symbol)) } ?? StorageService.isIndex(symbol: symbol, type: storageService.type(for: symbol))
            
            // Single-pass ATH & ATL calculation (zero array allocations)
            var histHigh: Double? = nil
            var histLow: Double? = nil
            for pt in allTimeHistory {
                let h = pt.effectiveHigh
                let l = pt.effectiveLow
                if histHigh == nil || h > histHigh! { histHigh = h }
                if histLow == nil || l < histLow! { histLow = l }
            }
            
            let quoteHigh = max(q?.fiftyTwoWeekHigh ?? 0, regularPrice)
            let athVal: Double?
            if let h = histHigh {
                athVal = max(h, quoteHigh) * rate
            } else if quoteHigh > 0 {
                athVal = quoteHigh * rate
            } else {
                athVal = nil
            }
            
            let qLow = q?.fiftyTwoWeekLow != nil ? min(q!.fiftyTwoWeekLow!, regularPrice > 0 ? regularPrice : Double.greatestFiniteMagnitude) : regularPrice
            let atlVal: Double?
            if let l = histLow, qLow > 0 {
                atlVal = min(l, qLow) * rate
            } else if let l = histLow {
                atlVal = l * rate
            } else if qLow > 0 {
                atlVal = qLow * rate
            } else {
                atlVal = nil
            }
            
            let fromAth: Double?
            if let ath = athVal, ath > 0, convPrice > 0 {
                fromAth = convPrice >= ath ? 0.0 : min(0.0, (convPrice - ath) / ath * 100)
            } else {
                fromAth = nil
            }
            
            let fromAtl: Double?
            if let atl = atlVal, atl > 0, convPrice > 0 {
                fromAtl = convPrice <= atl ? 0.0 : max(0.0, (convPrice - atl) / atl * 100)
            } else {
                fromAtl = nil
            }
            
            newRows.append(WatchlistWideView.WatchRow(
                id: symbol, order: index, symbol: symbol,
                name: q?.name ?? "",
                currency: indexFlag ? "" : ((storageService.stockPriceCurrency.isEmpty ? q?.currency : storageService.stockPriceCurrency) ?? ""),
                isIndex: indexFlag,
                rate: rate,
                price: convPrice,
                extPrice: ext,
                extChangePercent: ext != nil ? q?.extendedChangePercent : nil,
                extLabel: q?.marketStateLabel ?? "",
                change: (q?.change ?? 0) * rate,
                changePercent: q?.changePercent ?? 0,
                oneMonthChangePercent: PriceHistory.percentChange(points: history, currentPrice: regularPrice, since: monthStart),
                threeMonthChangePercent: PriceHistory.percentChange(points: history, currentPrice: regularPrice, since: threeMonthStart),
                sixMonthChangePercent: PriceHistory.percentChange(points: histForPeriods, currentPrice: regularPrice, since: sixMonthStart),
                ytdChangePercent: PriceHistory.percentChange(points: history, currentPrice: regularPrice, since: yearStart),
                oneYearChangePercent: PriceHistory.percentChange(points: histForPeriods, currentPrice: regularPrice, since: oneYearStart),
                twoYearChangePercent: PriceHistory.percentChange(points: histForPeriods, currentPrice: regularPrice, since: twoYearStart),
                threeYearChangePercent: PriceHistory.percentChange(points: histForPeriods, currentPrice: regularPrice, since: threeYearStart),
                fiveYearChangePercent: PriceHistory.percentChange(points: histForPeriods, currentPrice: regularPrice, since: fiveYearStart),
                tenYearChangePercent: PriceHistory.percentChange(points: histForPeriods, currentPrice: regularPrice, since: tenYearStart),
                allTimeHigh: athVal,
                allTimeLow: atlVal,
                fromAthPercent: fromAth,
                fromAtlPercent: fromAtl,
                history: history,
                allTimeHistory: allTimeHistory,
                loaded: q != nil, quote: q,
                marketCap: q?.marketCap.map { $0 * (q.map { stockService.rate(from: $0.currency) } ?? 1) }
            ))
        }
        
        self.rows = newRows
        
        // 2. Sort rows
        let sortKey = WatchlistSortKey.from(rawString: storageService.currentWatchlist.sortKey)
        let sortAsc = storageService.currentWatchlist.sortAsc ?? true
        
        let sortedSymbols = StorageService.sortWatchlistSymbols(
            currentWatchlist,
            key: sortKey,
            ascending: sortAsc,
            quotes: stockService.quotes,
            history: stockService.watchlistHistory,
            priceHistoryMax: stockService.priceHistoryMax,
            priceRate: { stockService.priceRate(from: $0) },
            rate: { stockService.rate(from: $0) },
            showExtendedHours: storageService.showExtendedHours
        )
        
        let rowsBySymbol = Dictionary(uniqueKeysWithValues: newRows.map { ($0.symbol, $0) })
        self.visibleRows = sortedSymbols.compactMap { rowsBySymbol[$0] }
        
        // 3. For WatchlistView (compact)
        self.displaySymbols = sortedSymbols
    }
}
