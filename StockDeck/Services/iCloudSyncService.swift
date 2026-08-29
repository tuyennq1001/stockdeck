import Foundation
import Combine
#if os(iOS)
import UIKit
#endif

@MainActor
final class iCloudSyncService: ObservableObject {
    static let shared = iCloudSyncService()

    private let store = NSUbiquitousKeyValueStore.default
    private let kSyncPayloadKey = "stockdeck_appdata_payload"
    private let kSyncTimestampKey = "stockdeck_sync_timestamp"
    private let kSyncDeviceIdKey = "stockdeck_sync_device_id"
    private let kBookmarkKey = "stockdeck_icloud_file_bookmark"

    @Published var lastSyncDate: Date? = nil
    @Published var syncStatus: String = "Idle"
    @Published var isSyncing: Bool = false
    @Published var isFileLinked: Bool = false
    @Published var linkedFileName: String = ""

    /// Checks if the user is currently signed in to an Apple ID / iCloud account on this device
    var isiCloudAvailable: Bool {
        FileManager.default.ubiquityIdentityToken != nil
    }

    private let deviceId: String
    private var pushDebounceTask: Task<Void, Never>?
    private var isStarted = false

    private init() {
        if let storedId = UserDefaults.standard.string(forKey: "stockdeck_device_uuid") {
            self.deviceId = storedId
        } else {
            let newId = UUID().uuidString
            UserDefaults.standard.set(newId, forKey: "stockdeck_device_uuid")
            self.deviceId = newId
        }
        updateLinkedFileStatus()
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(ubiquitousKeyValueStoreDidChange(_:)),
            name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: store
        )
        store.synchronize()

        updateLinkedFileStatus()

        // If iCloud sync is enabled, pull remote data on launch
        if StorageService.shared.iCloudSyncEnabled {
            pullAndMerge(force: false)
        }
    }

    func updateLinkedFileStatus() {
        #if os(iOS)
        if let url = resolveBookmarkedURL() {
            isFileLinked = true
            linkedFileName = url.lastPathComponent
        } else {
            isFileLinked = false
            linkedFileName = ""
        }
        #else
        isFileLinked = true
        linkedFileName = "stockdeck_sync.json"
        #endif
    }

    #if os(iOS)
    func saveBookmark(for url: URL) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        guard let bookmarkData = try? url.bookmarkData(
            options: .minimalBookmark,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else { return }

        UserDefaults.standard.set(bookmarkData, forKey: kBookmarkKey)
        updateLinkedFileStatus()
    }

    func resolveBookmarkedURL() -> URL? {
        guard let bookmarkData = UserDefaults.standard.data(forKey: kBookmarkKey) else {
            return nil
        }
        var isStale = false
        guard let resolvedURL = try? URL(
            resolvingBookmarkData: bookmarkData,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            return nil
        }
        if isStale {
            saveBookmark(for: resolvedURL)
        }
        return resolvedURL
    }
    #endif

    @objc private func ubiquitousKeyValueStoreDidChange(_ notification: Notification) {
        Task { @MainActor in
            guard StorageService.shared.iCloudSyncEnabled else { return }
            guard let userInfo = notification.userInfo,
                  let changeReason = userInfo[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int else {
                pullAndMerge(force: false)
                return
            }

            if changeReason == NSUbiquitousKeyValueStoreServerChange ||
               changeReason == NSUbiquitousKeyValueStoreInitialSyncChange {
                pullAndMerge(force: false)
            }
        }
    }

    /// Called when user toggles the sync switch
    func onSyncToggleChanged(enabled: Bool) {
        if enabled {
            pullAndMerge(force: true)
        }
    }

    /// Location for iCloud Drive synchronization file
    var iCloudDriveSyncFileURL: URL? {
        #if os(macOS)
        let home = FileManager.default.homeDirectoryForCurrentUser
        let cloudDocs = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        if FileManager.default.fileExists(atPath: cloudDocs.path) {
            let folder = cloudDocs.appendingPathComponent("StockDeck", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return folder.appendingPathComponent("stockdeck_sync.json")
        }
        #else
        if let ubiquityURL = FileManager.default.url(forUbiquityContainerIdentifier: nil) {
            let docs = ubiquityURL.appendingPathComponent("Documents", isDirectory: true)
            try? FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
            return docs.appendingPathComponent("stockdeck_sync.json")
        }
        if let bookmarked = resolveBookmarkedURL() {
            return bookmarked
        }
        #endif
        return nil
    }

    /// Triggers a debounced push to iCloud (1.5s after user finishes local modifications)
    func schedulePush() {
        guard StorageService.shared.iCloudSyncEnabled else { return }
        pushDebounceTask?.cancel()
        pushDebounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            self.pushLocalData()
        }
    }

    /// Pushes local data directly to iCloud (iCloud Drive + KVS)
    func pushLocalData() {
        guard StorageService.shared.iCloudSyncEnabled else { return }
        isSyncing = true
        let appData = StorageService.shared.exportAppData()
        guard let encoded = try? JSONEncoder().encode(appData) else {
            isSyncing = false
            return
        }

        var wroteDrive = false
        if let driveURL = iCloudDriveSyncFileURL {
            #if os(iOS)
            let accessed = driveURL.startAccessingSecurityScopedResource()
            defer { if accessed { driveURL.stopAccessingSecurityScopedResource() } }
            #endif
            do {
                try encoded.write(to: driveURL, options: .atomic)
                wroteDrive = true
            } catch {
                NSLog("[iCloudSync] Failed to write iCloud Drive: %@", error.localizedDescription)
            }
        }

        let now = Date().timeIntervalSince1970
        store.set(encoded, forKey: kSyncPayloadKey)
        store.set(now, forKey: kSyncTimestampKey)
        store.set(deviceId, forKey: kSyncDeviceIdKey)
        let kvsSuccess = store.synchronize()

        let date = Date()
        self.lastSyncDate = date
        if wroteDrive || kvsSuccess {
            self.syncStatus = "Uploaded to iCloud"
        } else if !isiCloudAvailable {
            self.syncStatus = "Saved locally (iCloud not signed in)"
        } else {
            self.syncStatus = "Uploaded to iCloud"
        }
        StorageService.shared.lastiCloudSyncDate = date
        isSyncing = false
    }

    /// Pulls remote data from iCloud and smart-merges into local StorageService
    func pullAndMerge(force: Bool = false) {
        guard StorageService.shared.iCloudSyncEnabled else { return }
        isSyncing = true

        var remoteData: Data? = nil
        var isFromDrive = false

        if let driveURL = iCloudDriveSyncFileURL {
            #if os(iOS)
            let accessed = driveURL.startAccessingSecurityScopedResource()
            defer { if accessed { driveURL.stopAccessingSecurityScopedResource() } }
            #endif

            if FileManager.default.fileExists(atPath: driveURL.path),
               let driveData = try? Data(contentsOf: driveURL) {
                remoteData = driveData
                isFromDrive = true
            }
        }

        if remoteData == nil {
            if let kvsData = store.data(forKey: kSyncPayloadKey),
               let _ = store.object(forKey: kSyncTimestampKey) as? Double {
                remoteData = kvsData
            }
        }

        guard let remoteDataToUse = remoteData else {
            if !isiCloudAvailable {
                self.syncStatus = "iCloud not signed in on this device"
            } else {
                self.syncStatus = "No data found on iCloud"
            }
            isSyncing = false
            return
        }

        let remoteDeviceId = store.string(forKey: kSyncDeviceIdKey) ?? ""
        // If this change came from this device and not forced, ignore
        if !force && !isFromDrive && remoteDeviceId == self.deviceId {
            isSyncing = false
            return
        }

        guard let decodedRemote = try? JSONDecoder().decode(StorageService.AppData.self, from: remoteDataToUse) else {
            self.syncStatus = "Cloud data format error"
            isSyncing = false
            return
        }

        let local = StorageService.shared.exportAppData()
        let merged = smartMerge(local: local, remote: decodedRemote)

        StorageService.shared.applyAppData(merged, isFromSync: true)
        let date = Date()
        self.lastSyncDate = date
        self.syncStatus = "Synced"
        StorageService.shared.lastiCloudSyncDate = date

        // Converge remote to the merged state
        if let mergedEncoded = try? JSONEncoder().encode(merged) {
            if let driveURL = iCloudDriveSyncFileURL {
                #if os(iOS)
                let accessed = driveURL.startAccessingSecurityScopedResource()
                defer { if accessed { driveURL.stopAccessingSecurityScopedResource() } }
                #endif
                try? mergedEncoded.write(to: driveURL, options: .atomic)
            }
            let now = Date().timeIntervalSince1970
            store.set(mergedEncoded, forKey: kSyncPayloadKey)
            store.set(now, forKey: kSyncTimestampKey)
            store.set(deviceId, forKey: kSyncDeviceIdKey)
            store.synchronize()
        }

        isSyncing = false

        // Refresh quotes for any newly merged symbols
        Task {
            await StockService.shared.refreshAll(storageService: StorageService.shared)
        }
    }

    /// Smart Merge algorithm combining local and remote data without losing positions or lists
    func smartMerge(local: StorageService.AppData, remote: StorageService.AppData) -> StorageService.AppData {
        var merged = local

        // 1. Merge Watchlists
        var mergedWatchlists: [Watchlist] = local.watchlists ?? []
        let localHasOnlyEmptyDefault = (local.watchlists?.count == 1 && local.watchlists?.first?.name.lowercased() == "watchlist" && local.watchlists?.first?.symbols.isEmpty == true)
        if localHasOnlyEmptyDefault && remote.watchlists?.isEmpty == false {
            mergedWatchlists = []
        }

        if let remoteWatchlists = remote.watchlists {
            for rw in remoteWatchlists {
                let trimmedRemoteName = rw.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if let idx = mergedWatchlists.firstIndex(where: {
                    $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == trimmedRemoteName
                }) {
                    var combined = mergedWatchlists[idx].symbols
                    for sym in rw.symbols {
                        if !combined.contains(sym) {
                            combined.append(sym)
                        }
                    }
                    mergedWatchlists[idx].symbols = combined
                } else {
                    mergedWatchlists.append(rw)
                }
            }
        }
        if mergedWatchlists.count > 1 {
            mergedWatchlists.removeAll { $0.symbols.isEmpty && $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "watchlist" }
        }
        if !mergedWatchlists.isEmpty {
            merged.watchlists = mergedWatchlists
            if let activeId = local.selectedWatchlistId,
               let activeWl = mergedWatchlists.first(where: { $0.id == activeId }) {
                merged.watchlist = activeWl.symbols
            } else {
                merged.watchlist = mergedWatchlists.first?.symbols ?? []
            }
        }

        // 2. Merge Portfolios
        var mergedPortfolios: [Portfolio] = local.portfolios
        for rp in remote.portfolios {
            let trimmedRemoteName = rp.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if let idx = mergedPortfolios.firstIndex(where: {
                $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == trimmedRemoteName
            }) {
                if rp.isReadOnly || mergedPortfolios[idx].isReadOnly {
                    // For auto-synced / read-only portfolios (like Binance):
                    // Use the latest sync snapshot rather than appending lots!
                    let localSync = mergedPortfolios[idx].lastSyncedAt ?? .distantPast
                    let remoteSync = rp.lastSyncedAt ?? .distantPast
                    if remoteSync >= localSync {
                        mergedPortfolios[idx].holdings = rp.holdings
                        mergedPortfolios[idx].lastSyncedAt = rp.lastSyncedAt
                    }
                } else {
                    var combinedHoldings = mergedPortfolios[idx].holdings
                    for rh in rp.holdings {
                        let exists = combinedHoldings.contains { lh in
                            if lh.id == rh.id { return true }
                            guard lh.symbol.caseInsensitiveCompare(rh.symbol) == .orderedSame else { return false }
                            guard abs(lh.quantity - rh.quantity) < 1e-6 else { return false }
                            if lh.avgPrice.isNaN && rh.avgPrice.isNaN {
                                // Both unknown cost basis -> matched
                            } else if lh.avgPrice.isFinite && rh.avgPrice.isFinite {
                                guard abs(lh.avgPrice - rh.avgPrice) < 1e-4 else { return false }
                            } else {
                                return false
                            }
                            if let ld = lh.purchaseDate, let rd = rh.purchaseDate {
                                guard abs(ld.timeIntervalSince(rd)) < 60 else { return false }
                            } else if lh.purchaseDate != rh.purchaseDate {
                                return false
                            }
                            if lh.account != rh.account { return false }
                            return true
                        }
                        if !exists {
                            combinedHoldings.append(rh)
                        }
                    }
                    mergedPortfolios[idx].holdings = combinedHoldings
                }
            } else {
                mergedPortfolios.append(rp)
            }
        }
        merged.portfolios = mergedPortfolios

        // 3. Merge Alerts
        var combinedAlerts = local.alerts ?? []
        if let remoteAlerts = remote.alerts {
            for ra in remoteAlerts {
                if !combinedAlerts.contains(where: { $0.id == ra.id || ($0.symbol == ra.symbol && $0.condition == ra.condition && abs($0.threshold - ra.threshold) < 0.0001) }) {
                    combinedAlerts.append(ra)
                }
            }
        }
        merged.alerts = combinedAlerts

        // 4. Merge Symbol Notes
        var combinedNotes = local.symbolNotes ?? [:]
        if let remoteNotes = remote.symbolNotes {
            for (sym, rNotes) in remoteNotes {
                if var existing = combinedNotes[sym] {
                    for rn in rNotes {
                        if !existing.contains(where: { $0.id == rn.id }) {
                            existing.append(rn)
                        }
                    }
                    combinedNotes[sym] = existing
                } else {
                    combinedNotes[sym] = rNotes
                }
            }
        }
        merged.symbolNotes = combinedNotes

        // 5. Merge User Preferences & Settings
        if let rc = remote.preferredCurrency, !rc.isEmpty {
            merged.preferredCurrency = rc
        }
        if let sc = remote.stockPriceCurrency, !sc.isEmpty {
            merged.stockPriceCurrency = sc
        }
        if let exh = remote.showExtendedHours {
            merged.showExtendedHours = exh
        }
        if let gColor = remote.gainColorHex, !gColor.isEmpty {
            merged.gainColorHex = gColor
        }
        if let lColor = remote.lossColorHex, !lColor.isEmpty {
            merged.lossColorHex = lColor
        }
        if let pDec = remote.percentDecimals {
            merged.percentDecimals = pDec
        }
        if let vDec = remote.valueDecimals {
            merged.valueDecimals = vDec
        }
        if let adv = remote.advancedPositions {
            merged.advancedPositions = adv
        }
        if let dcs = remote.defaultChartStyle {
            merged.defaultChartStyle = dcs
        }
        if let lang = remote.appLanguage {
            merged.appLanguage = lang
        }
        if let cols = remote.portfolioColumns {
            merged.portfolioColumns = cols
        }
        if let fSize = remote.fontSizeLevel {
            merged.fontSizeLevel = fSize
        }
        if let fontF = remote.fontFamily {
            merged.fontFamily = fontF
        }
        if let sName = remote.showCompanyName {
            merged.showCompanyName = sName
        }
        if let sSpark = remote.showWatchlistSparkline {
            merged.showWatchlistSparkline = sSpark
        }
        if let sDay = remote.showDayRange {
            merged.showDayRange = sDay
        }
        if let s52 = remote.show52WeekBar {
            merged.show52WeekBar = s52
        }
        if let sAbs = remote.showAbsoluteChange {
            merged.showAbsoluteChange = sAbs
        }
        if let rRanges = remote.portfolioChartRanges {
            var combined = merged.portfolioChartRanges ?? [:]
            for (k, v) in rRanges { combined[k] = v }
            merged.portfolioChartRanges = combined
        }
        if let rDaily = remote.portfolioDailyPnlRanges {
            var combined = merged.portfolioDailyPnlRanges ?? [:]
            for (k, v) in rDaily { combined[k] = v }
            merged.portfolioDailyPnlRanges = combined
        }
        if let rMonthly = remote.portfolioMonthlyPnlRanges {
            var combined = merged.portfolioMonthlyPnlRanges ?? [:]
            for (k, v) in rMonthly { combined[k] = v }
            merged.portfolioMonthlyPnlRanges = combined
        }
        if let rModes = remote.portfolioPnlViewModes {
            var combined = merged.portfolioPnlViewModes ?? [:]
            for (k, v) in rModes { combined[k] = v }
            merged.portfolioPnlViewModes = combined
        }
        if let rSorts = remote.portfolioPositionSorts {
            var combined = merged.portfolioPositionSorts ?? [:]
            for (k, v) in rSorts { combined[k] = v }
            merged.portfolioPositionSorts = combined
        }
        if let mbd = remote.menuBarDisplay, !mbd.isEmpty {
            merged.menuBarDisplay = mbd
        }
        if let aip = remote.aiProvider, !aip.isEmpty {
            merged.aiProvider = aip
        }
        if let aib = remote.aiBaseURL, !aib.isEmpty {
            merged.aiBaseURL = aib
        }
        if let aim = remote.aiModel, !aim.isEmpty {
            merged.aiModel = aim
        }
        if let wsp = remote.aiWorkspacePath {
            merged.aiWorkspacePath = wsp
        }
        if let dst = remote.aiDeepseekThinking {
            merged.aiDeepseekThinking = dst
        }
        if let prof = remote.investorProfile {
            merged.investorProfile = prof
        }
        if let sc = remote.menuBarShortcut {
            merged.menuBarShortcut = sc
        }
        if let rSections = remote.aiChatSections, !rSections.isEmpty {
            var combinedSections = merged.aiChatSections ?? []
            for rs in rSections {
                if !combinedSections.contains(where: { $0.id == rs.id }) {
                    combinedSections.append(rs)
                }
            }
            merged.aiChatSections = combinedSections
        }

        return merged
    }
}
