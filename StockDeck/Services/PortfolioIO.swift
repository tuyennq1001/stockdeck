import AppKit
import UniformTypeIdentifiers

/// Shared NSSavePanel/NSOpenPanel plumbing for portfolio export/import,
/// used by both `PortfolioListView` (menu-bar popover) and `PortfolioWindowView`
/// (full desktop window). The actual JSON encode/decode/merge logic lives in
/// `StorageService`; this only owns the panel configuration and presentation.
@MainActor
enum PortfolioIO {

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

    struct ImportResult: Identifiable {
        let id = UUID()
        let items: [ParsedImportItem]
        let suggestedPortfolioName: String?
        let isFundImport: Bool
    }

    /// Helper to pick a file and parse standard holdings for preview.
    static func pickAndParseStandard(
        storageService: StorageService,
        restoreActivationPolicy: Bool,
        onParsed: @escaping (ImportResult) -> Void,
        onAlert: @escaping (String) -> Void
    ) {
        let panel = NSOpenPanel()
        var types: [UTType] = [.json, .commaSeparatedText]
        if let xlsxType = UTType(filenameExtension: "xlsx") {
            types.append(xlsxType)
        }
        panel.allowedContentTypes = types
        panel.allowsMultipleSelection = false
        panel.title = "Import Standard Portfolios (CSV, XLSX, JSON)"
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
            Task { @MainActor in
                if let res = parseStandardFile(fileURL: url, storageService: storageService) {
                    onParsed(res)
                } else {
                    onAlert("Invalid file format or empty portfolio file.")
                }
            }
        }
    }

    /// Helper to pick a file and parse Japanese 投資信託 fund holdings for preview.
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
        panel.allowsMultipleSelection = false
        panel.title = "Import 投資信託 (Japanese Funds Trade History CSV/XLSX)"
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
            Task { @MainActor in
                if let res = parseJapaneseFundFile(fileURL: url) {
                    onParsed(res)
                } else {
                    onAlert("Could not parse 投資信託 file or no valid trades found.")
                }
            }
        }
    }

    static func parseStandardFile(fileURL url: URL, storageService: StorageService) -> ImportResult? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let imported: [Portfolio]?
        if let spreadsheetImport = SpreadsheetIO.parseStandardPortfolios(from: url) {
            imported = spreadsheetImport
        } else {
            imported = storageService.importPortfolios(from: data)
        }
        guard let imported, !imported.isEmpty else { return nil }

        let allHoldings = imported.flatMap { $0.holdings }
        let items = allHoldings.map { ParsedImportItem(holding: $0, isChecked: true, isFund: false, originalAccountName: nil) }
        let suggestedName = imported.first?.name
        return ImportResult(items: items, suggestedPortfolioName: suggestedName, isFundImport: false)
    }

    static func parseJapaneseFundFile(fileURL url: URL) -> ImportResult? {
        guard let imported = SpreadsheetIO.parseJapaneseFundCSV(from: url), !imported.isEmpty else { return nil }
        var items: [ParsedImportItem] = []
        for p in imported {
            for h in p.holdings {
                items.append(ParsedImportItem(holding: h, isChecked: true, isFund: true, originalAccountName: p.name))
            }
        }
        let suggestedName = imported.first?.name
        return ImportResult(items: items, suggestedPortfolioName: suggestedName, isFundImport: true)
    }

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
}
