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

    /// Presents an NSOpenPanel, reads and merges the imported portfolios, and
    /// reports the result via `onAlert` (mirrors the exact alert wording used
    /// at both call sites). See `exportAll` for `restoreActivationPolicy`.
    static func importInto(_ storageService: StorageService, restoreActivationPolicy: Bool, onAlert: @escaping (String) -> Void) {
        let panel = NSOpenPanel()
        var types: [UTType] = [.json, .commaSeparatedText]
        if let xlsxType = UTType(filenameExtension: "xlsx") {
            types.append(xlsxType)
        }
        panel.allowedContentTypes = types
        panel.allowsMultipleSelection = false
        panel.title = "Import Portfolios (XLSX, CSV, or JSON)"
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
            guard let data = try? Data(contentsOf: url) else {
                Task { @MainActor in onAlert("Could not read file.") }
                return
            }
            Task { @MainActor in
                let imported: [Portfolio]?
                if let spreadsheetImport = SpreadsheetIO.parsePortfolios(from: url) {
                    imported = spreadsheetImport
                } else {
                    imported = storageService.importPortfolios(from: data)
                }

                guard let imported, !imported.isEmpty else {
                    onAlert("Invalid file format or empty portfolio file.")
                    return
                }

                storageService.mergeImportedPortfolios(imported)
                onAlert("Imported \(imported.count) portfolio\(imported.count == 1 ? "" : "s").")
            }
        }
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
}
