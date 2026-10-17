import Foundation

/// Service responsible for fetching, parsing, and caching SEC Form 4 insider trading
/// transactions for US-listed public companies.
@MainActor
public final class InsiderTradingService: ObservableObject {
    public static let shared = InsiderTradingService()

    /// Transactions indexed by uppercase symbol (e.g. "AAPL" -> [InsiderTransaction])
    @Published public private(set) var transactions: [String: [InsiderTransaction]] = [:]

    /// Sentiment summary computed for each symbol
    @Published public private(set) var sentiment: [String: InsiderSentimentSummary] = [:]

    /// Set of symbols currently being fetched from SEC EDGAR
    @Published public private(set) var loadingSymbols: Set<String> = []

    /// Symbols that failed to fetch or parse
    @Published public private(set) var errorSymbols: [String: String] = [:]

    /// In-memory CIK mapping (Ticker -> CIK String padded to 10 digits)
    private var tickerToCik: [String: String] = [:]
    private var isCikMapLoaded = false
    private var cikMapLoadingTask: Task<Void, Never>?

    /// Single-flight task registry to avoid concurrent duplicate requests
    private var inFlightTasks: [String: Task<Void, Never>] = [:]

    /// Rate-limiting semaphore: SEC EDGAR fair-use allows up to 10 req/sec.
    /// We cap concurrency at 3 simultaneous requests.
    nonisolated private let requestGate = AsyncSemaphore(count: 3)

    /// In-memory cache timestamps
    private var lastFetchDates: [String: Date] = [:]
    /// TTL for cache: 12 hours (Form 4 filings are typically once or twice a week per company)
    private let cacheTTL: TimeInterval = 12 * 3600

    nonisolated private let session: URLSession

    nonisolated private static var cacheDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = appSupport.appendingPathComponent("\(AppEnvironment.appSupportFolderName)/InsiderCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private var cacheDirectory: URL {
        Self.cacheDirectory
    }

    private init() {
        let config = URLSessionConfiguration.default
        config.httpAdditionalHeaders = [
            // Complies with SEC EDGAR requirement for descriptive User-Agent with contact
            "User-Agent": "StockDeck/1.0 (contact@stockdeck.app)"
        ]
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        self.session = URLSession(configuration: config)
    }

    // MARK: - Public API

    /// Ensures insider transactions are fetched and cached for the given symbol.
    public func ensureTransactions(for symbol: String, force: Bool = false) async {
        let detectedMarket = market(for: symbol)
        guard detectedMarket != .unsupported else { return }
        let clean = cleanSymbol(symbol)

        // Return if fresh in-memory cache exists and not forced
        if !force,
           let lastFetch = lastFetchDates[clean],
           Date().timeIntervalSince(lastFetch) < cacheTTL,
           transactions[clean] != nil {
            return
        }

        // Always read disk cache into memory first if not in memory
        var isDiskFresh = false
        if transactions[clean] == nil {
            let ttl = cacheTTL
            if let cached = await Task.detached(priority: .userInitiated, operation: {
                Self.readDiskCache(for: clean, cacheTTL: ttl)
            }).value {
                self.transactions[clean] = cached.txs
                self.sentiment[clean] = computeSentiment(symbol: clean, transactions: cached.txs, lookbackMonths: 60)
                self.lastFetchDates[clean] = cached.modDate
                isDiskFresh = cached.isFresh
            }
        } else if let lastFetch = lastFetchDates[clean] {
            isDiskFresh = Date().timeIntervalSince(lastFetch) < cacheTTL
        }

        // Return immediately if disk cache was loaded and is still fresh and not forced
        if !force && isDiskFresh {
            return
        }

        // Single-flight deduplication
        if let existing = inFlightTasks[clean] {
            await existing.value
            return
        }

        let task = Task { [weak self] () -> Void in
            guard let self = self else { return }
            switch detectedMarket {
            case .us:
                await self.fetchFromSec(symbol: clean)
            case .vn:
                await self.fetchFromVN(symbol: clean)
            case .unsupported:
                break
            }
        }
        inFlightTasks[clean] = task
        await task.value
        inFlightTasks.removeValue(forKey: clean)
    }

    /// Synchronous accessor for transactions matching the symbol and optional date range
    public func getTransactions(for symbol: String, startDate: Date? = nil, endDate: Date? = nil, openMarketOnly: Bool = false) -> [InsiderTransaction] {
        let clean = cleanSymbol(symbol)
        guard let list = transactions[clean] else { return [] }
        return list.filter { tx in
            if openMarketOnly && !tx.isOpenMarket { return false }
            if let start = startDate, tx.transactionDate < start { return false }
            if let end = endDate, tx.transactionDate > end { return false }
            return true
        }
    }

    /// Whether the Insider Trading card should be displayed in Symbol Details / Holding Details.
    /// Returns true only for supported markets (US & VN equities) that have recorded transactions in the lookback period.
    public func shouldShowCard(for symbol: String) -> Bool {
        guard isEligibleSymbol(symbol) else { return false }
        let clean = cleanSymbol(symbol)
        guard let list = transactions[clean], !list.isEmpty else { return false }
        return true
    }

    /// Whether the chart Insider marker toggle should be shown (requires at least one executed trade).
    public func hasExecutedChartTrades(for symbol: String) -> Bool {
        guard isEligibleSymbol(symbol) else { return false }
        let clean = cleanSymbol(symbol)
        guard let list = transactions[clean] else { return false }
        return list.contains { !$0.isPendingPlan && $0.isOpenMarket && $0.shares > 0 }
    }

    // MARK: - Symbol Eligibility & Market Detection

    private static let knownETFs: Set<String> = [
        "SPY", "VOO", "IVV", "QQQ", "QQQM", "VTI", "SCHD", "VUG", "VTV", "IWM", "DIA",
        "ARKK", "ARKG", "ARKW", "ARKF", "SMH", "SOXX", "XLK", "XLF", "XLV", "XLE",
        "XLY", "XLP", "XLI", "XLU", "XLB", "XLRE", "XLC", "GLD", "SLV", "IAU",
        "TLT", "IEF", "SHY", "BND", "AGG", "VNQ", "VXUS", "VEA", "VWO", "IEFA",
        "IEMG", "EFA", "EEM", "JEPI", "JEPQ", "TQQQ", "SQQQ", "SOXL", "SOXS",
        "IBIT", "FBTC", "BITO", "ETHA", "GBTC", "ETHE", "E1VFVN30", "FUEVFVND",
        "FUESSVFL", "FUEKIV30", "FUEMAV30", "FUESSV50", "FUESSV30", "FUEIP100"
    ]

    private static let supportedUSShareClassSuffixes: Set<String> = ["US", "A", "B", "C"]

    /// Determines the regulatory insider trading market (.us, .vn, or .unsupported) for a symbol.
    public func market(for symbol: String) -> InsiderMarket {
        let upper = symbol.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !upper.isEmpty else { return .unsupported }

        // 1. Exclude indices, futures, commodities, and forex immediately
        if upper.hasPrefix("^") || upper.contains("=F") || upper.contains("=X") || StockService.isIndexSymbol(upper) {
            return .unsupported
        }

        let storedType = StorageService.shared.type(for: symbol).uppercased()
        if storedType == "INDEX" || storedType == "ETF" || storedType == "MUTUALFUND" ||
           storedType == "CRYPTOCURRENCY" || storedType == "FUTURE" || storedType == "CURRENCY" {
            return .unsupported
        }

        // 2. Exclude Japanese stocks and Japanese mutual funds
        if StockService.isJapaneseStock(upper) || StockService.isJapaneseMutualFund(upper) {
            return .unsupported
        }

        // 3. Handle Binance US Equity holdings (e.g. EQ_META, EQ_META-USD, EQ_GOOGL, EQ_ALPHABET)
        let baseNoUSD = upper.hasSuffix("-USD") ? String(upper.dropLast(4)) : upper
        if baseNoUSD.hasPrefix("EQ_") && baseNoUSD.count > 3 {
            let clean = cleanSymbol(upper)
            if Self.knownETFs.contains(clean) { return .unsupported }
            return .us
        }

        // 4. Detect Vietnamese equities (HOSE / HNX / UPCoM)
        let storedExchange = StorageService.shared.exchange(for: symbol)
        if StockService.isVietnameseStock(upper, exchange: storedExchange) {
            let clean = cleanSymbol(upper)
            if clean == "VNINDEX" || clean == "HNXINDEX" || clean == "UPINDEX" ||
               clean.hasPrefix("FUE") || Self.knownETFs.contains(clean) {
                return .unsupported
            }
            return .vn
        }

        // 5. Exclude cryptocurrencies and stablecoin pairs (BTC-USD, ETH-USD, BTCUSDT, SOLUSDC, BTCETH...)
        if upper.hasSuffix("-USD") {
            if StorageService.isStandardCryptoSymbol(baseNoUSD) || storedType != "EQUITY" {
                return .unsupported
            }
        }
        if StorageService.isStandardCryptoSymbol(upper) {
            return .unsupported
        }
        let cryptoQuoteSuffixes = ["USDT", "USDC", "BUSD", "FDUSD", "TUSD", "DAI"]
        for suffix in cryptoQuoteSuffixes where upper.hasSuffix(suffix) && upper.count > suffix.count {
            return .unsupported
        }
        let cryptoBaseQuoteSuffixes = ["BTC", "ETH", "BNB"]
        for suffix in cryptoBaseQuoteSuffixes where upper.hasSuffix(suffix) && upper.count > suffix.count {
            let prefix = String(upper.dropLast(suffix.count))
            if StorageService.isStandardCryptoSymbol(prefix) {
                return .unsupported
            }
        }

        // 6. Exclude non-US international stock exchanges (.KS, .KQ, .T, .HK, .L, .DE, .PA, .TW, .SS, .SZ, .TO, .AX, .SI...)
        if upper.contains(".") {
            let parts = upper.split(separator: ".")
            if parts.count >= 2, let suffix = parts.last.map(String.init) {
                if !Self.supportedUSShareClassSuffixes.contains(suffix) {
                    return .unsupported
                }
            }
        }

        let clean = cleanSymbol(upper)
        guard !clean.isEmpty, !Self.knownETFs.contains(clean) else {
            return .unsupported
        }

        // 7. If SEC CIK map is already loaded in memory, verify the US ticker exists in SEC EDGAR
        if isCikMapLoaded && !tickerToCik.isEmpty {
            let cikKey = clean.replacingOccurrences(of: ".", with: "-")
            if tickerToCik[clean] == nil && tickerToCik[cikKey] == nil {
                return .unsupported
            }
        }

        return .us
    }

    public func isEligibleSymbol(_ symbol: String) -> Bool {
        market(for: symbol) != .unsupported
    }

    public func isEligibleUSSymbol(_ symbol: String) -> Bool {
        market(for: symbol) == .us
    }

    public func isEligibleVNSymbol(_ symbol: String) -> Bool {
        market(for: symbol) == .vn
    }

    public func cleanSymbol(_ symbol: String) -> String {
        let canonical = StockService.canonicalSymbol(for: symbol)
        return canonical.uppercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ".US", with: "")
            .replacingOccurrences(of: ".VN", with: "")
            .replacingOccurrences(of: ".HM", with: "")
            .replacingOccurrences(of: ".HN", with: "")
    }

    // MARK: - CIK Mapping

    nonisolated private static func parseCikMapBackground(data: Data) -> [String: String]? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] else {
            return nil
        }
        var map: [String: String] = [:]
        for (_, entry) in json {
            guard let ticker = entry["ticker"] as? String,
                  let cikInt = entry["cik_str"] as? Int else { continue }
            let padded = String(format: "%010d", cikInt)
            map[ticker.uppercased()] = padded
        }
        return map
    }

    private func ensureCikMap() async {
        if isCikMapLoaded && !tickerToCik.isEmpty { return }

        if let existing = cikMapLoadingTask {
            await existing.value
            return
        }

        let cacheDir = self.cacheDirectory
        let session = self.session
        let gate = self.requestGate

        let backgroundTask = Task.detached(priority: .utility) { () -> [String: String]? in
            let file = cacheDir.appendingPathComponent("company_tickers.json")
            if let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
               let modDate = attrs[.modificationDate] as? Date,
               Date().timeIntervalSince(modDate) < 30 * 86400,
               let data = try? Data(contentsOf: file) {
                return Self.parseCikMapBackground(data: data)
            }

            guard let url = URL(string: "https://www.sec.gov/files/company_tickers.json") else { return nil }
            do {
                await gate.wait()
                defer { gate.signal() }
                let (data, response) = try await session.data(from: url)
                if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                    try? data.write(to: file, options: .atomic)
                    return Self.parseCikMapBackground(data: data)
                }
            } catch { }
            return nil
        }

        let mainTask = Task { [weak self] in
            if let map = await backgroundTask.value {
                self?.tickerToCik = map
                self?.isCikMapLoaded = true
            }
        }
        cikMapLoadingTask = mainTask
        await mainTask.value
        cikMapLoadingTask = nil
    }

    // MARK: - SEC EDGAR Fetching

    private func fetchFromSec(symbol: String) async {
        loadingSymbols.insert(symbol)
        defer { loadingSymbols.remove(symbol) }

        await ensureCikMap()

        let cikKey = symbol.replacingOccurrences(of: ".", with: "-")
        guard let cik10 = tickerToCik[symbol] ?? tickerToCik[cikKey] else {
            errorSymbols[symbol] = "CIK not found for \(symbol)"
            return
        }

        guard let submissionsURL = URL(string: "https://data.sec.gov/submissions/CIK\(cik10).json") else {
            return
        }

        do {
            await requestGate.wait()
            let (data, response) = try await session.data(from: submissionsURL)
            requestGate.signal()

            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                errorSymbols[symbol] = "SEC submissions returned error"
                return
            }

            let existing = transactions[symbol] ?? []
            var knownAccessions = Set<String>()
            for tx in existing {
                if let acc = tx.id.components(separatedBy: "_").first {
                    knownAccessions.insert(acc)
                }
            }

            let targetFilings = await Task.detached(priority: .utility) { () -> [(accession: String, doc: String, filingDate: String)] in
                guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let filings = root["filings"] as? [String: Any],
                      let recent = filings["recent"] as? [String: Any],
                      let forms = recent["form"] as? [String],
                      let accessions = recent["accessionNumber"] as? [String],
                      let primaryDocs = recent["primaryDocument"] as? [String],
                      let filingDates = recent["filingDate"] as? [String] else {
                    return []
                }
                var list: [(accession: String, doc: String, filingDate: String)] = []
                let fiveYearsAgo = Calendar.current.date(byAdding: .year, value: -5, to: Date()) ?? Date.distantPast
                for i in 0..<min(forms.count, accessions.count, primaryDocs.count, filingDates.count) {
                    guard forms[i] == "4" else { continue }
                    let acc = accessions[i]
                    let dateStr = filingDates[i]
                    if let filingDate = DateFormatter.secDate.date(from: dateStr), filingDate < fiveYearsAgo {
                        break
                    }
                    if !knownAccessions.contains(acc) {
                        list.append((accession: acc, doc: primaryDocs[i], filingDate: dateStr))
                    }
                }
                return list
            }.value

            let cikIntString = String(Int(cik10) ?? 0)

            // If no new filings need downloading, our existing cache is fully up to date!
            if targetFilings.isEmpty {
                self.sentiment[symbol] = computeSentiment(symbol: symbol, transactions: existing, lookbackMonths: 60)
                self.lastFetchDates[symbol] = Date()
                return
            }

            let immediateLimit = 35
            let immediateFilings = Array(targetFilings.prefix(immediateLimit))
            let remainingFilings = Array(targetFilings.dropFirst(immediateLimit))

            // Phase 1: Fetch immediate batch (recent filings first)
            let immediateTxs = await fetchAndParseFilings(immediateFilings, cikIntString: cikIntString, symbol: symbol)

            // Merge new filings with existing historical database
            var combined = immediateTxs + existing
            combined.sort { $0.transactionDate > $1.transactionDate }

            // Deduplicate by unique transaction ID and keep only positive price trades
            var seen = Set<String>()
            let uniqueTxs = combined.filter { $0.price > 0 && $0.shares > 0 && seen.insert($0.id).inserted }

            self.transactions[symbol] = uniqueTxs
            self.sentiment[symbol] = computeSentiment(symbol: symbol, transactions: uniqueTxs, lookbackMonths: 60)
            self.lastFetchDates[symbol] = Date()
            self.errorSymbols.removeValue(forKey: symbol)
            self.loadingSymbols.remove(symbol)

            saveDiskCache(for: symbol, txs: uniqueTxs)

            // Phase 2: If there are remaining older filings (e.g. initial 5-year backfill), backfill in background
            if !remainingFilings.isEmpty {
                startBackgroundBackfill(
                    remainingFilings: remainingFilings,
                    cikIntString: cikIntString,
                    symbol: symbol
                )
            }
        } catch {
            self.errorSymbols[symbol] = error.localizedDescription
        }
    }

    nonisolated private func fetchAndParseFilings(
        _ filings: [(accession: String, doc: String, filingDate: String)],
        cikIntString: String,
        symbol: String
    ) async -> [InsiderTransaction] {
        await withTaskGroup(of: [InsiderTransaction].self) { group in
            for filing in filings {
                group.addTask { [session = self.session, requestGate = self.requestGate] in
                    guard !Task.isCancelled else { return [] }
                    let accessionNoHyphen = filing.accession.replacingOccurrences(of: "-", with: "")
                    let docName = filing.doc.components(separatedBy: "/").last ?? "form4.xml"
                    let xmlURLString = "https://www.sec.gov/Archives/edgar/data/\(cikIntString)/\(accessionNoHyphen)/\(docName)"

                    guard let xmlURL = URL(string: xmlURLString) else { return [] }

                    do {
                        await requestGate.wait()
                        defer { requestGate.signal() }
                        guard !Task.isCancelled else { return [] }
                        let (xmlData, xmlResp) = try await session.data(from: xmlURL)
                        guard let xmlHttp = xmlResp as? HTTPURLResponse, xmlHttp.statusCode == 200 else {
                            return []
                        }

                        let filingDate = ISO8601DateFormatter().date(from: filing.filingDate)
                            ?? DateFormatter.secDate.date(from: filing.filingDate)

                        return Form4XMLParser.parse(data: xmlData, symbol: symbol, filingId: filing.accession, filingDate: filingDate)
                    } catch {
                        return []
                    }
                }
            }

            var results: [InsiderTransaction] = []
            for await list in group {
                results.append(contentsOf: list)
            }
            return results
        }
    }

    private func startBackgroundBackfill(
        remainingFilings: [(accession: String, doc: String, filingDate: String)],
        cikIntString: String,
        symbol: String
    ) {
        Task.detached(priority: .utility) { [weak self] in
            guard let self = self else { return }

            let chunkSize = 25
            for i in stride(from: 0, to: remainingFilings.count, by: chunkSize) {
                if Task.isCancelled { break }

                let chunk = Array(remainingFilings[i..<min(i + chunkSize, remainingFilings.count)])
                let chunkTxs = await self.fetchAndParseFilings(chunk, cikIntString: cikIntString, symbol: symbol)

                if !chunkTxs.isEmpty {
                    await self.mergeAndPersist(chunkTxs: chunkTxs, symbol: symbol)
                }

                // Polite pause between chunks to respect SEC fair-use
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
    }

    private func mergeAndPersist(chunkTxs: [InsiderTransaction], symbol: String) {
        let current = self.transactions[symbol] ?? []
        var combined = chunkTxs + current
        combined.sort { $0.transactionDate > $1.transactionDate }

        var seen = Set<String>()
        let uniqueTxs = combined.filter { $0.price > 0 && $0.shares > 0 && seen.insert($0.id).inserted }

        self.transactions[symbol] = uniqueTxs
        self.sentiment[symbol] = computeSentiment(symbol: symbol, transactions: uniqueTxs, lookbackMonths: 60)
        saveDiskCache(for: symbol, txs: uniqueTxs)
    }

    // MARK: - Vietnam Insider Fetching

    private func fetchFromVN(symbol: String) async {
        loadingSymbols.insert(symbol)
        defer { loadingSymbols.remove(symbol) }

        var components = URLComponents(string: VNMarketConfig.insiderTransactionsBaseURL)
        components?.queryItems = [
            URLQueryItem(name: "Symbol", value: symbol),
            URLQueryItem(name: "StartDate", value: ""),
            URLQueryItem(name: "EndDate", value: ""),
            URLQueryItem(name: "PageIndex", value: "1"),
            URLQueryItem(name: "PageSize", value: "50")
        ]
        guard let url = components?.url else { return }

        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10

        do {
            await requestGate.wait()
            let (data, response) = try await session.data(for: request)
            requestGate.signal()

            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                errorSymbols[symbol] = "VN insider endpoint returned error"
                return
            }

            let parsed = await Task.detached(priority: .utility) {
                VNInsiderParser.parse(data: data, symbol: symbol, lookbackMonths: 60)
            }.value

            let existing = self.transactions[symbol] ?? []
            var combined = parsed + existing
            combined.sort { $0.transactionDate > $1.transactionDate }

            var seen = Set<String>()
            let uniqueTxs = combined.filter { ($0.price > 0 || $0.isVNDisclosure) && $0.shares > 0 && seen.insert($0.id).inserted }

            self.transactions[symbol] = uniqueTxs
            self.sentiment[symbol] = computeSentiment(symbol: symbol, transactions: uniqueTxs, lookbackMonths: 60)
            self.lastFetchDates[symbol] = Date()
            self.errorSymbols.removeValue(forKey: symbol)

            saveDiskCache(for: symbol, txs: uniqueTxs)
        } catch {
            self.errorSymbols[symbol] = error.localizedDescription
        }
    }

    // MARK: - Price Resolution for Disclosures (Historical & Fallback)

    /// Resolves the effective execution price for a transaction.
    /// For US Form 4, returns `tx.price`.
    /// For VN disclosures (where price is not in the disclosure list), looks up the historical closing
    /// price from StockService for the transaction date. If date is not covered or PLAN, falls back to current quote.
    public func resolvedPrice(for tx: InsiderTransaction, rawSymbol: String? = nil) -> Double {
        if tx.price > 0 { return tx.price }
        guard tx.isVNDisclosure else { return 0 }

        let sym = rawSymbol ?? tx.symbol
        let candidates = [
            sym,
            "\(sym).VN",
            "\(sym).HM",
            "\(sym).HN",
            sym.replacingOccurrences(of: ".VN", with: "").replacingOccurrences(of: ".HM", with: "").replacingOccurrences(of: ".HN", with: "")
        ]

        let stockService = StockService.shared

        // 1. Check historical price points
        for candidate in candidates {
            let history = (stockService.priceHistory[candidate] ?? stockService.priceHistoryMax[candidate]) ?? []
            if !history.isEmpty {
                if let best = PriceHistory.nearestPoint(to: tx.transactionDate, in: history) {
                    let diff = abs(best.date.timeIntervalSince(tx.transactionDate))
                    if diff <= 7 * 86400, best.close > 0 {
                        let close = best.close
                        return close < 500 ? close * 1000.0 : close
                    }
                }
            }
        }

        // 2. Fallback to current quote
        for candidate in candidates {
            if let quote = stockService.quotes[candidate], quote.price > 0 {
                let p = quote.price
                return p < 500 ? p * 1000.0 : p
            }
        }

        return 0
    }

    /// Resolves total monetary value of an insider trade.
    public func resolvedTotalValue(for tx: InsiderTransaction, rawSymbol: String? = nil) -> Double {
        let p = resolvedPrice(for: tx, rawSymbol: rawSymbol)
        return tx.shares * p
    }

    /// Synchronous accessor for sentiment summary using latest available price quotes/history
    public func sentimentSummary(for symbol: String, lookbackMonths: Int = 60) -> InsiderSentimentSummary? {
        let clean = cleanSymbol(symbol)
        guard let list = transactions[clean] else { return nil }
        return computeSentiment(symbol: symbol, transactions: list, lookbackMonths: lookbackMonths)
    }

    // MARK: - Sentiment Calculation

    public func computeSentiment(symbol: String, transactions: [InsiderTransaction], lookbackMonths: Int = 60) -> InsiderSentimentSummary {
        let calendar = Calendar.current
        let cutoff = calendar.date(byAdding: .month, value: -lookbackMonths, to: Date()) ?? Date.distantPast

        let recent = transactions.filter { $0.transactionDate >= cutoff }
        // Exclude pending unexecuted registrations from completed volume totals when executed trades exist
        let hasExecuted = recent.contains { !$0.isPendingPlan }
        let pool = hasExecuted ? recent.filter { !$0.isPendingPlan } : recent

        var buyShares = 0.0
        var sellShares = 0.0
        var buyValue = 0.0
        var sellValue = 0.0
        var buyCount = 0
        var sellCount = 0
        var openMarketBuyCount = 0
        var openMarketSellCount = 0

        for tx in pool {
            let val = resolvedTotalValue(for: tx, rawSymbol: symbol)
            let effectiveVal = val > 0 ? val : tx.totalValue
            if tx.isBuy {
                buyShares += tx.shares
                buyValue += effectiveVal
                buyCount += 1
                if tx.isOpenMarket { openMarketBuyCount += 1 }
            } else {
                sellShares += tx.shares
                sellValue += effectiveVal
                sellCount += 1
                if tx.isOpenMarket { openMarketSellCount += 1 }
            }
        }

        return InsiderSentimentSummary(
            symbol: symbol,
            lookbackMonths: lookbackMonths,
            totalBuyShares: buyShares,
            totalSellShares: sellShares,
            totalBuyValue: buyValue,
            totalSellValue: sellValue,
            buyCount: buyCount,
            sellCount: sellCount,
            openMarketBuyCount: openMarketBuyCount,
            openMarketSellCount: openMarketSellCount
        )
    }

    // MARK: - Background Sync for Watchlist & Portfolios

    /// Periodically syncs insider filings for all eligible US & VN symbols in user portfolios and watchlists.
    /// Runs as a polite, throttled background queue.
    func syncAllUserSymbols(storageService: StorageService) async {
        var symbols = Set<String>()
        for p in storageService.portfolios {
            for h in p.holdings {
                if isEligibleSymbol(h.symbol) { symbols.insert(h.symbol) }
            }
        }
        for w in storageService.watchlists {
            for s in w.symbols {
                if isEligibleSymbol(s) { symbols.insert(s) }
            }
        }

        guard !symbols.isEmpty else { return }

        for sym in symbols {
            await ensureTransactions(for: sym)
            // Polite pause between symbols to maintain compliance and zero UI impact
            try? await Task.sleep(nanoseconds: 350_000_000)
        }
    }

    // MARK: - Disk Caching

    nonisolated static func cacheFilePath(for symbol: String) -> URL {
        cacheDirectory.appendingPathComponent("\(symbol)_insider.json")
    }

    func cacheFilePath(for symbol: String) -> URL {
        Self.cacheFilePath(for: symbol)
    }

    nonisolated static func readDiskCache(for symbol: String, cacheTTL: TimeInterval) -> (txs: [InsiderTransaction], modDate: Date, isFresh: Bool)? {
        let path = cacheFilePath(for: symbol)
        guard FileManager.default.fileExists(atPath: path.path),
              let attrs = try? FileManager.default.attributesOfItem(atPath: path.path),
              let modDate = attrs[.modificationDate] as? Date,
              let data = try? Data(contentsOf: path),
              let decoded = try? JSONDecoder().decode([InsiderTransaction].self, from: data) else {
            return nil
        }
        let validTxs = decoded.filter { $0.shares > 0 && ($0.price > 0 || $0.isVNDisclosure) }
        let isFresh = Date().timeIntervalSince(modDate) < cacheTTL
        return (validTxs, modDate, isFresh)
    }

    func saveDiskCache(for symbol: String, txs: [InsiderTransaction], synchronous: Bool = false) {
        let path = Self.cacheFilePath(for: symbol)
        let writeBlock = {
            guard let data = try? JSONEncoder().encode(txs) else { return }
            try? data.write(to: path, options: .atomic)
        }
        if synchronous {
            writeBlock()
        } else {
            Task.detached(priority: .background) {
                writeBlock()
            }
        }
    }

    @discardableResult
    func loadDiskCache(for symbol: String) -> (loaded: Bool, isFresh: Bool) {
        guard let cached = Self.readDiskCache(for: symbol, cacheTTL: cacheTTL) else {
            return (false, false)
        }
        self.transactions[symbol] = cached.txs
        self.sentiment[symbol] = computeSentiment(symbol: symbol, transactions: cached.txs, lookbackMonths: 60)
        self.lastFetchDates[symbol] = cached.modDate
        return (true, cached.isFresh)
    }
}

// MARK: - XML Parser for Form 4

public final class Form4XMLParser: NSObject, XMLParserDelegate {
    private var symbol: String
    private var filingId: String
    private var filingDate: Date?

    private var currentElement = ""
    private var currentValue = ""

    // Owner fields
    private var ownerName = ""
    private var officerTitle = ""
    private var isDirector = false
    private var isOfficer = false
    private var isTenPercentOwner = false
    private var inReportingOwner = false

    // Non-derivative transaction fields
    private var inNonDerivativeTransaction = false
    private var txDateString = ""
    private var txCode = ""
    private var txShares = 0.0
    private var txPrice = 0.0
    private var txAcqDisp = ""
    private var txPostShares = 0.0
    private var txIsRule10b51 = false
    private var txFootnoteIds: Set<String> = []

    // Footnotes & Document-level 10b5-1
    private var inFootnotes = false
    private var currentFootnoteId = ""
    private var currentFootnoteText = ""
    private var footnoteMap: [String: String] = [:]
    private var docIsRule10b51 = false
    private var transactionFootnoteIds: [Int: Set<String>] = [:]

    private var parsedTransactions: [InsiderTransaction] = []
    private var txIndex = 0

    public static func parse(data: Data, symbol: String, filingId: String, filingDate: Date?) -> [InsiderTransaction] {
        let parser = Form4XMLParser(symbol: symbol, filingId: filingId, filingDate: filingDate)
        let xmlParser = XMLParser(data: data)
        xmlParser.delegate = parser
        xmlParser.parse()
        return parser.parsedTransactions
    }

    private init(symbol: String, filingId: String, filingDate: Date?) {
        self.symbol = symbol
        self.filingId = filingId
        self.filingDate = filingDate
        super.init()
    }

    public func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        currentElement = elementName
        currentValue = ""

        if elementName == "reportingOwner" {
            inReportingOwner = true
        } else if elementName == "nonDerivativeTransaction" {
            inNonDerivativeTransaction = true
            txDateString = ""
            txCode = ""
            txShares = 0.0
            txPrice = 0.0
            txAcqDisp = ""
            txPostShares = 0.0
            txIsRule10b51 = false
            txFootnoteIds = []
        } else if elementName == "footnote" {
            inFootnotes = true
            currentFootnoteId = attributeDict["id"] ?? ""
            currentFootnoteText = ""
        } else if elementName == "footnoteId" {
            if let fId = attributeDict["id"] {
                txFootnoteIds.insert(fId)
            }
        }
    }

    public func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inFootnotes {
            currentFootnoteText += string
        } else {
            currentValue += string.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    public func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if inFootnotes && elementName == "footnote" {
            inFootnotes = false
            if !currentFootnoteId.isEmpty {
                footnoteMap[currentFootnoteId] = currentFootnoteText
            }
        }

        let lowerTag = elementName.lowercased()
        if lowerTag == "rule10b5-1checked" || lowerTag == "rule10b51checked" || lowerTag == "affirmativedefenseconditions" {
            let v = currentValue.lowercased()
            if v == "1" || v == "true" || v == "y" {
                if inNonDerivativeTransaction {
                    txIsRule10b51 = true
                } else {
                    docIsRule10b51 = true
                }
            }
        }

        if inReportingOwner {
            switch elementName {
            case "rptOwnerName":
                ownerName = currentValue
            case "officerTitle":
                officerTitle = currentValue
            case "isDirector":
                isDirector = currentValue == "1" || currentValue.lowercased() == "true"
            case "isOfficer":
                isOfficer = currentValue == "1" || currentValue.lowercased() == "true"
            case "isTenPercentOwner":
                isTenPercentOwner = currentValue == "1" || currentValue.lowercased() == "true"
            case "reportingOwner":
                inReportingOwner = false
            default:
                break
            }
        }

        if inNonDerivativeTransaction {
            switch elementName {
            case "transactionDate":
                // Handles direct date or inner <value>
                if txDateString.isEmpty { txDateString = currentValue }
            case "transactionCode":
                txCode = currentValue
            case "transactionShares":
                if txShares == 0 { txShares = Double(currentValue) ?? 0 }
            case "transactionPricePerShare":
                if txPrice == 0 { txPrice = Double(currentValue) ?? 0 }
            case "transactionAcquiredDisposedCode":
                txAcqDisp = currentValue
            case "sharesOwnedFollowingTransaction":
                txPostShares = Double(currentValue) ?? 0
            case "nonDerivativeTransaction":
                inNonDerivativeTransaction = false

                let date = DateFormatter.secDate.date(from: txDateString) ?? Date()
                txIndex += 1
                let uniqueId = "\(filingId)_\(txIndex)"

                let tx = InsiderTransaction(
                    id: uniqueId,
                    symbol: symbol,
                    ownerName: ownerName.isEmpty ? "Insider" : ownerName,
                    officerTitle: officerTitle.isEmpty ? nil : officerTitle,
                    isDirector: isDirector,
                    isOfficer: isOfficer,
                    isTenPercentOwner: isTenPercentOwner,
                    transactionDate: date,
                    filingDate: filingDate,
                    transactionCode: txCode.isEmpty ? "S" : txCode,
                    acquiredDisposed: txAcqDisp.isEmpty ? "D" : txAcqDisp,
                    shares: txShares,
                    price: txPrice,
                    sharesOwnedFollowing: txPostShares,
                    isRule10b51: txIsRule10b51 || docIsRule10b51
                )
                // Discard grants, awards, gifts or transactions with price <= 0
                if tx.shares > 0 && tx.price > 0 {
                    transactionFootnoteIds[parsedTransactions.count] = txFootnoteIds
                    parsedTransactions.append(tx)
                }
            default:
                break
            }
        }
    }

    public func parserDidEndDocument(_ parser: XMLParser) {
        let filingHas10b51Footnote = footnoteMap.values.contains {
            $0.localizedCaseInsensitiveContains("10b5-1") || $0.localizedCaseInsensitiveContains("10b51")
        }

        for i in 0..<parsedTransactions.count {
            if parsedTransactions[i].isRule10b51 { continue }
            let fIds = transactionFootnoteIds[i] ?? []
            var is10b51 = docIsRule10b51
            for fId in fIds {
                if let text = footnoteMap[fId], text.localizedCaseInsensitiveContains("10b5-1") || text.localizedCaseInsensitiveContains("10b51") {
                    is10b51 = true
                    break
                }
            }
            if !is10b51 && filingHas10b51Footnote && parsedTransactions[i].transactionCode == "S" {
                is10b51 = true
            }
            if is10b51 {
                let old = parsedTransactions[i]
                parsedTransactions[i] = InsiderTransaction(
                    id: old.id,
                    symbol: old.symbol,
                    ownerName: old.ownerName,
                    officerTitle: old.officerTitle,
                    isDirector: old.isDirector,
                    isOfficer: old.isOfficer,
                    isTenPercentOwner: old.isTenPercentOwner,
                    transactionDate: old.transactionDate,
                    filingDate: old.filingDate,
                    transactionCode: old.transactionCode,
                    acquiredDisposed: old.acquiredDisposed,
                    shares: old.shares,
                    price: old.price,
                    sharesOwnedFollowing: old.sharesOwnedFollowing,
                    relatedPersonName: old.relatedPersonName,
                    relatedPersonTitle: old.relatedPersonTitle,
                    transactionNote: old.transactionNote,
                    ownershipRatioAfter: old.ownershipRatioAfter,
                    plannedShares: old.plannedShares,
                    isVNDisclosure: old.isVNDisclosure,
                    isRule10b51: true
                )
            }
        }
    }
}

// MARK: - Vietnam Insider Disclosure Parser

public enum VNInsiderParser {
    private struct ResponseRoot: Decodable {
        let Data: Payload?
    }

    private struct Payload: Decodable {
        let TotalCount: Int?
        let Data: [RawItem]?
    }

    private struct RawItem: Decodable {
        let Stock: String?
        let TransactionMan: String?
        let TransactionManPosition: String?
        let RelatedMan: String?
        let RelatedManPosition: String?
        let VolumeBeforeTransaction: Double?
        let PlanBuyVolume: Double?
        let PlanSellVolume: Double?
        let PlanBeginDate: String?
        let PlanEndDate: String?
        let RealBuyVolume: Double?
        let RealSellVolume: Double?
        let RealEndDate: String?
        let PublishedDate: String?
        let VolumeAfterTransaction: Double?
        let TransactionNote: String?
        let TyLeSoHuu: Double?
        let ShareHolderCode: String?
        let OrderDate: String?
    }

    private static let shortDayMonthFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "dd/MM"
        df.timeZone = TimeZone(secondsFromGMT: 7 * 3600)
        return df
    }()

    /// Parses ASP.NET AJAX `/Date(1775667600000)/` strings into `Date`.
    public static func parseDotNetDate(_ raw: String?) -> Date? {
        guard let raw = raw,
              let openIdx = raw.firstIndex(of: "("),
              let closeIdx = raw.firstIndex(of: ")"),
              openIdx < closeIdx else {
            return nil
        }
        let inner = raw[raw.index(after: openIdx)..<closeIdx]
        var numSlice = inner
        if let plusIdx = inner.firstIndex(of: "+") {
            numSlice = inner[..<plusIdx]
        } else if let minusIdx = inner.dropFirst().firstIndex(of: "-") {
            numSlice = inner[..<minusIdx]
        }
        guard let ms = Double(numSlice), ms > 0 else { return nil }
        return Date(timeIntervalSince1970: ms / 1000.0)
    }

    private static func formatCompactShares(_ shares: Double) -> String {
        if shares >= 1_000_000 {
            let m = shares / 1_000_000
            return m.truncatingRemainder(dividingBy: 1) == 0
                ? String(format: "%.0fM", m)
                : String(format: "%.2fM", m)
        } else if shares >= 1_000 {
            let k = shares / 1_000
            return k.truncatingRemainder(dividingBy: 1) == 0
                ? String(format: "%.0fK", k)
                : String(format: "%.1fK", k)
        }
        return String(format: "%.0f", shares)
    }

    /// Parses Vietnam shareholder & insider transaction disclosures into `[InsiderTransaction]`.
    public static func parse(
        data: Data,
        symbol: String,
        now: Date = Date(),
        lookbackMonths: Int = 60
    ) -> [InsiderTransaction] {
        guard let root = try? JSONDecoder().decode(ResponseRoot.self, from: data),
              let items = root.Data?.Data else {
            return []
        }

        let cleanSym = symbol.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let cal = Calendar.current
        let cutoff = cal.date(byAdding: .month, value: -lookbackMonths, to: now) ?? Date.distantPast
        let pendingExpiryCutoff = cal.date(byAdding: .day, value: -7, to: now) ?? now
        let pendingStartCutoff = cal.date(byAdding: .day, value: -45, to: now) ?? now

        var result: [InsiderTransaction] = []
        var seenKeys = Set<String>()

        for (idx, item) in items.enumerated() {
            let owner = (item.TransactionMan ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !owner.isEmpty else { continue }

            let realBuy = item.RealBuyVolume ?? 0
            let realSell = item.RealSellVolume ?? 0
            let planBuy = item.PlanBuyVolume ?? 0
            let planSell = item.PlanSellVolume ?? 0

            let realEnd = parseDotNetDate(item.RealEndDate)
            let planBegin = parseDotNetDate(item.PlanBeginDate)
            let planEnd = parseDotNetDate(item.PlanEndDate)
            let orderDate = parseDotNetDate(item.OrderDate)
            let pubDate = parseDotNetDate(item.PublishedDate)

            let rawNote = (item.TransactionNote ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let isESOP = rawNote.localizedCaseInsensitiveContains("ESOP")

            let isExecuted = realBuy > 0 || realSell > 0
            let isBuy: Bool
            let shares: Double
            let plannedShares: Double?
            let txDate: Date
            let txCode: String
            let noteText: String?

            if isExecuted {
                isBuy = realBuy >= realSell
                shares = isBuy ? realBuy : realSell
                let planned = isBuy ? planBuy : planSell
                plannedShares = planned > 0 ? planned : nil
                txDate = realEnd ?? orderDate ?? planEnd ?? planBegin ?? pubDate ?? now
                guard txDate >= cutoff else { continue }

                txCode = isESOP ? "ESOP" : (isBuy ? "P" : "S")

                if !rawNote.isEmpty {
                    noteText = rawNote
                } else if planned > 0 && abs(planned - shares) >= 1 {
                    let pct = Int(round((shares / planned) * 100))
                    noteText = "Đạt \(pct)% ĐK"
                } else {
                    noteText = nil
                }
            } else if planBuy > 0 || planSell > 0 {
                // If RealEndDate is already present with 0 executed volume, the registration failed/expired with 0 trades
                if realEnd != nil { continue }
                if let pe = planEnd, pe < pendingExpiryCutoff { continue }
                let candidateDate = planBegin ?? orderDate ?? pubDate ?? now
                if planEnd == nil && candidateDate < pendingStartCutoff { continue }
                guard candidateDate >= cutoff else { continue }

                isBuy = planBuy >= planSell
                shares = isBuy ? planBuy : planSell
                plannedShares = shares
                txDate = candidateDate
                txCode = isESOP ? "ESOP" : "PLAN"

                var parts: [String] = []
                if let pb = planBegin, let pe = planEnd {
                    parts.append("ĐK: \(shortDayMonthFormatter.string(from: pb)) - \(shortDayMonthFormatter.string(from: pe))")
                }
                if !rawNote.isEmpty {
                    parts.append(rawNote)
                }
                noteText = parts.isEmpty ? nil : parts.joined(separator: " • ")
            } else {
                continue
            }

            guard shares > 0 else { continue }

            let volBefore = item.VolumeBeforeTransaction ?? 0
            let volAfter = item.VolumeAfterTransaction ?? 0
            let postShares: Double
            if isExecuted {
                postShares = volAfter > 0 ? volAfter : (volBefore > 0 ? max(0, volBefore + (isBuy ? shares : -shares)) : 0)
            } else {
                postShares = volBefore > 0 ? volBefore : volAfter
            }

            let title = (item.TransactionManPosition ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let relName = (item.RelatedMan ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let relTitle = (item.RelatedManPosition ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let holderCode = (item.ShareHolderCode ?? owner).trimmingCharacters(in: .whitespacesAndNewlines)
            let dayBucket = Int(txDate.timeIntervalSince1970 / 86400)
            let dedupKey = "\(holderCode)_\(txCode)_\(isBuy)_\(Int(shares))_\(dayBucket)"
            guard seenKeys.insert(dedupKey).inserted else { continue }

            let ratio = (item.TyLeSoHuu ?? 0) > 0 ? item.TyLeSoHuu : nil

            let tx = InsiderTransaction(
                id: "VN_\(cleanSym)_\(dedupKey)_\(idx)",
                symbol: cleanSym,
                ownerName: owner,
                officerTitle: title.isEmpty ? nil : title,
                isDirector: title.localizedCaseInsensitiveContains("HĐQT"),
                isOfficer: title.localizedCaseInsensitiveContains("GĐ") || title.localizedCaseInsensitiveContains("Giám đốc") || title.localizedCaseInsensitiveContains("Kế toán"),
                isTenPercentOwner: (ratio ?? 0) >= 5.0,
                transactionDate: txDate,
                filingDate: pubDate,
                transactionCode: txCode,
                acquiredDisposed: isBuy ? "A" : "D",
                shares: shares,
                price: 0,
                sharesOwnedFollowing: postShares,
                relatedPersonName: relName.isEmpty ? nil : relName,
                relatedPersonTitle: relTitle.isEmpty ? nil : relTitle,
                transactionNote: noteText,
                ownershipRatioAfter: ratio,
                plannedShares: plannedShares,
                isVNDisclosure: true
            )
            result.append(tx)
        }

        result.sort { $0.transactionDate > $1.transactionDate }
        return result
    }
}

// MARK: - Date Formatter Extension

extension DateFormatter {
    static let secDate: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.timeZone = TimeZone(secondsFromGMT: 0)
        return df
    }()
}
