import SwiftUI
import Combine

@MainActor
@Observable
final class WatchlistViewModel {
    private var stockService: StockService?
    private var storageService: StorageService?
    
    struct Snapshot {
        var scope: UUID?
        var rows: [WatchlistWideView.WatchRow] = []
        var rowsBySymbol: [String: WatchlistWideView.WatchRow] = [:]
        var visibleRows: [WatchlistWideView.WatchRow] = []
        var displaySymbols: [String] = []
        var isLoading = false
    }

    private(set) var snapshot = Snapshot(scope: nil)
    var rows: [WatchlistWideView.WatchRow] { snapshot.rows }
    var rowsBySymbol: [String: WatchlistWideView.WatchRow] { snapshot.rowsBySymbol }
    var visibleRows: [WatchlistWideView.WatchRow] { snapshot.visibleRows }
    var displaySymbols: [String] { snapshot.displaySymbols }

    private struct CacheKey: Hashable {
        let watchlistID: UUID
        let symbols: [String]
        let sortKey: WatchlistSortKey
        let sortAscending: Bool
        let currency: String
    }
    private struct RowCacheKey: Hashable, Sendable {
        let symbol: String
        let order: Int
        let quote: StockQuote?
        let regularQuoteRevision: UInt64
        let extendedQuoteRevision: UInt64
        let metadataRevision: UInt64
        let dailyHistoryRevision: UInt64
        let maxHistoryRevision: UInt64
        let watchlistHistoryRevision: UInt64
        let fxRevision: UInt64
        let priceRate: Double
        let rate: Double
        let target: StockTarget?
        let isCrypto: Bool
        let isIndex: Bool
        let stockPriceCurrency: String
        let dayBucket: Int64
    }
    private struct CachedRow: Sendable {
        let key: RowCacheKey
        let row: WatchlistWideView.WatchRow
    }
    private var snapshotsByKey: [CacheKey: Snapshot] = [:]
    private var snapshotLRU: [CacheKey] = []
    private var rowCacheBySymbol: [String: CachedRow] = [:]
    private let cachedRowLimit = 600
    private var active = false
    private var generation: UInt64 = 0
    private var workerID: UUID?
    private var worker: Task<( [WatchlistWideView.WatchRow], [WatchlistWideView.WatchRow], [String])?, Never>?
    private var pending: (ComputationInputs, UUID, UInt64)?
    private var cancellables = Set<AnyCancellable>()
    
    init() {}
    
    func setup(stockService: StockService, storageService: StorageService) {
        guard self.stockService == nil else { return } // setup only once
        self.stockService = stockService
        self.storageService = storageService
        
        // Ignore unrelated service publications (news, alerts, loading flags).
        // Market data is already batched upstream; throttle to the newest state
        // so a continuous quote stream cannot postpone row refresh indefinitely.
        stockService.marketDataChanges
            .filter { [weak self] change in
                guard let self, self.active, let symbols = self.storageService?.watchlist
                    .map(StockService.canonicalSymbol(for:)) else { return false }
                if change.kind == .fx { return true }
                return !change.symbols.isDisjoint(with: Set(symbols))
            }
            .throttle(for: .milliseconds(500), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] _ in self?.invalidate() }
            .store(in: &cancellables)

        // Only storage fields used to build rows or choose their order invalidate
        // the snapshot; view-only settings remain local to the view.
        Publishers.MergeMany([
            storageService.$watchlists.map { _ in () }.eraseToAnyPublisher(),
            storageService.$selectedWatchlistId.map { _ in () }.eraseToAnyPublisher(),
            storageService.$stockTargets.map { _ in () }.eraseToAnyPublisher(),
            storageService.$symbolType.map { _ in () }.eraseToAnyPublisher(),
            storageService.$stockPriceCurrency.map { _ in () }.eraseToAnyPublisher()
        ])
            .throttle(for: .milliseconds(200), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] _ in
                self?.invalidate()
            }
            .store(in: &cancellables)

        stockService.$exchangeRates
            .throttle(for: .milliseconds(500), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] _ in self?.invalidate() }
            .store(in: &cancellables)
            
        setActive(true)
    }

    func setActive(_ active: Bool) {
        guard self.active != active else {
            if active { invalidate() }
            return
        }
        self.active = active
        generation &+= 1
        if active {
            invalidate()
        } else {
            pending = nil
            worker?.cancel()
        }
    }

    /// Immediately updates `snapshot.visibleRows` and `snapshot.displaySymbols`
    /// in-memory after a manual drag-drop reorder so the UI reflects the new
    /// order on the exact same frame without waiting for the 200ms throttle.
    func applyManualOrder(_ orderedSymbols: [String]) {
        guard !orderedSymbols.isEmpty,
              orderedSymbols.count == snapshot.displaySymbols.count else { return }
        let reorderedRows = orderedSymbols.compactMap { snapshot.rowsBySymbol[$0] }
        guard reorderedRows.count == orderedSymbols.count else { return }
        var next = snapshot
        next.rows = reorderedRows
        next.visibleRows = reorderedRows
        next.displaySymbols = orderedSymbols
        snapshot = next
    }

    private func invalidate() {
        guard active else { return }
        generation &+= 1
        guard let inputsAndKey = makeInputs() else { return }
        let (inputs, key) = inputsAndKey

        if let cached = snapshotsByKey[key] {
            snapshot = cached
            touch(key)
        } else if snapshot.scope != key.watchlistID {
            // Do not show rows belonging to the previously selected watchlist.
            snapshot = Snapshot(scope: key.watchlistID, isLoading: true)
        } else if snapshot.rows.isEmpty {
            snapshot.isLoading = true
        }
        pending = (inputs, key.watchlistID, generation)
        worker?.cancel()
        if worker == nil { startPending(key: key) }
    }
    
    private struct ComputationInputs: Sendable {
        let watchlist: [String]
        let quotes: [String: StockQuote]
        let history: [String: [PricePoint]]
        let priceHistory: [String: [PricePoint]]
        let historyMax: [String: [PricePoint]]
        let targets: [String: StockTarget]
        let priceRates: [String: Double]
        let rates: [String: Double]
        let isCryptoMap: [String: Bool]
        let isIndexMap: [String: Bool]
        let stockPriceCurrency: String
        let sortKey: WatchlistSortKey
        let sortAsc: Bool
        let rowCacheKeys: [String: RowCacheKey]
        let reusableRows: [String: WatchlistWideView.WatchRow]
    }
    
    private func makeInputs() -> (ComputationInputs, CacheKey)? {
        guard let stockService = stockService, let storageService = storageService else { return nil }
        let selected = storageService.currentWatchlist
        let currentWatchlist = selected.symbols
        guard !currentWatchlist.isEmpty else {
            snapshot = Snapshot(scope: selected.id)
            pending = nil
            worker?.cancel()
            return nil
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
        
        let sortKey = WatchlistSortKey.from(rawString: selected.sortKey)
        let sortAsc = selected.sortAsc ?? true
        var scopedQuotes: [String: StockQuote] = [:]
        var scopedHistory: [String: [PricePoint]] = [:]
        var scopedDaily: [String: [PricePoint]] = [:]
        var scopedMax: [String: [PricePoint]] = [:]
        var scopedTargets: [String: StockTarget] = [:]
        for symbol in currentWatchlist {
            if let value = stockService.quotes[symbol] { scopedQuotes[symbol] = value }
            if let value = stockService.watchlistHistory[symbol] { scopedHistory[symbol] = value }
            if let value = stockService.priceHistory[symbol] { scopedDaily[symbol] = value }
            if let value = stockService.priceHistoryMax[symbol] { scopedMax[symbol] = value }
            if let value = storageService.stockTargets[symbol] { scopedTargets[symbol] = value }
        }

        var rowCacheKeys: [String: RowCacheKey] = [:]
        var reusableRows: [String: WatchlistWideView.WatchRow] = [:]
        for (order, symbol) in currentWatchlist.enumerated() {
            let quote = scopedQuotes[symbol]
            let currency = quote?.currency ?? ""
            let canonical = StockService.canonicalSymbol(for: symbol)
            let key = RowCacheKey(
                symbol: symbol,
                order: order,
                quote: quote,
                regularQuoteRevision: stockService.dataRevision(for: .regularQuote, symbol: canonical),
                extendedQuoteRevision: stockService.dataRevision(for: .extendedQuote, symbol: canonical),
                metadataRevision: stockService.dataRevision(for: .metadata, symbol: canonical),
                dailyHistoryRevision: stockService.dataRevision(for: .dailyHistory, symbol: canonical),
                maxHistoryRevision: stockService.dataRevision(for: .maxHistory, symbol: canonical),
                watchlistHistoryRevision: stockService.dataRevision(for: .watchlistHistory, symbol: canonical),
                fxRevision: stockService.fxRevision,
                priceRate: priceRates[currency] ?? 1,
                rate: rates[currency] ?? 1,
                target: scopedTargets[symbol],
                isCrypto: isCryptoMap[symbol] ?? false,
                isIndex: isIndexMap[symbol] ?? false,
                stockPriceCurrency: storageService.stockPriceCurrency,
                dayBucket: Int64(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970)
            )
            rowCacheKeys[symbol] = key
            if let cached = rowCacheBySymbol[symbol], cached.key == key {
                reusableRows[symbol] = cached.row
            }
        }
        
        let inputs = ComputationInputs(
            watchlist: currentWatchlist,
            quotes: scopedQuotes,
            history: scopedHistory,
            priceHistory: scopedDaily,
            historyMax: scopedMax,
            targets: scopedTargets,
            priceRates: priceRates,
            rates: rates,
            isCryptoMap: isCryptoMap,
            isIndexMap: isIndexMap,
            stockPriceCurrency: storageService.stockPriceCurrency,
            sortKey: sortKey,
            sortAsc: sortAsc,
            rowCacheKeys: rowCacheKeys,
            reusableRows: reusableRows
        )
        return (inputs, CacheKey(watchlistID: selected.id, symbols: currentWatchlist,
                                 sortKey: sortKey, sortAscending: sortAsc,
                                 currency: storageService.stockPriceCurrency))
    }

    private func startPending(key: CacheKey? = nil) {
        guard active, worker == nil, let (inputs, scope, requestedGeneration) = pending else { return }
        pending = nil
        let id = UUID()
        workerID = id
        let task = Task.detached(priority: .userInitiated) {
            Self.computeRowsAndSort(inputs: inputs)
        }
        worker = task
        Task { @MainActor [weak self] in
            let result = await task.value
            self?.finishWorker(id: id, result: result, scope: scope,
                               requestedGeneration: requestedGeneration, cacheKey: key,
                               rowCacheKeys: inputs.rowCacheKeys)
        }
    }

    private func finishWorker(
        id: UUID,
        result: ([WatchlistWideView.WatchRow], [WatchlistWideView.WatchRow], [String])?,
        scope: UUID,
        requestedGeneration: UInt64,
        cacheKey: CacheKey?,
        rowCacheKeys: [String: RowCacheKey]
    ) {
        guard workerID == id else { return }
        worker = nil
        workerID = nil
        if let result, active, requestedGeneration == generation,
           storageService?.currentWatchlist.id == scope,
           let cacheKey {
            let next = Snapshot(
                scope: scope,
                rows: result.0,
                rowsBySymbol: Dictionary(result.0.map { ($0.symbol, $0) }, uniquingKeysWith: { first, _ in first }),
                visibleRows: result.1,
                displaySymbols: result.2,
                isLoading: false
            )
            snapshot = next
            for row in result.0 {
                if let key = rowCacheKeys[row.symbol] {
                    rowCacheBySymbol[row.symbol] = CachedRow(key: key, row: row)
                }
            }
            if rowCacheBySymbol.count > cachedRowLimit * 2 {
                let activeSymbols = Set(cacheKey.symbols)
                rowCacheBySymbol = rowCacheBySymbol.filter { activeSymbols.contains($0.key) }
            }
            cache(next, for: cacheKey)
        }
        if let next = pending {
            let key = CacheKey(watchlistID: next.1,
                               symbols: next.0.watchlist,
                               sortKey: next.0.sortKey,
                               sortAscending: next.0.sortAsc,
                               currency: next.0.stockPriceCurrency)
            startPending(key: key)
        }
    }

    private func cache(_ value: Snapshot, for key: CacheKey) {
        guard value.rows.count <= cachedRowLimit else { return }
        snapshotsByKey[key] = value
        touch(key)
        while snapshotsByKey.values.reduce(0, { $0 + $1.rows.count }) > cachedRowLimit,
              let oldest = snapshotLRU.first {
            snapshotLRU.removeFirst()
            snapshotsByKey.removeValue(forKey: oldest)
        }
    }

    private func touch(_ key: CacheKey) {
        snapshotLRU.removeAll { $0 == key }
        snapshotLRU.append(key)
    }
    
    private nonisolated static func computeRowsAndSort(inputs: ComputationInputs) -> ([WatchlistWideView.WatchRow], [WatchlistWideView.WatchRow], [String])? {
        let signpostID = PerformanceSignposts.begin("Watchlist rows", itemCount: inputs.watchlist.count)
        defer { PerformanceSignposts.end("Watchlist rows", id: signpostID) }
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
            if Task.isCancelled { return nil }
            if let cachedRow = inputs.reusableRows[symbol] {
                newRows.append(cachedRow)
                continue
            }
            let q = inputs.quotes[symbol]
            let rate = q.flatMap { inputs.priceRates[$0.currency] } ?? 1.0
            let ext: Double? = q.flatMap { $0.isExtendedHours ? $0.effectivePrice * rate : nil }
            let pHist = inputs.priceHistory[symbol] ?? []
            let wHist = inputs.history[symbol] ?? []
            let history: [PricePoint]
            if pHist.isEmpty {
                history = wHist
            } else if wHist.isEmpty {
                history = pHist
            } else {
                let pLast = pHist.last?.date ?? .distantPast
                let wLast = wHist.last?.date ?? .distantPast
                if pLast > wLast {
                    history = pHist
                } else if wLast > pLast {
                    history = wHist
                } else {
                    history = pHist.count >= wHist.count ? pHist : wHist
                }
            }
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
            let pointsToScan = allTimeHistory.isEmpty ? history : allTimeHistory
            for pt in pointsToScan {
                if Task.isCancelled { return nil }
                // Guard against unadjusted split spike anomalies in historical data
                let close = pt.close
                let rawHigh = pt.effectiveHigh
                let rawLow = pt.effectiveLow
                let h = (close > 0 && rawHigh > close * 3.0) ? close : rawHigh
                let l = (close > 0 && rawLow > 0 && rawLow < close * 0.25) ? close : rawLow
                if histHigh == nil || h > histHigh! { histHigh = h }
                if histLow == nil || l < histLow! { histLow = l }
            }
            // If allTimeHistory was used, also check high/low of recent 10y daily history for intraday precision
            if !allTimeHistory.isEmpty {
                for pt in history {
                    if Task.isCancelled { return nil }
                    let close = pt.close
                    let rawHigh = pt.effectiveHigh
                    let rawLow = pt.effectiveLow
                    let h = (close > 0 && rawHigh > close * 3.0) ? close : rawHigh
                    let l = (close > 0 && rawLow > 0 && rawLow < close * 0.25) ? close : rawLow
                    if histHigh == nil || h > histHigh! { histHigh = h }
                    if histLow == nil || l < histLow! { histLow = l }
                }
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
        return (newRows, sortedRows, displaySymbols)
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
