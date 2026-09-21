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
    private let requestGate = AsyncSemaphore(count: 3)

    /// In-memory cache timestamps
    private var lastFetchDates: [String: Date] = [:]
    /// TTL for cache: 12 hours (Form 4 filings are typically once or twice a week per company)
    private let cacheTTL: TimeInterval = 12 * 3600

    private let session: URLSession

    private var cacheDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = appSupport.appendingPathComponent("StockDeck/InsiderCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
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
    public func ensureTransactions(for symbol: String) async {
        let clean = cleanSymbol(symbol)
        guard isEligibleUSSymbol(clean) else { return }

        // Return if fresh cache exists
        if let lastFetch = lastFetchDates[clean], Date().timeIntervalSince(lastFetch) < cacheTTL,
           transactions[clean] != nil {
            return
        }

        // Try reading disk cache first
        if loadDiskCache(for: clean) {
            return
        }

        // Single-flight deduplication
        if let existing = inFlightTasks[clean] {
            await existing.value
            return
        }

        let task = Task { [weak self] () -> Void in
            guard let self = self else { return }
            await self.fetchFromSec(symbol: clean)
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

    // MARK: - Symbol Eligibility

    public func isEligibleUSSymbol(_ symbol: String) -> Bool {
        let upper = symbol.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
        // Exclude Vietnamese, Tokyo, London, Hong Kong, crypto and indices
        if upper.contains(".VN") || upper.contains(".HM") || upper.contains(".HN") ||
           upper.contains(".T") || upper.contains(".L") || upper.contains(".HK") ||
           upper.hasSuffix("-USD") || upper.hasSuffix("USDT") || upper.hasPrefix("^") {
            return false
        }
        return !upper.isEmpty
    }

    private func cleanSymbol(_ symbol: String) -> String {
        symbol.uppercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ".US", with: "")
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

        guard let cik10 = tickerToCik[symbol] else {
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
                let twoYearsAgo = Calendar.current.date(byAdding: .year, value: -2, to: Date()) ?? Date.distantPast
                for i in 0..<min(forms.count, accessions.count, primaryDocs.count, filingDates.count) {
                    guard forms[i] == "4" else { continue }
                    let acc = accessions[i]
                    let dateStr = filingDates[i]
                    if let filingDate = DateFormatter.secDate.date(from: dateStr), filingDate < twoYearsAgo {
                        break
                    }
                    if !knownAccessions.contains(acc) {
                        list.append((accession: acc, doc: primaryDocs[i], filingDate: dateStr))
                        if list.count >= 30 { break }
                    }
                }
                return list
            }.value

            let cikIntString = String(Int(cik10) ?? 0)

            // If no new filings need downloading, our existing cache is fully up to date!
            if targetFilings.isEmpty {
                self.sentiment[symbol] = computeSentiment(symbol: symbol, transactions: existing)
                self.lastFetchDates[symbol] = Date()
                return
            }

            // Fetch and parse only the new Form 4 XML files concurrently
            var newTransactions: [InsiderTransaction] = []

            await withTaskGroup(of: [InsiderTransaction].self) { group in
                for filing in targetFilings {
                    group.addTask { [weak self] in
                        guard let self = self else { return [] }
                        let accessionNoHyphen = filing.accession.replacingOccurrences(of: "-", with: "")
                        let docName = filing.doc.components(separatedBy: "/").last ?? "form4.xml"
                        let xmlURLString = "https://www.sec.gov/Archives/edgar/data/\(cikIntString)/\(accessionNoHyphen)/\(docName)"

                        guard let xmlURL = URL(string: xmlURLString) else { return [] }

                        do {
                            await self.requestGate.wait()
                            defer { self.requestGate.signal() }
                            let (xmlData, xmlResp) = try await self.session.data(from: xmlURL)
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

                for await list in group {
                    newTransactions.append(contentsOf: list)
                }
            }

            // Merge new filings with existing historical database
            var combined = newTransactions + existing
            combined.sort { $0.transactionDate > $1.transactionDate }

            // Deduplicate by unique transaction ID and keep only positive price trades
            var seen = Set<String>()
            let uniqueTxs = combined.filter { $0.price > 0 && $0.shares > 0 && seen.insert($0.id).inserted }

            self.transactions[symbol] = uniqueTxs
            self.sentiment[symbol] = computeSentiment(symbol: symbol, transactions: uniqueTxs)
            self.lastFetchDates[symbol] = Date()
            self.errorSymbols.removeValue(forKey: symbol)

            saveDiskCache(for: symbol, txs: uniqueTxs)
        } catch {
            self.errorSymbols[symbol] = error.localizedDescription
        }
    }

    // MARK: - Sentiment Calculation

    public func computeSentiment(symbol: String, transactions: [InsiderTransaction], lookbackMonths: Int = 24) -> InsiderSentimentSummary {
        let calendar = Calendar.current
        let cutoff = calendar.date(byAdding: .month, value: -lookbackMonths, to: Date()) ?? Date.distantPast

        let recent = transactions.filter { $0.transactionDate >= cutoff }

        var buyShares = 0.0
        var sellShares = 0.0
        var buyValue = 0.0
        var sellValue = 0.0
        var buyCount = 0
        var sellCount = 0
        var openMarketBuyCount = 0
        var openMarketSellCount = 0

        for tx in recent {
            if tx.isBuy {
                buyShares += tx.shares
                buyValue += tx.totalValue
                buyCount += 1
                if tx.isOpenMarket { openMarketBuyCount += 1 }
            } else {
                sellShares += tx.shares
                sellValue += tx.totalValue
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

    /// Periodically syncs Form 4 filings for all US symbols in user portfolios and watchlists.
    /// Runs as a polite, throttled background queue.
    func syncAllUserSymbols(storageService: StorageService) async {
        var symbols = Set<String>()
        for p in storageService.portfolios {
            for h in p.holdings {
                let clean = cleanSymbol(h.symbol)
                if isEligibleUSSymbol(clean) { symbols.insert(clean) }
            }
        }
        for w in storageService.watchlists {
            for s in w.symbols {
                let clean = cleanSymbol(s)
                if isEligibleUSSymbol(clean) { symbols.insert(clean) }
            }
        }

        guard !symbols.isEmpty else { return }

        for sym in symbols {
            await ensureTransactions(for: sym)
            // Polite pause between symbols to maintain SEC compliance and zero UI impact
            try? await Task.sleep(nanoseconds: 350_000_000)
        }
    }

    // MARK: - Disk Caching

    private func cacheFilePath(for symbol: String) -> URL {
        cacheDirectory.appendingPathComponent("\(symbol)_insider.json")
    }

    private func saveDiskCache(for symbol: String, txs: [InsiderTransaction]) {
        let path = cacheFilePath(for: symbol)
        Task.detached(priority: .background) {
            guard let data = try? JSONEncoder().encode(txs) else { return }
            try? data.write(to: path, options: .atomic)
        }
    }

    private func loadDiskCache(for symbol: String) -> Bool {
        let path = cacheFilePath(for: symbol)
        guard FileManager.default.fileExists(atPath: path.path),
              let attrs = try? FileManager.default.attributesOfItem(atPath: path.path),
              let modDate = attrs[.modificationDate] as? Date,
              Date().timeIntervalSince(modDate) < cacheTTL,
              let data = try? Data(contentsOf: path),
              let decoded = try? JSONDecoder().decode([InsiderTransaction].self, from: data) else {
            return false
        }
        let validTxs = decoded.filter { $0.price > 0 && $0.shares > 0 }
        self.transactions[symbol] = validTxs
        self.sentiment[symbol] = computeSentiment(symbol: symbol, transactions: validTxs)
        self.lastFetchDates[symbol] = modDate
        return true
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
        }
    }

    public func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentValue += string.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
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
                    sharesOwnedFollowing: txPostShares
                )
                // Discard grants, awards, gifts or transactions with price <= 0
                if tx.shares > 0 && tx.price > 0 {
                    parsedTransactions.append(tx)
                }
            default:
                break
            }
        }
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
