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

    /// Clones production data.json to dev data.json.
    /// Only works if currently in Dev mode and prod file exists.
    @discardableResult
    static func cloneProdDataToDev() throws -> Bool {
        guard isDev else { return false }
        let prodFile = prodAppSupportDirectoryURL.appendingPathComponent("data.json")
        let devFile = appSupportDirectoryURL.appendingPathComponent("data.json")
        guard FileManager.default.fileExists(atPath: prodFile.path) else { return false }

        try FileManager.default.createDirectory(at: appSupportDirectoryURL, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: devFile.path) {
            try FileManager.default.removeItem(at: devFile)
        }
        try FileManager.default.copyItem(at: prodFile, to: devFile)
        return true
    }

    /// Auto-seed on first run for Dev if dev data doesn't exist yet (Option B).
    /// Copies prod data.json to dev data.json once on first run.
    static func autoSeedDevDataIfNeeded() {
        guard isDev else { return }
        let prodFile = prodAppSupportDirectoryURL.appendingPathComponent("data.json")
        let devFile = appSupportDirectoryURL.appendingPathComponent("data.json")
        let manager = FileManager.default

        // Only auto-seed if dev file doesn't exist, but prod file exists
        if !manager.fileExists(atPath: devFile.path), manager.fileExists(atPath: prodFile.path) {
            try? manager.createDirectory(at: appSupportDirectoryURL, withIntermediateDirectories: true)
            try? manager.copyItem(at: prodFile, to: devFile)
            NSLog("[AppEnvironment] Auto-seeded Dev data from Production snapshot successfully.")
        }
    }

    /// Opens the specified folder URL in Finder.
    static func openFolderInFinder(_ url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }
}
