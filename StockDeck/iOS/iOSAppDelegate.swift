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
    private var storageServiceObserver: AnyCancellable?
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
                let symbols = self.storageService.allTrackedSymbols
                self.webSocketService.subscribe(symbols: symbols)
                Task {
                    await self.stockService.refreshAll(storageService: self.storageService)
                }
            }

        // On WSS tick -> update quote in StockService & evaluate alerts
        webSocketService.onTick = { [weak self] tick in
            guard let self else { return }
            self.stockService.applyTick(tick)
            if let quote = self.stockService.quotes[tick.id] {
                self.alertMonitor.evaluate(quote: quote)
                self.portfolioMonitor.evaluate(quote: quote)
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
                await self.storageService.syncAllBinancePortfolios()
            }
        }

        // Initial refresh
        Task {
            let symbols = storageService.allTrackedSymbols
            webSocketService.subscribe(symbols: symbols)
            await stockService.refreshAll(storageService: storageService)
            if storageService.showNewsTab {
                await stockService.refreshNews(storageService: storageService)
            }
        }

        return true
    }
}
#endif
