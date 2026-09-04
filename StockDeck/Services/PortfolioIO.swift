#if os(macOS)
import AppKit
#endif
import Foundation
import UniformTypeIdentifiers

/// Shared NSSavePanel/NSOpenPanel plumbing for portfolio export/import,
/// used by both `PortfolioListView` (menu-bar popover) and `PortfolioWindowView`
/// (full desktop window). The actual JSON encode/decode/merge logic lives in
/// `StorageService`; this only owns the panel configuration and presentation.
@MainActor
enum PortfolioIO {

    #if os(macOS)
    /// Presents an NSSavePanel and writes the exported JSON on confirm.
    ///
    /// - Parameter restoreActivationPolicy: when true, temporarily flips the app
    ///   to `.regular` so the panel can come to the front of a menu-bar
    ///   (accessory) app, then restores `.accessory` shortly after the panel
    ///   closes. Pass false when the caller's window already keeps the app
    ///   `.regular` for its own lifetime (e.g. the desktop portfolio window),
    ///   so this helper doesn't prematurely drop the app back to accessory
    ///   while that window is still open.
    /// Presents an NSSavePanel and writes the exported XLSX on confirm.
    static func exportAll(_ portfolios: [Portfolio], storageService: StorageService, restoreActivationPolicy: Bool) {
        guard let data = SpreadsheetIO.generatePortfoliosXLSXData(portfolios) else { return }
        let panel = NSSavePanel()
        if let xlsxType = UTType(filenameExtension: "xlsx") {
            panel.allowedContentTypes = [xlsxType]
        }
        let name = portfolios.count == 1 ? portfolios[0].name : "StockDeck Portfolios"
        panel.nameFieldStringValue = "\(name).xlsx"
        panel.title = "Export Portfolios (XLSX)"
        if restoreActivationPolicy {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
        panel.begin { response in
            if restoreActivationPolicy {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    NSApp.setActivationPolicy(.accessory)
                }
            }
            guard response == .OK, let url = panel.url else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Presents an NSSavePanel and writes the exported watchlists XLSX on confirm.
    static func exportWatchlists(_ watchlists: [Watchlist], stockService: StockService, restoreActivationPolicy: Bool) {
        guard let data = SpreadsheetIO.generateWatchlistsXLSXData(watchlists: watchlists, stockService: stockService) else { return }
        let panel = NSSavePanel()
        if let xlsxType = UTType(filenameExtension: "xlsx") {
            panel.allowedContentTypes = [xlsxType]
        }
        let name = watchlists.count == 1 ? watchlists[0].name : "StockDeck Watchlists"
        panel.nameFieldStringValue = "\(name).xlsx"
        panel.title = "Export Watchlists (XLSX)"
        if restoreActivationPolicy {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
        panel.begin { response in
            if restoreActivationPolicy {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    NSApp.setActivationPolicy(.accessory)
                }
            }
            guard response == .OK, let url = panel.url else { return }
            try? data.write(to: url, options: .atomic)
        }
    }
    #endif

    struct ImportResult: Identifiable {
        let id = UUID()
        let items: [ParsedImportItem]
        var closedTrades: [ClosedTrade] = []
        var transactions: [Transaction] = []
        let suggestedPortfolioName: String?
        let isFundImport: Bool
    }

    #if os(macOS)
    /// Helper to pick one or more files and parse holdings for preview.
    static func pickAndParseStandard(
        storageService: StorageService? = nil,
        restoreActivationPolicy: Bool,
        onParsed: @escaping (ImportResult) -> Void,
        onAlert: @escaping (String) -> Void
    ) {
        let panel = NSOpenPanel()
        var types: [UTType] = [.json, .commaSeparatedText, .plainText, .data]
        if let xlsxType = UTType(filenameExtension: "xlsx") {
            types.append(xlsxType)
        }
        panel.allowedContentTypes = types
        panel.allowsMultipleSelection = true
        panel.title = "Import Portfolios (CSV, XLSX, JSON)"
        if restoreActivationPolicy {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
        panel.begin { response in
            if restoreActivationPolicy {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    NSApp.setActivationPolicy(.accessory)
                }
            }
            guard response == .OK, !panel.urls.isEmpty else { return }
            Task { @MainActor in
                if let res = parseFiles(urls: panel.urls) {
                    onParsed(res)
                } else {
                    onAlert("Invalid file format or empty portfolio file(s).")
                }
            }
        }
    }

    enum BrokerFileImportStatus {
        case success(ImportResult)
        case allTradesClosed(tradesCount: Int)
        case invalidFile
    }

    /// Helper to pick one or more Japanese broker / fund files for preview.
    static func pickAndParseJapaneseFunds(
        restoreActivationPolicy: Bool,
        onParsed: @escaping (ImportResult) -> Void,
        onAlert: @escaping (String) -> Void
    ) {
        let panel = NSOpenPanel()
        var types: [UTType] = [.commaSeparatedText, .plainText, .data]
        if let xlsxType = UTType(filenameExtension: "xlsx") {
            types.append(xlsxType)
        }
        panel.allowedContentTypes = types
        panel.allowsMultipleSelection = true
        panel.title = "Import 投資信託 / 株式 (Broker Trade History CSV/XLSX)"
        if restoreActivationPolicy {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
        panel.begin { response in
            if restoreActivationPolicy {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    NSApp.setActivationPolicy(.accessory)
                }
            }
            guard response == .OK, !panel.urls.isEmpty else { return }
            Task { @MainActor in
                switch parseBrokerFilesStatus(urls: panel.urls) {
                case .success(let res):
                    onParsed(res)
                case .allTradesClosed(let count):
                    onAlert("All \(count) trades in the file(s) are closed/sold off (0 active positions remaining).")
                case .invalidFile:
                    onAlert("Could not parse broker file(s) or no valid trades found.")
                }
            }
        }
    }
    #endif

    /// Parses broker trade history files with granular status feedback.
    static func parseBrokerFilesStatus(urls: [URL], storageService: StorageService? = nil) -> BrokerFileImportStatus {
        var allBrokerRecords: [SpreadsheetIO.BrokerTradeRecord] = []
        var suggestedNames: [String] = []

        for url in urls {
            if let records = SpreadsheetIO.extractJapaneseBrokerTradeRecords(from: url), !records.isEmpty {
                allBrokerRecords.append(contentsOf: records)
                let name = url.deletingPathExtension().lastPathComponent
                if !suggestedNames.contains(name) {
                    suggestedNames.append(name)
                }
            }
        }

        if !allBrokerRecords.isEmpty {
            let portfolios = SpreadsheetIO.processBrokerTradeRecords(allBrokerRecords)
            if !portfolios.isEmpty {
                var allItems: [ParsedImportItem] = []
                var allClosed: [ClosedTrade] = []
                for p in portfolios {
                    for h in p.holdings {
                        let isFund = StockService.isJapaneseMutualFund(h.symbol)
                        allItems.append(ParsedImportItem(holding: h, isChecked: true, isFund: isFund, originalAccountName: p.name))
                    }
                    allClosed.append(contentsOf: p.closedTrades)
                }
                let suggestedName = suggestedNames.first
                let isFundImport = !allItems.isEmpty && allItems.allSatisfy { $0.isFund }
                return .success(ImportResult(items: allItems, closedTrades: allClosed, suggestedPortfolioName: suggestedName, isFundImport: isFundImport))
            } else {
                return .allTradesClosed(tradesCount: allBrokerRecords.count)
            }
        }

        if let result = parseFiles(urls: urls, storageService: storageService) {
            return .success(result)
        }

        return .invalidFile
    }

    /// Parses multiple files (CSV, XLSX, JSON) and aggregates all parsed positions and closed trades.
    static func parseFiles(urls: [URL], storageService: StorageService? = nil) -> ImportResult? {
        var allItems: [ParsedImportItem] = []
        var allClosedTrades: [ClosedTrade] = []
        var suggestedNames: [String] = []

        // 1. Try Japanese broker / fund format aggregated across all URLs
        var allBrokerRecords: [SpreadsheetIO.BrokerTradeRecord] = []
        var brokerHandledURLs: Set<URL> = []

        for url in urls {
            if let records = SpreadsheetIO.extractJapaneseBrokerTradeRecords(from: url), !records.isEmpty {
                allBrokerRecords.append(contentsOf: records)
                brokerHandledURLs.insert(url)
                let name = url.deletingPathExtension().lastPathComponent
                if !suggestedNames.contains(name) {
                    suggestedNames.append(name)
                }
            }
        }

        var allTransactions: [Transaction] = []

        if !allBrokerRecords.isEmpty {
            let imported = SpreadsheetIO.processBrokerTradeRecords(allBrokerRecords)
            for p in imported {
                if !p.name.isEmpty && !suggestedNames.contains(p.name) {
                    suggestedNames.append(p.name)
                }
                for h in p.holdings {
                    let isFund = StockService.isJapaneseMutualFund(h.symbol)
                    allItems.append(ParsedImportItem(holding: h, isChecked: true, isFund: isFund, originalAccountName: p.name))
                }
                allClosedTrades.append(contentsOf: p.closedTrades)
                allTransactions.append(contentsOf: p.transactions)
            }
        }

        // 2. Try standard portfolio format (CSV / XLSX) & JSON for remaining URLs
        for url in urls where !brokerHandledURLs.contains(url) {
            if let imported = SpreadsheetIO.parseStandardPortfolios(from: url), !imported.isEmpty {
                for p in imported {
                    if !p.name.isEmpty && !suggestedNames.contains(p.name) {
                        suggestedNames.append(p.name)
                    }
                    for h in p.holdings {
                        let isFund = StockService.isJapaneseMutualFund(h.symbol)
                        allItems.append(ParsedImportItem(holding: h, isChecked: true, isFund: isFund, originalAccountName: p.name))
                    }
                    allClosedTrades.append(contentsOf: p.closedTrades)
                    allTransactions.append(contentsOf: p.transactions)
                }
                continue
            }

            if let data = try? Data(contentsOf: url),
               let imported = StorageService.importPortfolios(from: data), !imported.isEmpty {
                for p in imported {
                    if !p.name.isEmpty && !suggestedNames.contains(p.name) {
                        suggestedNames.append(p.name)
                    }
                    for h in p.holdings {
                        let isFund = StockService.isJapaneseMutualFund(h.symbol)
                        allItems.append(ParsedImportItem(holding: h, isChecked: true, isFund: isFund, originalAccountName: p.name))
                    }
                    allClosedTrades.append(contentsOf: p.closedTrades)
                    allTransactions.append(contentsOf: p.transactions)
                }
                continue
            }
        }

        guard !allItems.isEmpty || !allClosedTrades.isEmpty || !allTransactions.isEmpty else { return nil }

        let suggestedName = suggestedNames.first ?? urls.first?.deletingPathExtension().lastPathComponent
        let isFundImport = !allItems.isEmpty && allItems.allSatisfy { $0.isFund }
        return ImportResult(
            items: allItems,
            closedTrades: allClosedTrades,
            transactions: allTransactions,
            suggestedPortfolioName: suggestedName,
            isFundImport: isFundImport
        )
    }

    static func parseStandardFile(fileURL url: URL, storageService: StorageService? = nil) -> ImportResult? {
        parseFiles(urls: [url], storageService: storageService)
    }

    static func parseJapaneseFundFile(fileURL url: URL) -> ImportResult? {
        parseFiles(urls: [url])
    }

    #if os(macOS)
    /// Generates a clean sample Excel (.xlsx) file and saves it directly to ~/Downloads.
    static func downloadSample(storageService: StorageService, restoreActivationPolicy: Bool, onAlert: ((String) -> Void)? = nil) {
        guard let data = SpreadsheetIO.generateSampleXLSXData() else { return }
        guard let downloadsURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else { return }

        var targetURL = downloadsURL.appendingPathComponent("sample_portfolio.xlsx")
        var counter = 1
        while FileManager.default.fileExists(atPath: targetURL.path) {
            targetURL = downloadsURL.appendingPathComponent("sample_portfolio (\(counter)).xlsx")
            counter += 1
        }

        do {
            try data.write(to: targetURL, options: .atomic)
            NSWorkspace.shared.activateFileViewerSelecting([targetURL])
            onAlert?("Saved \(targetURL.lastPathComponent) to Downloads folder.")
        } catch {
            onAlert?("Could not save sample file.")
        }
    }

    /// Generates a sample 投資信託 (Japanese Funds) Excel (.xlsx) file and saves it directly to ~/Downloads.
    static func downloadJapaneseFundSample(restoreActivationPolicy: Bool = true, onAlert: ((String) -> Void)? = nil) {
        guard let data = SpreadsheetIO.generateJapaneseFundTemplateXLSXData() else { return }
        guard let downloadsURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else { return }

        var targetURL = downloadsURL.appendingPathComponent("japanese_funds_template.xlsx")
        var counter = 1
        while FileManager.default.fileExists(atPath: targetURL.path) {
            targetURL = downloadsURL.appendingPathComponent("japanese_funds_template (\(counter)).xlsx")
            counter += 1
        }

        do {
            try data.write(to: targetURL, options: .atomic)
            NSWorkspace.shared.activateFileViewerSelecting([targetURL])
            onAlert?("Saved \(targetURL.lastPathComponent) to Downloads folder.")
        } catch {
            onAlert?("Could not save 投資信託 template file.")
        }
    }

    /// Presents an NSOpenPanel to pick one or more Watchlist files (CSV/XLSX/TXT) and imports symbols into Watchlists.
    /// Supports multiple watchlists in one file (grouped by Watchlist Name column).
    /// If a watchlist with the same name already exists, merges symbols into it.
    static func pickAndParseWatchlist(storageService: StorageService, restoreActivationPolicy: Bool = true, onAlert: ((String) -> Void)? = nil) {
        let panel = NSOpenPanel()
        var types: [UTType] = [.commaSeparatedText, .plainText, .data]
        if let xlsxType = UTType(filenameExtension: "xlsx") {
            types.append(xlsxType)
        }
        panel.allowedContentTypes = types
        panel.allowsMultipleSelection = true
        panel.title = "Import Watchlists (CSV/XLSX/TXT)"
        if restoreActivationPolicy {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
        panel.begin { response in
            if restoreActivationPolicy {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    NSApp.setActivationPolicy(.accessory)
                }
            }
            guard response == .OK, !panel.urls.isEmpty else { return }
            Task { @MainActor in
                var allParsed: [(name: String, symbols: [String])] = []
                for url in panel.urls {
                    if let parsed = SpreadsheetIO.parseWatchlistsFile(from: url) {
                        allParsed.append(contentsOf: parsed)
                    }
                }
                if !allParsed.isEmpty {
                    var messages: [String] = []
                    for (wlName, symbols) in allParsed {
                        let deduped = Set(symbols)
                        if let existing = storageService.watchlists.first(where: {
                            $0.name.trimmingCharacters(in: .whitespaces).lowercased()
                            == wlName.trimmingCharacters(in: .whitespaces).lowercased()
                        }) {
                            storageService.addMultipleToWatchlist(deduped, targetWatchlistId: existing.id)
                            messages.append("\(deduped.count) symbols merged into existing “\(wlName)”")
                        } else {
                            let created = storageService.createWatchlist(name: wlName)
                            storageService.addMultipleToWatchlist(deduped, targetWatchlistId: created.id)
                            messages.append("\(deduped.count) symbols to new “\(wlName)”")
                        }
                    }
                    onAlert?("Imported \(allParsed.count) watchlist(s): " + messages.joined(separator: "; ") + ".")
                } else {
                    onAlert?("Could not parse watchlist file(s) or no valid symbols found.")
                }
            }
        }
    }

    /// Generates a sample Watchlist Excel (.xlsx) file and saves it directly to ~/Downloads.
    static func downloadWatchlistSample(restoreActivationPolicy: Bool = true, onAlert: ((String) -> Void)? = nil) {
        guard let data = SpreadsheetIO.generateWatchlistSampleXLSXData() else { return }
        guard let downloadsURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else { return }

        var targetURL = downloadsURL.appendingPathComponent("watchlist_sample.xlsx")
        var counter = 1
        while FileManager.default.fileExists(atPath: targetURL.path) {
            targetURL = downloadsURL.appendingPathComponent("watchlist_sample (\(counter)).xlsx")
            counter += 1
        }

        do {
            try data.write(to: targetURL, options: .atomic)
            NSWorkspace.shared.activateFileViewerSelecting([targetURL])
            onAlert?("Saved \(targetURL.lastPathComponent) to Downloads folder.")
        } catch {
            onAlert?("Could not save watchlist sample file.")
        }
    }
    #endif
}
