import Foundation
import AppKit

enum AutoExportFrequency: String, CaseIterable, Codable, Sendable {
    case biweekly = "biweekly"
    case monthly = "monthly"

    var displayName: String {
        switch self {
        case .biweekly: return "1st & 15th of month (Bi-weekly)"
        case .monthly: return "1st of month (Monthly)"
        }
    }
}

struct ExportedHolding: Codable, Sendable, Equatable {
    let id: String
    let symbol: String
    let assetType: String
    let exchange: String
    let currency: String
    let quantity: Double
    let avgPrice: Double
    let currentPrice: Double?
    let marketValue: Double?
    let costBasis: Double?
    let costBasisMissing: Bool
    let unrealizedPnl: Double?
    let unrealizedPnlPercent: Double?
    let purchaseDate: String?
    let account: String
    let leverage: Double?

    init(
        id: String,
        symbol: String,
        assetType: String,
        exchange: String,
        currency: String,
        quantity: Double,
        avgPrice: Double,
        currentPrice: Double?,
        marketValue: Double?,
        costBasis: Double?,
        costBasisMissing: Bool,
        unrealizedPnl: Double?,
        unrealizedPnlPercent: Double?,
        purchaseDate: String?,
        account: String,
        leverage: Double?
    ) {
        self.id = id
        self.symbol = symbol
        self.assetType = assetType
        self.exchange = exchange
        self.currency = currency
        self.quantity = quantity
        self.avgPrice = avgPrice
        self.currentPrice = currentPrice
        self.marketValue = marketValue
        self.costBasis = costBasis
        self.costBasisMissing = costBasisMissing
        self.unrealizedPnl = unrealizedPnl
        self.unrealizedPnlPercent = unrealizedPnlPercent
        self.purchaseDate = purchaseDate
        self.account = account
        self.leverage = leverage
    }
}

struct ExportedClosedTrade: Codable, Sendable, Equatable {
    let id: String
    let symbol: String
    let assetType: String
    let exchange: String
    let currency: String
    let quantity: Double
    let buyPrice: Double
    let sellPrice: Double
    let costBasis: Double
    let proceeds: Double
    let realizedPnl: Double
    let realizedPnlPercent: Double
    let buyDate: String?
    let sellDate: String?
    let account: String
    let leverage: Double?

    init(
        id: String,
        symbol: String,
        assetType: String,
        exchange: String,
        currency: String,
        quantity: Double,
        buyPrice: Double,
        sellPrice: Double,
        costBasis: Double,
        proceeds: Double,
        realizedPnl: Double,
        realizedPnlPercent: Double,
        buyDate: String?,
        sellDate: String?,
        account: String,
        leverage: Double?
    ) {
        self.id = id
        self.symbol = symbol
        self.assetType = assetType
        self.exchange = exchange
        self.currency = currency
        self.quantity = quantity
        self.buyPrice = buyPrice
        self.sellPrice = sellPrice
        self.costBasis = costBasis
        self.proceeds = proceeds
        self.realizedPnl = realizedPnl
        self.realizedPnlPercent = realizedPnlPercent
        self.buyDate = buyDate
        self.sellDate = sellDate
        self.account = account
        self.leverage = leverage
    }
}

struct ExportedTransaction: Codable, Sendable, Equatable {
    let id: String
    let date: String
    let symbol: String
    let assetType: String
    let exchange: String
    let type: String
    let quantity: Double
    let price: Double
    let amount: Double
    let currency: String
    let account: String
    let notes: String?

    init(
        id: String,
        date: String,
        symbol: String,
        assetType: String,
        exchange: String,
        type: String,
        quantity: Double,
        price: Double,
        amount: Double,
        currency: String,
        account: String,
        notes: String?
    ) {
        self.id = id
        self.date = date
        self.symbol = symbol
        self.assetType = assetType
        self.exchange = exchange
        self.type = type
        self.quantity = quantity
        self.price = price
        self.amount = amount
        self.currency = currency
        self.account = account
        self.notes = notes
    }
}

struct ExportedPortfolio: Codable, Sendable, Equatable {
    let id: String
    let name: String
    let totalValuePreferred: Double
    let totalCostPreferred: Double
    let totalUnrealizedPnlPreferred: Double
    let totalUnrealizedPnlPercent: Double?
    let totalRealizedPnlPreferred: Double
    let hasIncompleteCostBasis: Bool
    let holdings: [ExportedHolding]
    let closedTrades: [ExportedClosedTrade]
    let transactions: [ExportedTransaction]

    init(
        id: String,
        name: String,
        totalValuePreferred: Double,
        totalCostPreferred: Double,
        totalUnrealizedPnlPreferred: Double,
        totalUnrealizedPnlPercent: Double?,
        totalRealizedPnlPreferred: Double,
        hasIncompleteCostBasis: Bool,
        holdings: [ExportedHolding],
        closedTrades: [ExportedClosedTrade],
        transactions: [ExportedTransaction]
    ) {
        self.id = id
        self.name = name
        self.totalValuePreferred = totalValuePreferred
        self.totalCostPreferred = totalCostPreferred
        self.totalUnrealizedPnlPreferred = totalUnrealizedPnlPreferred
        self.totalUnrealizedPnlPercent = totalUnrealizedPnlPercent
        self.totalRealizedPnlPreferred = totalRealizedPnlPreferred
        self.hasIncompleteCostBasis = hasIncompleteCostBasis
        self.holdings = holdings
        self.closedTrades = closedTrades
        self.transactions = transactions
    }
}

struct PortfolioExportSummary: Codable, Sendable, Equatable {
    let totalPortfolioCount: Int
    let preferredCurrency: String
    let totalValue: Double
    let totalCost: Double
    let totalUnrealizedPnl: Double
    let totalUnrealizedPnlPercent: Double?
    let totalRealizedPnl: Double
    let hasIncompleteCostBasis: Bool

    init(
        totalPortfolioCount: Int,
        preferredCurrency: String,
        totalValue: Double,
        totalCost: Double,
        totalUnrealizedPnl: Double,
        totalUnrealizedPnlPercent: Double?,
        totalRealizedPnl: Double,
        hasIncompleteCostBasis: Bool
    ) {
        self.totalPortfolioCount = totalPortfolioCount
        self.preferredCurrency = preferredCurrency
        self.totalValue = totalValue
        self.totalCost = totalCost
        self.totalUnrealizedPnl = totalUnrealizedPnl
        self.totalUnrealizedPnlPercent = totalUnrealizedPnlPercent
        self.totalRealizedPnl = totalRealizedPnl
        self.hasIncompleteCostBasis = hasIncompleteCostBasis
    }
}

struct PortfolioExportPayload: Codable, Sendable, Equatable {
    let schemaVersion: Int
    let appVersion: String
    let exportedAt: String
    let preferredCurrency: String
    let summary: PortfolioExportSummary
    let portfolios: [ExportedPortfolio]

    init(
        schemaVersion: Int = 1,
        appVersion: String,
        exportedAt: String,
        preferredCurrency: String,
        summary: PortfolioExportSummary,
        portfolios: [ExportedPortfolio]
    ) {
        self.schemaVersion = schemaVersion
        self.appVersion = appVersion
        self.exportedAt = exportedAt
        self.preferredCurrency = preferredCurrency
        self.summary = summary
        self.portfolios = portfolios
    }
}

@MainActor
final class AutoExportService: ObservableObject {
    static let shared = AutoExportService()

    @Published var isExporting: Bool = false
    @Published var exportStatus: String = "Ready"

    private var isStarted = false
    private var periodicTimer: Timer?

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private init() {}

    func start() {
        guard !isStarted else { return }
        isStarted = true

        // Initial check on launch after waiting briefly for services
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            self.checkAndRunScheduledExport()
        }

        // Periodic check every 1 hour while app remains open
        periodicTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkAndRunScheduledExport()
            }
        }
    }

    /// Determines the base destination folder on iCloud Drive or local fallback.
    static var baseDirectoryURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let cloudDocs = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        if FileManager.default.fileExists(atPath: cloudDocs.path) {
            let folder = cloudDocs.appendingPathComponent(AppEnvironment.iCloudFolderName, isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return folder
        }
        let localFolder = home.appendingPathComponent("Documents/StockDeck", isDirectory: true)
        try? FileManager.default.createDirectory(at: localFolder, withIntermediateDirectories: true)
        return localFolder
    }

    /// Fixed location read by Muse and external automated tools.
    static var latestExportFileURL: URL {
        baseDirectoryURL.appendingPathComponent("portfolio_export_latest.json")
    }

    /// Archive folder storing timestamped snapshots for historical tracking.
    static var archiveDirectoryURL: URL {
        let dir = baseDirectoryURL.appendingPathComponent("Exports", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Computes the current calendar period key (e.g., "2026-10-15" or "2026-10-01") for catch-up and deduplication.
    static func periodKey(for date: Date = Date(), frequency: AutoExportFrequency) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let comps = calendar.dateComponents([.year, .month, .day], from: date)
        let y = comps.year ?? 2026
        let m = comps.month ?? 1
        let d = comps.day ?? 1

        switch frequency {
        case .biweekly:
            let dayPart = (d >= 15) ? 15 : 1
            return String(format: "%04d-%02d-%02d", y, m, dayPart)
        case .monthly:
            return String(format: "%04d-%02d-01", y, m)
        }
    }

    /// Checks if a scheduled export is due based on the current period key and triggers it if needed.
    func checkAndRunScheduledExport(force: Bool = false) {
        let storage = StorageService.shared
        guard storage.autoExportEnabled || force else { return }

        let currentKey = Self.periodKey(frequency: storage.autoExportFrequency)
        if !force && storage.lastAutoExportPeriodKey == currentKey {
            // Already exported for this period
            return
        }

        performExport(periodKey: currentKey)
    }

    /// Triggers an immediate export regardless of schedule.
    func exportNow() {
        let storage = StorageService.shared
        let currentKey = Self.periodKey(frequency: storage.autoExportFrequency)
        performExport(periodKey: currentKey)
    }

    /// Opens Finder revealing the exported file.
    func showInFinder() {
        let latestFile = Self.latestExportFileURL
        if FileManager.default.fileExists(atPath: latestFile.path) {
            NSWorkspace.shared.activateFileViewerSelecting([latestFile])
        } else {
            NSWorkspace.shared.open(Self.baseDirectoryURL)
        }
    }

    /// Compiles and writes the export payload to disk.
    func performExport(periodKey: String) {
        guard !isExporting else { return }
        isExporting = true
        exportStatus = "Exporting…"

        let storage = StorageService.shared
        let stockSvc = StockService.shared
        let payload = Self.buildExportPayload(storageService: storage, stockService: stockSvc)

        let latestURL = Self.latestExportFileURL
        let archiveDir = Self.archiveDirectoryURL
        let archiveURL = archiveDir.appendingPathComponent("portfolio_export_\(periodKey).json")

        Task {
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(payload)

                try await Task.detached(priority: .utility) {
                    try data.write(to: latestURL, options: .atomic)
                    try data.write(to: archiveURL, options: .atomic)
                }.value

                await MainActor.run {
                    storage.lastAutoExportDate = Date()
                    storage.lastAutoExportPeriodKey = periodKey
                    self.exportStatus = "Exported (\(periodKey))"
                    self.isExporting = false
                }
            } catch {
                await MainActor.run {
                    self.exportStatus = "Failed: \(error.localizedDescription)"
                    self.isExporting = false
                }
            }
        }
    }

    static func round2Opt(_ val: Double?) -> Double? {
        guard let val = val, val.isFinite else { return nil }
        return (val * 100.0).rounded() / 100.0
    }

    static func round2(_ val: Double) -> Double {
        guard val.isFinite else { return 0.0 }
        return (val * 100.0).rounded() / 100.0
    }

    static func normalizeAccount(_ raw: String?) -> String {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty, trimmed != "-" else {
            return ""
        }
        return trimmed
    }

    static func resolveAssetType(symbol: String, storageService: StorageService) -> String {
        let clean = symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if let stored = storageService.symbolType[clean] ?? storageService.symbolType[symbol], !stored.isEmpty {
            return stored
        }
        if StockService.isJapaneseMutualFund(clean) {
            return "MUTUAL_FUND"
        }
        if StorageService.isStandardCryptoSymbol(clean) {
            return "CRYPTOCURRENCY"
        }
        if clean.hasPrefix("^") {
            return "INDEX"
        }
        return "EQUITY"
    }

    static func resolveExchange(symbol: String, storageService: StorageService) -> String {
        let clean = symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if let stored = storageService.symbolExchange[clean] ?? storageService.symbolExchange[symbol], !stored.isEmpty {
            return stored
        }
        if StockService.isJapaneseMutualFund(clean) {
            return "TSE"
        }
        if clean.hasSuffix(".VN") {
            return "HOSE"
        }
        if clean.hasSuffix(".T") {
            return "TSE"
        }
        if StorageService.isStandardCryptoSymbol(clean) {
            return "BINANCE"
        }
        return "US"
    }

    /// Pure function converting current storage & quote state into the standardized export payload.
    static func buildExportPayload(
        storageService: StorageService,
        stockService: StockService,
        date: Date = Date()
    ) -> PortfolioExportPayload {
        let preferredCurrency = storageService.preferredCurrency.isEmpty ? "USD" : storageService.preferredCurrency
        var exportedPortfolios: [ExportedPortfolio] = []

        var grandTotalValue: Double = 0.0
        var grandTotalCost: Double = 0.0
        var grandTotalRealizedPnl: Double = 0.0
        var grandHasIncompleteCostBasis: Bool = false

        for portfolio in storageService.portfolios {
            var pHoldings: [ExportedHolding] = []
            var pTotalValPref: Double = 0.0
            var pTotalCostPref: Double = 0.0
            var pTotalRealizedPnlPref: Double = 0.0
            var portfolioHasIncompleteCostBasis: Bool = false

            // Process Holdings
            for holding in portfolio.holdings {
                let sym = holding.symbol
                let cleanSym = sym.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                let holdingCurrency = StockService.detectedCurrency(for: cleanSym)
                let quote = stockService.quotes[cleanSym] ?? stockService.quotes[sym]

                let assetType = resolveAssetType(symbol: cleanSym, storageService: storageService)
                let exchange = resolveExchange(symbol: cleanSym, storageService: storageService)

                let currentPrice: Double? = {
                    if let qp = quote?.price, qp.isFinite, qp > 0 {
                        return qp
                    }
                    if holding.avgPrice.isFinite && holding.avgPrice > 0 {
                        return holding.avgPrice
                    }
                    return nil
                }()

                let costBasisMissing = !holding.hasKnownCostBasis
                if costBasisMissing {
                    portfolioHasIncompleteCostBasis = true
                }

                let marketValLocal: Double? = currentPrice.map { holding.marketValue(currentPrice: $0) }
                let costBasisLocal: Double? = costBasisMissing ? nil : holding.costBasisLocal

                let pnlLocal: Double? = costBasisMissing ? nil : currentPrice.map { holding.pnl(currentPrice: $0) }
                let pnlPct: Double? = costBasisMissing ? nil : currentPrice.map { holding.pnlPercent(currentPrice: $0) }

                let rate = stockService.rate(from: holdingCurrency, to: preferredCurrency)
                if let mv = marketValLocal {
                    pTotalValPref += mv * rate
                }
                if let cb = costBasisLocal {
                    pTotalCostPref += cb * rate
                }

                let purchaseDateStr: String? = holding.purchaseDate.map { isoFormatter.string(from: $0) }

                let expH = ExportedHolding(
                    id: holding.id.uuidString,
                    symbol: cleanSym,
                    assetType: assetType,
                    exchange: exchange,
                    currency: holdingCurrency,
                    quantity: holding.quantity,
                    avgPrice: round2(holding.avgPrice.isFinite ? holding.avgPrice : 0),
                    currentPrice: round2Opt(currentPrice),
                    marketValue: round2Opt(marketValLocal),
                    costBasis: round2Opt(costBasisLocal),
                    costBasisMissing: costBasisMissing,
                    unrealizedPnl: round2Opt(pnlLocal),
                    unrealizedPnlPercent: round2Opt(pnlPct),
                    purchaseDate: purchaseDateStr,
                    account: normalizeAccount(holding.account),
                    leverage: holding.leverage
                )
                pHoldings.append(expH)
            }

            // Process Closed Trades
            var pClosedTrades: [ExportedClosedTrade] = []
            for ct in portfolio.closedTrades {
                let cleanSym = ct.symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                let assetType = resolveAssetType(symbol: cleanSym, storageService: storageService)
                let exchange = resolveExchange(symbol: cleanSym, storageService: storageService)
                let ctCurrency = StockService.detectedCurrency(for: cleanSym)

                let rate = stockService.rate(from: ctCurrency, to: preferredCurrency)
                pTotalRealizedPnlPref += ct.realizedPnl * rate

                let buyDateStr: String? = ct.buyDate.map { isoFormatter.string(from: $0) }
                let sellDateStr: String? = ct.sellDate.map { isoFormatter.string(from: $0) }

                let expCT = ExportedClosedTrade(
                    id: ct.id.uuidString,
                    symbol: cleanSym,
                    assetType: assetType,
                    exchange: exchange,
                    currency: ctCurrency,
                    quantity: ct.quantity,
                    buyPrice: round2(ct.buyPrice),
                    sellPrice: round2(ct.sellPrice),
                    costBasis: round2(ct.costBasis),
                    proceeds: round2(ct.proceeds),
                    realizedPnl: round2(ct.realizedPnl),
                    realizedPnlPercent: round2(ct.realizedPnlPercent),
                    buyDate: buyDateStr,
                    sellDate: sellDateStr,
                    account: normalizeAccount(ct.account),
                    leverage: ct.leverage
                )
                pClosedTrades.append(expCT)
            }

            // Process Transactions
            var pTransactions: [ExportedTransaction] = []
            for tx in portfolio.transactions {
                let cleanSym = tx.symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                let assetType = resolveAssetType(symbol: cleanSym, storageService: storageService)
                let exchange = resolveExchange(symbol: cleanSym, storageService: storageService)

                let txDateStr = isoFormatter.string(from: tx.date)
                let expTx = ExportedTransaction(
                    id: tx.id.uuidString,
                    date: txDateStr,
                    symbol: cleanSym,
                    assetType: assetType,
                    exchange: exchange,
                    type: tx.type.rawValue,
                    quantity: tx.quantity,
                    price: round2(tx.price),
                    amount: round2(tx.effectiveAmount),
                    currency: tx.effectiveCurrency,
                    account: normalizeAccount(tx.account),
                    notes: tx.notes
                )
                pTransactions.append(expTx)
            }

            let pTotalUnrealizedPnlPref = pTotalValPref - pTotalCostPref
            let pTotalUnrealizedPnlPct: Double? = {
                guard pTotalCostPref > 0, !portfolioHasIncompleteCostBasis else { return nil }
                return round2((pTotalUnrealizedPnlPref / pTotalCostPref) * 100)
            }()

            grandTotalValue += pTotalValPref
            grandTotalCost += pTotalCostPref
            grandTotalRealizedPnl += pTotalRealizedPnlPref
            if portfolioHasIncompleteCostBasis {
                grandHasIncompleteCostBasis = true
            }

            let expP = ExportedPortfolio(
                id: portfolio.id.uuidString,
                name: portfolio.name,
                totalValuePreferred: round2(pTotalValPref),
                totalCostPreferred: round2(pTotalCostPref),
                totalUnrealizedPnlPreferred: round2(pTotalUnrealizedPnlPref),
                totalUnrealizedPnlPercent: pTotalUnrealizedPnlPct,
                totalRealizedPnlPreferred: round2(pTotalRealizedPnlPref),
                hasIncompleteCostBasis: portfolioHasIncompleteCostBasis,
                holdings: pHoldings,
                closedTrades: pClosedTrades,
                transactions: pTransactions
            )
            exportedPortfolios.append(expP)
        }

        let grandUnrealizedPnl = grandTotalValue - grandTotalCost
        let grandUnrealizedPnlPct: Double? = {
            guard grandTotalCost > 0, !grandHasIncompleteCostBasis else { return nil }
            return round2((grandUnrealizedPnl / grandTotalCost) * 100)
        }()

        let summary = PortfolioExportSummary(
            totalPortfolioCount: exportedPortfolios.count,
            preferredCurrency: preferredCurrency,
            totalValue: round2(grandTotalValue),
            totalCost: round2(grandTotalCost),
            totalUnrealizedPnl: round2(grandUnrealizedPnl),
            totalUnrealizedPnlPercent: grandUnrealizedPnlPct,
            totalRealizedPnl: round2(grandTotalRealizedPnl),
            hasIncompleteCostBasis: grandHasIncompleteCostBasis
        )

        let appVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.1.19"
        let dateStr = isoFormatter.string(from: date)

        return PortfolioExportPayload(
            schemaVersion: 1,
            appVersion: appVersion,
            exportedAt: dateStr,
            preferredCurrency: preferredCurrency,
            summary: summary,
            portfolios: exportedPortfolios
        )
    }
}
