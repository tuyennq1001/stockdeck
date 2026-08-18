import Foundation
import Combine

@MainActor
final class iCloudSyncService: ObservableObject {
    static let shared = iCloudSyncService()

    private let store = NSUbiquitousKeyValueStore.default
    private let kSyncPayloadKey = "stockdeck_appdata_payload"
    private let kSyncTimestampKey = "stockdeck_sync_timestamp"
    private let kSyncDeviceIdKey = "stockdeck_sync_device_id"

    @Published var lastSyncDate: Date? = nil
    @Published var syncStatus: String = "Idle"
    @Published var isSyncing: Bool = false

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

        // If iCloud sync is enabled, pull remote data on launch
        if StorageService.shared.iCloudSyncEnabled {
            pullAndMerge(force: false)
        }
    }

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

        if let driveURL = iCloudDriveSyncFileURL,
           FileManager.default.fileExists(atPath: driveURL.path),
           let driveData = try? Data(contentsOf: driveURL) {
            remoteData = driveData
            isFromDrive = true
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
                var combinedHoldings = mergedPortfolios[idx].holdings
                for rh in rp.holdings {
                    let exists = combinedHoldings.contains { lh in
                        lh.symbol == rh.symbol &&
                        abs(lh.avgPrice - rh.avgPrice) < 0.0001 &&
                        abs(lh.quantity - rh.quantity) < 0.0001
                    }
                    if !exists {
                        combinedHoldings.append(rh)
                    }
                }
                mergedPortfolios[idx].holdings = combinedHoldings
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

        return merged
    }
}
