#if os(iOS)
import Combine
import SwiftUI
import UIKit

@MainActor
final class iOSAppDelegate: NSObject, UIApplicationDelegate, ObservableObject {
    private var stockService = StockService.shared
    private var storageService = StorageService.shared
    private var webSocketService = WebSocketService.shared
    private var timer: Timer?
    private var binanceTimer: Timer?
    private var pendingTicks: [Yaticker] = []
    private var tickBatchTimer: Timer?
    private var symbolsObserver: AnyCancellable?
    private lazy var alertMonitor = AlertMonitor(storage: storageService)
    private lazy var portfolioMonitor = PortfolioMonitor(storage: storageService, stockService: stockService)

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {
        FontRegistration.registerFonts()
        NotificationManager.shared.requestAuthorization()
        iCloudSyncService.shared.start()

        // Sync WebSocket subscriptions with active symbols
        symbolsObserver = Publishers.CombineLatest(storageService.$portfolios, storageService.$watchlists)
            .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
            .sink { [weak self] _, _ in
                guard let self else { return }
                let wssSymbols = Array(StockService.collectWebSocketSymbols(storageService: self.storageService))
                self.webSocketService.ensureConnected(symbols: wssSymbols)
                Task {
                    await self.stockService.refreshAll(storageService: self.storageService)
                }
            }

        // On WSS tick -> buffer tick and flush max once per second to prevent @Published UI thrashing
        webSocketService.onTick = { [weak self] ticker in
            guard let self else { return }
            self.pendingTicks.append(ticker)
            self.scheduleTickFlush()
        }

        // REST polling timer every 60s fallback
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                await self.stockService.refreshAll(storageService: self.storageService)
            }
        }

        // Auto-sync Binance every 10 min
        binanceTimer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                await self.storageService.syncAllBinancePortfolios()
            }
        }

        // Initial refresh
        Task {
            let wssSymbols = Array(StockService.collectWebSocketSymbols(storageService: storageService))
            webSocketService.ensureConnected(symbols: wssSymbols)
            await storageService.syncAllBinancePortfolios()
            await stockService.refreshAll(storageService: storageService)
            await stockService.refreshNews(storageService: storageService)
        }

        return true
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        Task { @MainActor in
            await storageService.syncAllBinancePortfolios()
            await stockService.refreshAll(storageService: storageService)
        }
    }

    /// Flush buffered ticks max once per second to avoid @Published spam
    private func scheduleTickFlush() {
        guard tickBatchTimer == nil else { return }
        tickBatchTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.tickBatchTimer = nil
                self.flushTicks()
            }
        }
    }

    private func flushTicks() {
        guard !pendingTicks.isEmpty else { return }
        let ticks = pendingTicks
        pendingTicks.removeAll(keepingCapacity: false)

        // Keep only the latest tick per symbol
        var latest: [String: Yaticker] = [:]
        for tick in ticks {
            latest[tick.id] = tick
        }

        if stockService.applyTicks(Array(latest.values)) {
            alertMonitor.check(quotes: stockService.quotes)
            portfolioMonitor.check()
        }
    }
}
#endif
