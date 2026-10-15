import Foundation
import AppKit

enum AppEnvironment {
    /// Checks whether the app is currently running in Development mode.
    /// Priority:
    /// 1. Environment variable `STOCKDECK_ENV` ("dev" / "development" / "prod" / "production")
    /// 2. #if DEBUG compiler flag
    /// 3. Bundle identifier != "com.terry.stockdeck"
    static var isDev: Bool {
        if let env = ProcessInfo.processInfo.environment["STOCKDECK_ENV"] {
            let lower = env.lowercased()
            if lower == "dev" || lower == "development" { return true }
            if lower == "prod" || lower == "production" { return false }
        }
        #if DEBUG
        return true
        #else
        if let bundleId = Bundle.main.bundleIdentifier, bundleId != "com.terry.stockdeck" {
            return true
        }
        return false
        #endif
    }

    /// Application Support subfolder name
    static var appSupportFolderName: String {
        isDev ? "StockDeck-Dev" : "StockDeck"
    }

    /// iCloud Drive sync subfolder name
    static var iCloudFolderName: String {
        isDev ? "StockDeck-Dev" : "StockDeck"
    }

    /// Keychain service identifier
    static var keychainServiceName: String {
        isDev ? "com.stockdeck.app.binance.dev" : "com.stockdeck.app.binance"
    }

    /// URL to the active Application Support directory for this environment
    static var appSupportDirectoryURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent(appSupportFolderName, isDirectory: true)
    }

    /// URL to the Production Application Support directory
    static var prodAppSupportDirectoryURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("StockDeck", isDirectory: true)
    }

    /// List of file and directory names to clone from Production to Dev for complete parity.
    static let itemsToClone: [String] = [
        "data.json",
        "data.json.bak",
        "historyCache.json",
        "historyCache.json.bak",
        "keyStatsCache.json",
        "keyStatsCache.json.bak",
        "daily_ai_insight.json",
        "vn_valuation_cache.json",
        "vn_valuation_cache.json.bak",
        "Logos",
        "InsiderCache",
        "EarningsCache",
        "note-images"
    ]

    /// Clones production files and cache directories from source to destination.
    @discardableResult
    static func cloneDirectory(from sourceDir: URL, to destDir: URL) throws -> Bool {
        let prodDataFile = sourceDir.appendingPathComponent("data.json")
        guard FileManager.default.fileExists(atPath: prodDataFile.path) else { return false }

        let manager = FileManager.default
        try manager.createDirectory(at: destDir, withIntermediateDirectories: true)

        let devDataFile = destDir.appendingPathComponent("data.json")
        if manager.fileExists(atPath: devDataFile.path) {
            try manager.removeItem(at: devDataFile)
        }
        try manager.copyItem(at: prodDataFile, to: devDataFile)

        for item in itemsToClone where item != "data.json" {
            let prodItem = sourceDir.appendingPathComponent(item)
            let devItem = destDir.appendingPathComponent(item)
            guard manager.fileExists(atPath: prodItem.path) else { continue }
            if manager.fileExists(atPath: devItem.path) {
                try? manager.removeItem(at: devItem)
            }
            try? manager.copyItem(at: prodItem, to: devItem)
        }

        let marker = destDir.appendingPathComponent(".dev_seeded")
        manager.createFile(atPath: marker.path, contents: Data(), attributes: nil)

        return true
    }

    /// Clones production data.json and auxiliary caches to dev data directory.
    /// Only works if currently in Dev mode and prod file exists.
    @discardableResult
    static func cloneProdDataToDev() throws -> Bool {
        guard isDev else { return false }
        return try cloneDirectory(from: prodAppSupportDirectoryURL, to: appSupportDirectoryURL)
    }

    /// Checks if a data.json file contains zero holdings and zero watchlist symbols.
    static func isDevDataEffectivelyEmpty(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url) else { return true }
        if data.isEmpty || data.count < 60 { return true }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        let portfolios = json["portfolios"] as? [[String: Any]] ?? []
        let watchlists = json["watchlists"] as? [[String: Any]] ?? []
        let totalHoldings = portfolios.reduce(0) { sum, p in
            let holdings = p["holdings"] as? [[String: Any]] ?? []
            return sum + holdings.count
        }
        let totalSymbols = watchlists.reduce(0) { sum, w in
            let symbols = w["symbols"] as? [String] ?? []
            return sum + symbols.count
        }
        return totalHoldings == 0 && totalSymbols == 0
    }

    /// Auto-seed on first run for Dev if dev data doesn't exist yet or is empty.
    /// Copies prod data.json and all caches to dev data.json once on first run.
    static func autoSeedDevDataIfNeeded() {
        guard isDev else { return }
        let prodFile = prodAppSupportDirectoryURL.appendingPathComponent("data.json")
        let devFile = appSupportDirectoryURL.appendingPathComponent("data.json")
        let marker = appSupportDirectoryURL.appendingPathComponent(".dev_seeded")
        let manager = FileManager.default

        guard manager.fileExists(atPath: prodFile.path) else { return }

        let devFileExists = manager.fileExists(atPath: devFile.path)
        let seeded = manager.fileExists(atPath: marker.path)

        if !devFileExists || (!seeded && isDevDataEffectivelyEmpty(devFile)) {
            do {
                try cloneProdDataToDev()
                NSLog("[AppEnvironment] Auto-seeded Dev data from Production snapshot successfully.")
            } catch {
                NSLog("[AppEnvironment] Failed to auto-seed Dev data: %@", error.localizedDescription)
            }
        }
    }

    /// Opens the specified folder URL in Finder.
    static func openFolderInFinder(_ url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }
}
