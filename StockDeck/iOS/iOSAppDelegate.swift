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
    private var symbolsObserver: AnyCancellable?
    private lazy var alertMonitor = AlertMonitor(storage: storageService)
    private lazy var portfolioMonitor = PortfolioMonitor(storage: storageService, stockService: stockService)

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {
        FontRegistration.registerFonts()
        NotificationManager.shared.requestAuthorization()

        // Sync WebSocket subscriptions with active symbols
        symbolsObserver = Publishers.CombineLatest(storageService.$portfolios, storageService.$watchlists)
            .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
            .sink { [weak self] _, _ in
                guard let self else { return }
                let symbols = Array(StockService.collectSymbols(storageService: self.storageService))
                self.webSocketService.ensureConnected(symbols: symbols)
                Task {
                    await self.stockService.refreshAll(storageService: self.storageService)
                }
            }

        // On WSS tick -> update quote in StockService & evaluate alerts
        webSocketService.onTick = { [weak self] tick in
            guard let self else { return }
            if self.stockService.applyTicks([tick]) {
                self.alertMonitor.check(quotes: self.stockService.quotes)
                self.portfolioMonitor.check()
            }
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
                await self.syncAllBinancePortfolios()
            }
        }

        // Initial refresh
        Task {
            let symbols = Array(StockService.collectSymbols(storageService: storageService))
            webSocketService.ensureConnected(symbols: symbols)
            await stockService.refreshAll(storageService: storageService)
            if storageService.showNewsTab {
                await stockService.refreshNews(storageService: storageService)
            }
        }

        return true
    }

    private func syncAllBinancePortfolios() async {
        for p in storageService.portfolios {
            if case .binance = p.sourceType {
                try? await storageService.syncBinancePortfolio(id: p.id)
            }
        }
    }
}
#endif
