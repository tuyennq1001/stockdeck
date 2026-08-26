import SwiftUI
import Combine

@MainActor
@Observable
final class WatchlistViewModel {
    private var stockService: StockService?
    private var storageService: StorageService?
    
#if os(macOS)
    private(set) var rows: [WatchlistWideView.WatchRow] = []
    private(set) var visibleRows: [WatchlistWideView.WatchRow] = []
#endif
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
        
#if os(macOS)
        // 1. Build WatchlistWideView.WatchRow
        var newRows: [WatchlistWideView.WatchRow] = []
        
        // Re-use current time boundary to avoid recalculating per symbol
        let calendar = Calendar.current
        let now = Date()
        let monthStart = calendar.date(byAdding: .month, value: -1, to: now) ?? now
        let threeMonthStart = calendar.date(byAdding: .month, value: -3, to: now) ?? now
        let yearStart = calendar.date(from: calendar.dateComponents([.year], from: now)) ?? now
        
        for (index, symbol) in currentWatchlist.enumerated() {
            let q = stockService.quotes[symbol]
            let rate = q.map { stockService.priceRate(from: $0.currency) } ?? 1
            let ext: Double? = q.flatMap { $0.isExtendedHours ? $0.effectivePrice * rate : nil }
            let history = stockService.watchlistHistory[symbol] ?? []
            
            let regularPrice = q?.price ?? 0
            let indexFlag = q.map { StorageService.isIndex(symbol: $0.symbol, type: storageService.type(for: $0.symbol)) } ?? StorageService.isIndex(symbol: symbol, type: storageService.type(for: symbol))
            
            newRows.append(WatchlistWideView.WatchRow(
                id: symbol, order: index, symbol: symbol,
                name: q?.name ?? "",
                currency: indexFlag ? "" : ((storageService.stockPriceCurrency.isEmpty ? q?.currency : storageService.stockPriceCurrency) ?? ""),
                isIndex: indexFlag,
                rate: rate,
                price: (q?.price ?? 0) * rate,
                extPrice: ext,
                extChangePercent: ext != nil ? q?.extendedChangePercent : nil,
                extLabel: q?.marketStateLabel ?? "",
                change: (q?.change ?? 0) * rate,
                changePercent: q?.changePercent ?? 0,
                oneMonthChangePercent: PriceHistory.percentChange(points: history, currentPrice: regularPrice, since: monthStart),
                threeMonthChangePercent: PriceHistory.percentChange(points: history, currentPrice: regularPrice, since: threeMonthStart),
                ytdChangePercent: PriceHistory.percentChange(points: history, currentPrice: regularPrice, since: yearStart),
                history: history,
                allTimeHistory: stockService.priceHistoryMax[symbol] ?? [],
                loaded: q != nil, quote: q,
                marketCap: q?.marketCap.map { $0 * (q.map { stockService.rate(from: $0.currency) } ?? 1) }
            ))
        }
        
        self.rows = newRows
#endif
        
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
        
#if os(macOS)
        let rowsBySymbol = Dictionary(uniqueKeysWithValues: newRows.map { ($0.symbol, $0) })
        self.visibleRows = sortedSymbols.compactMap { rowsBySymbol[$0] }
#endif
        
        // 3. For WatchlistView (compact)
        self.displaySymbols = sortedSymbols
    }
}
