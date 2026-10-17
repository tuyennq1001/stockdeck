import Foundation
import Combine

/// Service responsible for fetching, parsing, caching, and serving earnings report data
/// for equities (upcoming report dates, consensus estimates, and historical Beat/Miss).
@MainActor
public final class EarningsService: ObservableObject {
    public static let shared = EarningsService()

    /// Earnings data indexed by clean uppercase symbol (e.g. "AAPL" -> EarningsReportItem)
    @Published public private(set) var earnings: [String: EarningsReportItem] = [:]

    /// Set of symbols currently being fetched from Yahoo Finance
    @Published public private(set) var loadingSymbols: Set<String> = []

    /// Single-flight task registry to prevent duplicate concurrent network requests for the same symbol
    private var inFlightTasks: [String: Task<Void, Never>] = [:]

    /// Rate-limiting semaphore: Yahoo Finance allows fair-use querying, capped at 3 concurrent requests
    private let requestGate = AsyncSemaphore(count: 3)

    /// In-memory cache timestamps
    private var lastFetchDates: [String: Date] = [:]

    /// Cache TTL: 24 hours (earnings dates & estimates change infrequently)
    private let cacheTTL: TimeInterval = 24 * 3600

    nonisolated private static var cacheDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = appSupport.appendingPathComponent("\(AppEnvironment.appSupportFolderName)/EarningsCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private init() {}

    // MARK: - Public API

    /// Clean ticker symbol for earnings lookup (strips Binance prefixes, USD suffixes, etc.)
    nonisolated public static func cleanSymbol(_ symbol: String) -> String {
        var clean = symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()

        // 1. Strip Binance Equity prefix
        let baseNoUSD = clean.hasSuffix("-USD") ? String(clean.dropLast(4)) : clean
        if baseNoUSD.hasPrefix("EQ_") && baseNoUSD.count > 3 {
            clean = String(baseNoUSD.dropFirst(3))
        }

        // 2. Strip standard US exchange suffixes like AAPL.US -> AAPL
        if clean.hasSuffix(".US") {
            clean = String(clean.dropLast(3))
        }

        // 3. Remove spaces
        clean = clean.replacingOccurrences(of: " ", with: "")
        return clean
    }

    /// Instance convenience method for cleanSymbol
    public func cleanSymbol(_ symbol: String) -> String {
        Self.cleanSymbol(symbol)
    }

    /// Known broad market ETFs and crypto/index instruments that do not report quarterly company earnings.
    nonisolated private static let knownNonReportingAssets: Set<String> = [
        "SPY", "VOO", "IVV", "QQQ", "QQQM", "VTI", "SCHD", "VUG", "VTV", "IWM", "DIA",
        "ARKK", "ARKG", "ARKW", "ARKF", "SMH", "SOXX", "XLK", "XLF", "XLV", "XLE",
        "XLY", "XLP", "XLI", "XLU", "XLB", "XLRE", "XLC", "GLD", "SLV", "IAU",
        "TLT", "IEF", "SHY", "BND", "AGG", "VNQ", "VXUS", "VEA", "VWO", "IEFA",
        "IEMG", "EFA", "EEM", "JEPI", "JEPQ", "TQQQ", "SQQQ", "SOXL", "SOXS",
        "IBIT", "FBTC", "BITO", "ETHA", "GBTC", "ETHE",
        "BTC", "ETH", "BNB", "SOL", "XRP", "DOGE", "ADA"
    ]

    /// Determines if a symbol represents an operating public equity eligible for earnings reports.
    nonisolated public static func isEligible(symbol: String, storedType: String? = nil) -> Bool {
        let clean = cleanSymbol(symbol)
        guard !clean.isEmpty else { return false }

        // 1. Exclude indices, futures, and currencies
        if clean.hasPrefix("^") || clean.contains("=F") || clean.contains("=X") || StockService.isIndexSymbol(clean) {
            return false
        }

        // 2. Exclude known non-reporting assets (ETFs, Crypto commodities)
        if knownNonReportingAssets.contains(clean) {
            return false
        }

        // 3. Exclude crypto pairs and stablecoin quotes
        if clean.hasSuffix("USDT") || clean.hasSuffix("BUSD") || clean.hasSuffix("USDC") || clean.hasSuffix("-USD") {
            return false
        }
        if StorageService.isBinanceNativePair(clean) || StorageService.isStandardCryptoSymbol(clean) {
            return false
        }

        // 4. Exclude Japanese funds / Japanese stocks
        if StockService.isJapaneseStock(clean) || StockService.isJapaneseMutualFund(clean) {
            return false
        }

        // 4. Check stored asset type if provided
        if let type = storedType?.uppercased() {
            if type == "INDEX" || type == "ETF" || type == "MUTUALFUND" ||
               type == "CRYPTOCURRENCY" || type == "FUTURE" || type == "CURRENCY" {
                return false
            }
        }

        return true
    }

    /// Instance convenience method for isEligible using StorageService
    public func isEligible(symbol: String) -> Bool {
        let storedType = StorageService.shared.type(for: symbol)
        return Self.isEligible(symbol: symbol, storedType: storedType)
    }

    /// Returns the cached EarningsReportItem if available.
    public func getEarnings(for symbol: String) -> EarningsReportItem? {
        let clean = cleanSymbol(symbol)
        return earnings[clean]
    }

    /// Ensures earnings data is loaded and cached for a single symbol.
    public func ensureEarnings(for symbol: String, force: Bool = false) async {
        guard isEligible(symbol: symbol) else { return }
        let clean = cleanSymbol(symbol)

        // 1. Return immediately if fresh cache exists in memory
        if !force,
           let lastFetch = lastFetchDates[clean],
           Date().timeIntervalSince(lastFetch) < cacheTTL,
           earnings[clean] != nil {
            return
        }

        // 2. Try loading from disk cache first
        if !force {
            let cached = await Task.detached(priority: .userInitiated) {
                Self.readDiskCache(for: clean, cacheTTL: 24 * 3600)
            }.value
            if let cached = cached {
                self.earnings[clean] = cached.item
                self.lastFetchDates[clean] = cached.modDate
                if cached.isFresh {
                    return
                }
            }
        }

        // 3. Deduplicate in-flight network requests
        if let existing = inFlightTasks[clean] {
            await existing.value
            return
        }

        let task = Task { [weak self] () -> Void in
            guard let self = self else { return }
            await self.fetchEarnings(symbol: clean)
        }
        inFlightTasks[clean] = task
        await task.value
        inFlightTasks.removeValue(forKey: clean)
    }

    /// Batch fetches earnings for multiple symbols on-demand.
    public func ensureEarnings(for symbols: [String], force: Bool = false) async {
        let unique = Array(Set(symbols.compactMap { sym -> String? in
            let clean = cleanSymbol(sym)
            return isEligible(symbol: clean) ? clean : nil
        })).sorted()

        // First pass: load any existing disk cache in a single batch to avoid thrashing @Published
        if !force {
            var batchCached: [String: EarningsReportItem] = [:]
            for sym in unique where earnings[sym] == nil {
                if let cached = readDiskCache(for: sym) {
                    batchCached[sym] = cached.item
                    self.lastFetchDates[sym] = cached.modDate
                }
            }
            if !batchCached.isEmpty {
                self.earnings.merge(batchCached) { _, new in new }
            }
        }

        let needed = unique.filter { sym in
            if force { return true }
            guard let lastFetch = lastFetchDates[sym], Date().timeIntervalSince(lastFetch) < cacheTTL else {
                return true
            }
            return earnings[sym] == nil
        }

        guard !needed.isEmpty else { return }

        // Set loading symbols in batch once
        loadingSymbols.formUnion(needed)
        defer { loadingSymbols.subtract(needed) }

        // Fetch in parallel throttled by semaphore, collecting results in batch
        await withTaskGroup(of: (String, EarningsReportItem?).self) { group in
            for sym in needed {
                group.addTask {
                    await self.requestGate.wait()
                    defer { self.requestGate.signal() }

                    guard let data = await StockService.shared.fetchEarningsQuoteSummary(for: sym) else {
                        return (sym, nil)
                    }

                    if let item = try? Self.parseEarningsResponse(data: data, symbol: sym) {
                        Self.saveDiskCache(for: sym, item: item)
                        return (sym, item)
                    }
                    return (sym, nil)
                }
            }

            var batchUpdates: [String: EarningsReportItem] = [:]
            for await (sym, item) in group {
                if let item {
                    batchUpdates[sym] = item
                    self.lastFetchDates[sym] = Date()
                }
            }
            if !batchUpdates.isEmpty {
                self.earnings.merge(batchUpdates) { _, new in new }
            }
        }
    }

    /// Checks whether the symbol has an upcoming earnings date within the next N days.
    public func hasUpcomingEarnings(for symbol: String, withinDays days: Int = 7) -> Bool {
        guard let item = getEarnings(for: symbol) else { return false }
        return item.isUpcoming(withinDays: days)
    }

    // MARK: - Internal Network Fetching

    private func fetchEarnings(symbol: String) async {
        await requestGate.wait()
        defer { requestGate.signal() }

        loadingSymbols.insert(symbol)
        defer { loadingSymbols.remove(symbol) }

        guard let data = await StockService.shared.fetchEarningsQuoteSummary(for: symbol) else {
            return
        }

        do {
            let item = try Self.parseEarningsResponse(data: data, symbol: symbol)
            self.earnings[symbol] = item
            self.lastFetchDates[symbol] = Date()
            self.saveDiskCache(for: symbol, item: item)
        } catch {
            // Silently ignore or leave existing cache
        }
    }

    // MARK: - Parsing (Pure, nonisolated, unit-testable)

    nonisolated static func parseEarningsResponse(
        data: Data,
        symbol: String,
        companyName: String? = nil,
        fetchedAt: Date = Date()
    ) throws -> EarningsReportItem {
        let decoder = JSONDecoder()
        let resp = try decoder.decode(YahooEarningsResponse.self, from: data)
        guard let result = resp.quoteSummary.result?.first else {
            return EarningsReportItem(symbol: symbol, companyName: companyName, fetchedAt: fetchedAt)
        }

        let cal = result.calendarEvents?.earnings
        let hist = result.earningsHistory?.history ?? []

        // 1. Next earnings dates
        var nextDate: Date? = nil
        var nextDateEnd: Date? = nil
        let isEstimate = cal?.isEarningsDateEstimate ?? false

        if let dates = cal?.earningsDate, !dates.isEmpty {
            if let firstRaw = dates.first?.raw {
                nextDate = Date(timeIntervalSince1970: TimeInterval(firstRaw))
            }
            if dates.count > 1, let secondRaw = dates[1].raw {
                nextDateEnd = Date(timeIntervalSince1970: TimeInterval(secondRaw))
            }
        }

        // 2. Session detection (BMO / AMC / TBD)
        let session: EarningsSession
        if isEstimate {
            session = .unspecified
        } else if let date = nextDate {
            var utcCal = Calendar(identifier: .gregorian)
            utcCal.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
            let hour = utcCal.component(.hour, from: date)
            if hour >= 10 && hour <= 15 {
                session = .bmo
            } else if hour >= 19 && hour <= 23 {
                session = .amc
            } else {
                session = .unspecified
            }
        } else {
            session = .unspecified
        }

        // 3. Estimates
        let epsEst = cal?.earningsAverage?.raw
        let epsLow = cal?.earningsLow?.raw
        let epsHigh = cal?.earningsHigh?.raw
        let revEst = cal?.revenueAverage?.raw
        let revLow = cal?.revenueLow?.raw
        let revHigh = cal?.revenueHigh?.raw

        // 4. History (up to 4 recent quarters, chronologically sorted)
        let qFin = result.earnings?.financialsChart?.quarterly ?? []
        let parsedHistory: [EarningsQuarterResult] = hist.enumerated().compactMap { idx, item in
            let qDate: Date? = item.quarter?.raw.map { Date(timeIntervalSince1970: TimeInterval($0)) }
            let fin = idx < qFin.count ? qFin[idx] : nil
            return EarningsQuarterResult(
                quarterDate: qDate,
                epsActual: item.epsActual?.raw,
                epsEstimate: item.epsEstimate?.raw,
                epsDifference: item.epsDifference?.raw,
                surprisePercent: item.surprisePercent?.raw,
                currency: item.currency ?? "USD",
                period: item.period,
                revenue: fin?.revenue?.raw,
                netIncome: fin?.earnings?.raw,
                profitMargin: fin?.profitMargin?.raw
            )
        }.sorted { (a, b) -> Bool in
            guard let da = a.quarterDate, let db = b.quarterDate else { return false }
            return da > db
        }

        // 5. Forward Trends (Guidance / Wall Street Consensus Outlook)
        let trendsList = result.earningsTrend?.trend ?? []
        let parsedTrends: [EarningsTrendItem] = trendsList.compactMap { t in
            guard let period = t.period, !period.isEmpty else { return nil }
            return EarningsTrendItem(
                period: period,
                endDate: t.endDate,
                epsEstimate: t.earningsEstimate?.avg?.raw,
                epsGrowth: t.earningsEstimate?.growth?.raw ?? t.growth?.raw,
                revenueEstimate: t.revenueEstimate?.avg?.raw,
                revenueGrowth: t.revenueEstimate?.growth?.raw,
                numberOfAnalysts: t.revenueEstimate?.numberOfAnalysts?.raw.map { Int($0) }
                    ?? t.earningsEstimate?.numberOfAnalysts?.raw.map { Int($0) }
            )
        }

        return EarningsReportItem(
            symbol: symbol,
            companyName: companyName,
            nextDate: nextDate,
            nextDateEnd: nextDateEnd,
            isDateEstimate: isEstimate,
            session: session,
            epsEstimate: epsEst,
            epsLow: epsLow,
            epsHigh: epsHigh,
            revenueEstimate: revEst,
            revenueLow: revLow,
            revenueHigh: revHigh,
            history: parsedHistory,
            trends: parsedTrends,
            fetchedAt: fetchedAt
        )
    }

    // MARK: - Disk Caching

    nonisolated static func cacheFilePath(for symbol: String) -> URL {
        cacheDirectory.appendingPathComponent("\(symbol)_earnings.json")
    }

    nonisolated func cacheFilePath(for symbol: String) -> URL {
        Self.cacheFilePath(for: symbol)
    }

    nonisolated static func saveDiskCache(for symbol: String, item: EarningsReportItem) {
        let path = cacheFilePath(for: symbol)
        Task.detached(priority: .background) {
            guard let data = try? JSONEncoder().encode(item) else { return }
            try? data.write(to: path, options: .atomic)
        }
    }

    nonisolated func saveDiskCache(for symbol: String, item: EarningsReportItem) {
        Self.saveDiskCache(for: symbol, item: item)
    }

    nonisolated static func readDiskCache(for symbol: String, cacheTTL: TimeInterval = 24 * 3600) -> (item: EarningsReportItem, modDate: Date, isFresh: Bool)? {
        let path = cacheFilePath(for: symbol)
        guard FileManager.default.fileExists(atPath: path.path),
              let attrs = try? FileManager.default.attributesOfItem(atPath: path.path),
              let modDate = attrs[.modificationDate] as? Date,
              let data = try? Data(contentsOf: path),
              let item = try? JSONDecoder().decode(EarningsReportItem.self, from: data) else {
            return nil
        }
        // Auto-upgrade cache if old cache format is missing revenue in history
        let needsUpgrade = !item.history.isEmpty && item.history.allSatisfy { $0.revenue == nil }
        let isFresh = !needsUpgrade && Date().timeIntervalSince(modDate) < cacheTTL
        return (item, modDate, isFresh)
    }

    func readDiskCache(for symbol: String) -> (item: EarningsReportItem, modDate: Date, isFresh: Bool)? {
        Self.readDiskCache(for: symbol, cacheTTL: cacheTTL)
    }

    @discardableResult
    func loadDiskCache(for symbol: String) -> (loaded: Bool, isFresh: Bool) {
        guard let cached = readDiskCache(for: symbol) else {
            return (false, false)
        }
        self.earnings[symbol] = cached.item
        self.lastFetchDates[symbol] = cached.modDate
        return (true, cached.isFresh)
    }
}

// MARK: - Yahoo Finance JSON Models (Private to EarningsService)

private struct YahooEarningsResponse: Decodable {
    let quoteSummary: QuoteSummary

    struct QuoteSummary: Decodable {
        let result: [ResultItem]?
        let error: ErrorItem?
    }

    struct ResultItem: Decodable {
        let calendarEvents: CalendarEvents?
        let earningsHistory: EarningsHistory?
        let earnings: EarningsModule?
        let earningsTrend: EarningsTrendModule?
    }

    struct EarningsTrendModule: Decodable {
        let trend: [TrendItem]?
    }

    struct TrendItem: Decodable {
        let period: String?
        let endDate: String?
        let growth: YahooRawNum?
        let earningsEstimate: TrendMetric?
        let revenueEstimate: TrendMetric?
    }

    struct TrendMetric: Decodable {
        let avg: YahooRawNum?
        let low: YahooRawNum?
        let high: YahooRawNum?
        let numberOfAnalysts: YahooRawNum?
        let growth: YahooRawNum?
    }

    struct EarningsModule: Decodable {
        let financialsChart: FinancialsChart?
    }

    struct FinancialsChart: Decodable {
        let quarterly: [QuarterlyFinancial]?
    }

    struct QuarterlyFinancial: Decodable {
        let date: String?
        let revenue: YahooRawNum?
        let earnings: YahooRawNum?
        let profitMargin: YahooRawNum?
    }

    struct CalendarEvents: Decodable {
        let earnings: EarningsDetails?
    }

    struct EarningsDetails: Decodable {
        let earningsDate: [YahooRawDate]?
        let isEarningsDateEstimate: Bool?
        let earningsAverage: YahooRawNum?
        let earningsLow: YahooRawNum?
        let earningsHigh: YahooRawNum?
        let revenueAverage: YahooRawNum?
        let revenueLow: YahooRawNum?
        let revenueHigh: YahooRawNum?
    }

    struct EarningsHistory: Decodable {
        let history: [HistoryItem]?
    }

    struct HistoryItem: Decodable {
        let quarter: YahooRawDate?
        let epsActual: YahooRawNum?
        let epsEstimate: YahooRawNum?
        let epsDifference: YahooRawNum?
        let surprisePercent: YahooRawNum?
        let currency: String?
        let period: String?
    }

    struct YahooRawDate: Decodable {
        let raw: Int?
        let fmt: String?
    }

    struct YahooRawNum: Decodable {
        let raw: Double?
        let fmt: String?
    }

    struct ErrorItem: Decodable {
        let code: String?
        let description: String?
    }
}
