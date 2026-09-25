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
    
    private struct ComputationInputs: Sendable {
        let watchlist: [String]
        let quotes: [String: StockQuote]
        let history: [String: [PricePoint]]
        let historyMax: [String: [PricePoint]]
        let targets: [String: StockTarget]
        let priceRates: [String: Double]
        let rates: [String: Double]
        let isCryptoMap: [String: Bool]
        let isIndexMap: [String: Bool]
        let stockPriceCurrency: String
        let sortKey: WatchlistSortKey
        let sortAsc: Bool
    }
    
    private func recomputeAll() {
        guard let stockService = stockService, let storageService = storageService else { return }
        let currentWatchlist = storageService.watchlist
        guard !currentWatchlist.isEmpty else {
            self.rows = []
            self.visibleRows = []
            self.displaySymbols = []
            return
        }
        
        var priceRates: [String: Double] = [:]
        var rates: [String: Double] = [:]
        var isCryptoMap: [String: Bool] = [:]
        var isIndexMap: [String: Bool] = [:]
        
        for symbol in currentWatchlist {
            let q = stockService.quotes[symbol]
            let curr = q?.currency ?? ""
            if !curr.isEmpty {
                priceRates[curr] = stockService.priceRate(from: curr)
                rates[curr] = stockService.rate(from: curr)
            }
            let isCrypto = storageService.type(for: symbol) == "CRYPTOCURRENCY" || HomeAIInsightService.cryptoBaseAsset(for: symbol) != nil
            isCryptoMap[symbol] = isCrypto
            let isIdx = q.map { StorageService.isIndex(symbol: $0.symbol, type: storageService.type(for: $0.symbol)) } ?? StorageService.isIndex(symbol: symbol, type: storageService.type(for: symbol))
            isIndexMap[symbol] = isIdx
        }
        
        let sortKey = WatchlistSortKey.from(rawString: storageService.currentWatchlist.sortKey)
        let sortAsc = storageService.currentWatchlist.sortAsc ?? true
        
        let inputs = ComputationInputs(
            watchlist: currentWatchlist,
            quotes: stockService.quotes,
            history: stockService.watchlistHistory,
            historyMax: stockService.priceHistoryMax,
            targets: storageService.stockTargets,
            priceRates: priceRates,
            rates: rates,
            isCryptoMap: isCryptoMap,
            isIndexMap: isIndexMap,
            stockPriceCurrency: storageService.stockPriceCurrency,
            sortKey: sortKey,
            sortAsc: sortAsc
        )
        
        refreshTask?.cancel()
        refreshTask = Task {
            let result = await Task.detached(priority: .userInitiated) {
                Self.computeRowsAndSort(inputs: inputs)
            }.value
            
            guard !Task.isCancelled else { return }
            self.rows = result.rows
            self.visibleRows = result.visibleRows
            self.displaySymbols = result.displaySymbols
        }
    }
    
    private nonisolated static func computeRowsAndSort(inputs: ComputationInputs) -> (rows: [WatchlistWideView.WatchRow], visibleRows: [WatchlistWideView.WatchRow], displaySymbols: [String]) {
        var newRows: [WatchlistWideView.WatchRow] = []
        newRows.reserveCapacity(inputs.watchlist.count)
        
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
        
        for (index, symbol) in inputs.watchlist.enumerated() {
            let q = inputs.quotes[symbol]
            let rate = q.flatMap { inputs.priceRates[$0.currency] } ?? 1.0
            let ext: Double? = q.flatMap { $0.isExtendedHours ? $0.effectivePrice * rate : nil }
            let history = inputs.history[symbol] ?? []
            let allTimeHistory = inputs.historyMax[symbol] ?? []
            
            func series(covering boundary: Date) -> [PricePoint] {
                if let first = history.first?.date, first <= boundary {
                    return history
                }
                return allTimeHistory.isEmpty ? history : allTimeHistory
            }
            
            let regularPrice = q?.price ?? 0
            let convPrice = regularPrice * rate
            let indexFlag = inputs.isIndexMap[symbol] ?? false
            let isCrypto = inputs.isCryptoMap[symbol] ?? false
            
            // Single-pass ATH & ATL calculation (zero allocations)
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
            
            let target = inputs.targets[symbol]
            let toTargetPct = target?.percentDistance(from: regularPrice)
            let inBuyZone = target?.isInBuyZone(currentPrice: regularPrice) ?? false

            newRows.append(WatchlistWideView.WatchRow(
                id: symbol, order: index, symbol: symbol,
                name: q?.name ?? "",
                currency: indexFlag ? "" : ((inputs.stockPriceCurrency.isEmpty ? q?.currency : inputs.stockPriceCurrency) ?? ""),
                isIndex: indexFlag,
                rate: rate,
                price: convPrice,
                extPrice: ext,
                extChangePercent: ext != nil ? q?.extendedChangePercent : nil,
                extLabel: q?.marketStateLabel ?? "",
                change: (q?.change ?? 0) * rate,
                changePercent: q?.changePercent ?? 0,
                oneMonthChangePercent: PriceHistory.percentChange(points: series(covering: monthStart), currentPrice: regularPrice, since: monthStart),
                threeMonthChangePercent: PriceHistory.percentChange(points: series(covering: threeMonthStart), currentPrice: regularPrice, since: threeMonthStart),
                sixMonthChangePercent: PriceHistory.percentChange(points: series(covering: sixMonthStart), currentPrice: regularPrice, since: sixMonthStart),
                ytdChangePercent: PriceHistory.percentChange(points: series(covering: yearStart), currentPrice: regularPrice, since: yearStart),
                oneYearChangePercent: PriceHistory.percentChange(points: series(covering: oneYearStart), currentPrice: regularPrice, since: oneYearStart),
                twoYearChangePercent: PriceHistory.percentChange(points: series(covering: twoYearStart), currentPrice: regularPrice, since: twoYearStart),
                threeYearChangePercent: PriceHistory.percentChange(points: series(covering: threeYearStart), currentPrice: regularPrice, since: threeYearStart),
                fiveYearChangePercent: PriceHistory.percentChange(points: series(covering: fiveYearStart), currentPrice: regularPrice, since: fiveYearStart),
                tenYearChangePercent: PriceHistory.percentChange(points: series(covering: tenYearStart), currentPrice: regularPrice, since: tenYearStart),
                allTimeHigh: athVal,
                allTimeLow: atlVal,
                fromAthPercent: fromAth,
                fromAtlPercent: fromAtl,
                history: history,
                allTimeHistory: allTimeHistory,
                loaded: q != nil, quote: q,
                marketCap: q?.marketCap.map { $0 * (q.flatMap { inputs.rates[$0.currency] } ?? 1) },
                buyTarget: target,
                toBuyTargetPercent: toTargetPct,
                isInBuyZone: inBuyZone,
                isCrypto: isCrypto
            ))
        }
        
        // Direct in-memory sort using precalculated WatchRow metrics (O(N log N) without history binary search)
        let sortedRows: [WatchlistWideView.WatchRow]
        if inputs.sortKey == .order {
            sortedRows = inputs.sortAsc ? newRows : Array(newRows.reversed())
        } else if inputs.sortKey == .symbol {
            sortedRows = newRows.sorted {
                inputs.sortAsc ? $0.symbol.localizedCompare($1.symbol) == .orderedAscending : $0.symbol.localizedCompare($1.symbol) == .orderedDescending
            }
        } else {
            sortedRows = newRows.sorted { a, b in
                let valA = sortValue(row: a, key: inputs.sortKey)
                let valB = sortValue(row: b, key: inputs.sortKey)
                if let vA = valA, let vB = valB {
                    if vA != vB {
                        return inputs.sortAsc ? vA < vB : vA > vB
                    }
                } else if valA != nil {
                    return true
                } else if valB != nil {
                    return false
                }
                return a.order < b.order
            }
        }
        
        let displaySymbols = sortedRows.map(\.symbol)
        return (rows: newRows, visibleRows: sortedRows, displaySymbols: displaySymbols)
    }
    
    private nonisolated static func sortValue(row: WatchlistWideView.WatchRow, key: WatchlistSortKey) -> Double? {
        switch key {
        case .order, .symbol: return nil
        case .price: return row.price
        case .changePercent: return row.changePercent
        case .extChangePercent: return row.extChangePercent
        case .metric(let m): return row.metricValue(for: m)
        }
    }
}
