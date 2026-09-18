import AppKit
import Combine
import Sparkle
import SwiftUI
import UserNotifications

extension Notification.Name {
    static let popoverDidClose = Notification.Name("popoverDidClose")
    /// Posted when the user clicks an alert notification; the desktop window
    /// listens and jumps to the Alerts tab.
    static let stockDeckAlertTapped = Notification.Name("stockDeckAlertTapped")
}

final class SparkleDelegate: NSObject, SPUUpdaterDelegate {
    func updater(_ updater: SPUUpdater, didFinishLoading appcast: SUAppcast) {
        NSLog("[Sparkle] Appcast loaded OK, %d items", appcast.items.count)
    }
    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        NSLog("[Sparkle] Aborted: %@", error.localizedDescription)
    }
}

final class UpdaterViewModel: ObservableObject {
    private let controller: SPUStandardUpdaterController?
    private let sparkleDelegate = SparkleDelegate()

    var canCheckForUpdates: Bool {
        controller?.updater.canCheckForUpdates ?? false
    }

    var isAvailable: Bool {
        controller != nil
    }

    init() {
        if let feedURLStr = BundleInfo.infoDictionary?["SUFeedURL"] as? String, !feedURLStr.isEmpty {
            let c = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: sparkleDelegate, userDriverDelegate: nil)
            self.controller = c
        } else {
            self.controller = nil
        }
    }

    func checkForUpdates() {
        controller?.updater.checkForUpdates()
    }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var portfolioWindow: NSWindow?
    private var isPresentingPortfolioWindow = false
    private var portfolioActivationGeneration = 0
    private var stockService = StockService.shared
    private var storageService = StorageService.shared
    private var webSocketService = WebSocketService.shared
    private var timer: Timer?
    private var tickerIndex = 0
    private var eventMonitor: Any?
    /// The regular application that was frontmost before StockDeck's menu bar item was clicked,
    /// used to perform a focus bounce so macOS Dock registers StockDeck at index 0 of Cmd+Tab.
    private var lastActiveApplication: NSRunningApplication?
    /// Guards the `didBecomeActive` fallback so a click that already opened the
    /// Alerts tab doesn't fire twice.
    private var lastAlertActivationAt: Date = .distantPast
    /// When the current refresh started. Nil = no refresh in flight. Used via
    /// `ConnectionSupervisor.refreshIsBlocking` instead of a bare Bool so a
    /// refresh Task cancelled by a sleep/wake race can't leave polling wedged.
    private var refreshStartedAt: Date?
    private var isRefreshing: Bool {
        ConnectionSupervisor.refreshIsBlocking(startedAt: refreshStartedAt, now: Date())
    }
    private var refreshTask: Task<Void, Never>?
    private var pendingTicks: [Yaticker] = []
    private var tickBatchTimer: Timer?
    private var tickerTimer: Timer?
    private var storageServiceObserver: AnyCancellable?
    private var symbolsObserver: AnyCancellable?
    private lazy var alertMonitor: AlertMonitor = {
        let monitor = AlertMonitor(storage: storageService)
        monitor.history = { [weak stockService] symbol in
            let svc = stockService
            // Choose the longest daily series available for the rolling average.
            return svc?.priceHistoryMax[symbol] ?? svc?.priceHistory[symbol] ?? []
        }
        return monitor
    }()
    private lazy var portfolioMonitor = PortfolioMonitor(storage: storageService, stockService: stockService)
    let updaterViewModel = UpdaterViewModel()

    /// REST polling: quotes + exchange rates as WSS fallback
    private static let restPollingInterval: TimeInterval = 60
    /// How often to auto-sync Binance-linked portfolios (every 10 minutes, 24/7
    /// so crypto balances stay fresh without a manual "Sync Binance Now" tap).
    private static let binanceAutoSyncInterval: TimeInterval = 600
    private var lastBinanceAutoSync: Date?

    /// Set the UN delegate before launch finishes so a notification response
    /// delivered while the app is cold-launching (click on a delivered banner)
    /// is captured instead of being dropped.
    func applicationWillFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        FontRegistration.registerFonts()

        if let url = Bundle.module.url(forResource: "AppIcon", withExtension: "icns"),
           let img = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = img
        }

        // Ask for notification permission (no-op in dev without a bundle)
        NotificationManager.shared.requestAuthorization()
        iCloudSyncService.shared.start()

        // Cold launch from clicking a delivered notification: the system already
        // routed the response to the delegate (set in willFinishLaunching); the
        // `.didBecomeActive` observer below is the LSUIElement fallback in case
        // macOS swallowed the didReceive callback on the banner click.
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleBecameActive),
            name: NSApplication.didBecomeActiveNotification, object: nil)

        // Menu-bar-only by default; opening the desktop window temporarily
        // promotes the app to a regular application.
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // macOS 26 tracks a status item's menu-bar visibility in the app's own
        // defaults under "NSStatusItem VisibleCC <autosaveName>". A freshly
        // created item is hidden from the menu bar until that key is set, so a
        // brand-new identity (new bundle ID / autosave name) shows nothing. Write
        // the key once when absent so the item appears by default; the user can
        // still hide it later from Control Center.
        let statusItemName = "StockDeck.MainStatusItem.v5"
        let statusItemVisibleKey = "NSStatusItem VisibleCC \(statusItemName)"
        UserDefaults.standard.set(true, forKey: statusItemVisibleKey)
        statusItem?.autosaveName = statusItemName
        statusItem?.isVisible = true

        if let button = statusItem?.button {
            button.image = menuBarImage
            if button.image == nil {
                button.title = " SD"
            }
            button.action = #selector(togglePopover)
            button.target = self
        }

        let p = NSPopover()
        p.contentSize = NSSize(width: 462, height: 520)
        p.behavior = .transient
        p.delegate = self
        // Appearance follows the user's preference (issue #11), applied reactively
        // via `.preferredColorScheme` on the SwiftUI root — not pinned here.
        popover = p
        storageService.onHotKeyTriggered = { [weak self] in
            if let front = NSWorkspace.shared.frontmostApplication,
               front.processIdentifier != ProcessInfo.processInfo.processIdentifier,
               front.activationPolicy == .regular {
                self?.lastActiveApplication = front
            }
            self?.togglePopover()
        }
        storageService.onDesktopHotKeyTriggered = { [weak self] in
            self?.toggleDesktopApp()
        }
        storageService.updateHotKeyRegistration()

        let start = Date()
        refreshStartedAt = start
        refreshTask = Task {
            // Compare-and-clear: only clear if a newer refresh hasn't superseded
            // us, so a cancelled Task's defer can't unblock a live refresh.
            defer { if self.refreshStartedAt == start { self.refreshStartedAt = nil } }

            // Phase 1: WebSocket first (realtime ticks), then critical watchlist
            // quotes so the menu bar shows a value immediately.
            startWebSocket()
            guard !Task.isCancelled else { return }
            await stockService.refreshCritical(storageService: storageService)
            guard !Task.isCancelled else { return }
            updateMenuBarTitle()

            // Phase 2: full portfolio quotes + exchange rates, non-blocking
            await self.autoSyncBinancePortfolios()
            guard !Task.isCancelled else { return }
            await stockService.refreshAll(storageService: storageService)
            guard !Task.isCancelled else { return }
            updateMenuBarTitle()
            await self.ensureMAAlertHistory()
            alertMonitor.check(quotes: stockService.quotes)
            portfolioMonitor.check()
            recordSnapshots()
        }

        // REST polling at low frequency for exchange rates and as WSS fallback
        scheduleRESTPolling()

        // Dev affordance: open the Portfolio window on launch for screenshots/testing.
        // Only when explicitly set to "1" — a bare env var or "0" must NOT open it.
        if ProcessInfo.processInfo.environment["SD_OPEN_WINDOW"] == "1" {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                guard !(self.popover?.isShown ?? false) else { return }
                self.showPortfolioWindow()
            }
        }

        // Pause on system sleep, resume on wake
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(handleSleep),
            name: NSWorkspace.willSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(handleWake),
            name: NSWorkspace.didWakeNotification, object: nil)

        // Update menu bar when popover closes (user may have changed holdings/settings)
        NotificationCenter.default.addObserver(
            self, selector: #selector(handlePopoverClosed),
            name: .popoverDidClose, object: nil)

        // Observe StorageService changes (portfolio edits, display mode, currency, etc.)
        storageServiceObserver = storageService.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in
                self?.invalidateMenuBarStats()
                self?.updateMenuBarTitle()
            }
        }

        symbolsObserver = storageService.$portfolios
            .combineLatest(storageService.$watchlists)
            .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
            .sink { [weak self] _, _ in
                guard let self else { return }
                let symbols = Array(self.collectSymbols())
                guard !symbols.isEmpty else { return }
                self.webSocketService.updateSymbols(Array(StockService.collectWebSocketSymbols(storageService: self.storageService)))
                self.refreshTask?.cancel()
                let start = Date()
                self.refreshStartedAt = start
                self.refreshTask = Task { @MainActor in
                    defer { if self.refreshStartedAt == start { self.refreshStartedAt = nil } }
                    await self.stockService.refreshAll(storageService: self.storageService)
                    self.updateMenuBarTitle()
                    await self.ensureMAAlertHistory()
                    self.alertMonitor.check(quotes: self.stockService.quotes)
                    self.portfolioMonitor.check()
                    self.recordSnapshots()
                }
            }
    }

    func applicationWillTerminate(_ notification: Notification) {
        storageService.saveNow()
        timer?.invalidate()
        timer = nil
        tickBatchTimer?.invalidate()
        tickBatchTimer = nil
        tickerTimer?.invalidate()
        tickerTimer = nil
        webSocketService.disconnect()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - WebSocket

    /// Ensures daily price history is loaded for every MA-based alert so the
    /// cross evaluation has data to compute the rolling average.
    private func ensureMAAlertHistory() async {
        for alert in storageService.alerts where alert.condition.movingAverage != nil {
            await stockService.ensurePriceHistory(for: alert.symbol)
        }
    }

    private func startWebSocket() {
        let symbols = StockService.collectWebSocketSymbols(storageService: storageService)
        guard !symbols.isEmpty else { return }

        webSocketService.onTick = { [weak self] ticker in
            guard let self else { return }
            self.pendingTicks.append(ticker)
            self.scheduleTickFlush()
        }

        webSocketService.connect(symbols: Array(symbols))
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
            invalidateMenuBarStats()
            updateMenuBarTitle()
            alertMonitor.check(quotes: stockService.quotes)
            portfolioMonitor.check()
        }
    }

    /// Captures a daily value/P&L snapshot per portfolio from the current quotes,
    /// for the Portfolio window's history chart. Skips a portfolio until every
    /// holding has a quote, so a partially-loaded feed can't record an understated
    /// value. `StorageService.recordSnapshot` keeps one entry per day.
    private func recordSnapshots() {
        for portfolio in storageService.portfolios {
            guard !portfolio.holdings.isEmpty else { continue }
            let inputs = PortfolioValuation.resolveInputs(for: [portfolio], stockService: stockService, storageService: storageService)
            let totals = PortfolioValuation.totals(inputs)
            storageService.recordSnapshot(for: portfolio.id, totalValue: totals.value, totalCost: totals.cost)
        }
    }

    private func collectSymbols() -> Set<String> {
        StockService.collectSymbols(storageService: storageService)
    }


    // MARK: - Ticker Cycling

    private func startTickerTimer() {
        guard tickerTimer == nil else { return }
        tickerTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.tickerIndex += 1
                self.updateMenuBarTitle()
            }
        }
    }

    private func stopTickerTimer() {
        tickerTimer?.invalidate()
        tickerTimer = nil
        tickerIndex = 0
    }

    // MARK: - REST Polling (exchange rates + fallback)

    private func scheduleRESTPolling() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.restPollingInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.isRefreshing else { return }
                let start = Date()
                self.refreshStartedAt = start
                defer { if self.refreshStartedAt == start { self.refreshStartedAt = nil } }
                let symbols = Array(StockService.collectSymbols(storageService: self.storageService))
                await self.stockService.fetchQuotes(symbols: symbols)
                await self.stockService.refreshExchangeRates(storageService: self.storageService)
                self.invalidateMenuBarStats()
                self.updateMenuBarTitle()
                await self.ensureMAAlertHistory()
                self.alertMonitor.check(quotes: self.stockService.quotes)
                self.portfolioMonitor.check()
                self.recordSnapshots()
                // Auto-sync Binance portfolios every 10 minutes so non-WSS crypto
                // balances (funding, margin, futures, earn) stay fresh.
                await self.autoSyncBinancePortfolios()
                // Supervisor: revive the WebSocket if it silently died, otherwise
                // just keep its subscriptions current.
                self.webSocketService.ensureConnected(symbols: Array(StockService.collectWebSocketSymbols(storageService: self.storageService)))
            }
        }
    }

    /// Periodically re-fetches Binance holdings so a portfolio edited on the
    /// Binance app (buy/sell/stake) is reflected in StockDeck without a manual
    /// "Sync Binance Now" tap. Throttled to once per `binanceAutoSyncInterval`.
    private func autoSyncBinancePortfolios() async {
        let now = Date()
        if let last = lastBinanceAutoSync,
           now.timeIntervalSince(last) < Self.binanceAutoSyncInterval {
            return
        }
        let binancePortfolios = storageService.portfolios.filter { $0.isReadOnly }
        guard !binancePortfolios.isEmpty else { return }
        lastBinanceAutoSync = now

        for portfolio in binancePortfolios {
            do {
                try await storageService.syncBinancePortfolio(id: portfolio.id)
            } catch {
                print("[StockDeck] Binance auto-sync failed for \(portfolio.name): \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Sleep / Wake

    @objc private func handleSleep() {
        timer?.invalidate()
        timer = nil
        tickBatchTimer?.invalidate()
        tickBatchTimer = nil
        refreshTask?.cancel()
        refreshTask = nil
        refreshStartedAt = nil
        tickerTimer?.invalidate()
        tickerTimer = nil
        pendingTicks.removeAll()
        webSocketService.disconnect()
    }

    @objc private func handleWake() {
        refreshTask?.cancel()
        refreshTask = Task {
            let start = Date()
            refreshStartedAt = start
            defer { if refreshStartedAt == start { refreshStartedAt = nil } }
            await autoSyncBinancePortfolios()
            guard !Task.isCancelled else { return }
            await stockService.refreshAll(storageService: storageService)
            guard !Task.isCancelled else { return }
            updateMenuBarTitle()
            startWebSocket()
        }
        scheduleRESTPolling()
    }

    private var menuBarFontSize: CGFloat {
        CGFloat(storageService.fontSizeLevel) + 5
    }

    /// Renders one watchlist slide for the menu bar ticker. Applies issue #8.2
    /// (show name vs symbol) and #8.3 (no currency symbol for indices).
    private func watchlistSlide(symbol: String, upColor: NSColor, downColor: NSColor) -> (title: String, color: NSColor) {
        guard let quote = stockService.quotes[symbol] else {
            return (" \(symbol)", .secondaryLabelColor)
        }
        // #8.2: prefer the readable name when the user opted in and it's available.
        // Indices, FX pairs, and futures always use their conventional display
        // name ("^N225" → "Nikkei 225", "EURUSD=X" → "EUR/USD", "GC=F" → "Gold
        // Futures"). Single stocks / ETFs keep the raw ticker by default.
        let label: String
        if StockService.isDisplayNameAsset(quote.symbol) {
            label = quote.displayName
        } else if storageService.tickerShowName && !quote.name.isEmpty {
            label = quote.name
        } else {
            label = quote.symbol
        }
        let sign = quote.changePercent >= 0 ? "+" : ""
        let priceValue = quote.displayPrice(extendedHours: storageService.showExtendedHours)
        let price = StorageService.formatNumber(priceValue, decimals: storageService.resolvedPriceDecimals(symbol: quote.symbol, price: priceValue))
        // Issue #10: optionally drop the percentage from the menu-bar ticker.
        let pctPart = storageService.menuBarHidePercent
            ? ""
            : " \(sign)\(String(format: "%.\(storageService.percentDecimals)f", quote.changePercent))%"
        let title = " \(label) \(price)\(pctPart)"
        return (title, quote.changePercent >= 0 ? upColor : downColor)
    }

    private struct MenuBarStatsCache {
        let totalValue: Double
        let totalCost: Double
        let totalPnl: Double
        let totalPnlPct: Double
        let todayGain: Double
        let todayPct: Double
        let bestStock: StockQuote?
        let worstStock: StockQuote?
    }

    private var cachedMenuBarStats: MenuBarStatsCache? = nil

    private func invalidateMenuBarStats() {
        cachedMenuBarStats = nil
    }

    private func updateMenuBarTitle() {
        let displayMode = storageService.menuBarDisplay

        if displayMode == "ticker" || displayMode == "tickerPortfolio" {
            if tickerTimer == nil { startTickerTimer() }
        } else {
            stopTickerTimer()
        }

        // Icon only
        if displayMode == "icon" {
            statusItem?.button?.attributedTitle = NSAttributedString(string: "")
            let button = statusItem?.button
            let image = menuBarImage
            button?.image = image
            button?.title = image == nil ? " SD" : ""
            statusItem?.isVisible = true
            return
        }

        let stats: MenuBarStatsCache
        if let cached = cachedMenuBarStats {
            stats = cached
        } else {
            let inputs = PortfolioValuation.resolveInputs(for: storageService.portfolios, stockService: stockService, storageService: storageService)
            let totals = PortfolioValuation.totals(inputs)
            let totalVal = totals.value
            let totalCst = totals.cost
            let pnl = totals.pnl
            let pnlPct = abs(totalCst) >= 0.01 ? (pnl / abs(totalCst)) * 100 : 0

            let todayInputs = storageService.portfolios.flatMap(\.holdings).compactMap { holding -> TodayPerformance.Input? in
                guard let quote = stockService.quotes[holding.symbol] else { return nil }
                let isCrypto = storageService.type(for: holding.symbol) == "CRYPTOCURRENCY" || HomeAIInsightService.cryptoBaseAsset(for: holding.symbol) != nil
                let isMarketActive = MarketCategory.isTradingDay(symbol: holding.symbol, quote: quote, isCrypto: isCrypto)
                return TodayPerformance.Input(
                    holding: holding,
                    regularPrice: quote.price,
                    previousClose: quote.previousClose,
                    rate: stockService.rate(from: quote.currency),
                    isMarketActiveToday: isMarketActive
                )
            }
            let today = TodayPerformance.totals(todayInputs)

            let best = storageService.watchlist.compactMap { stockService.quotes[$0] }
                .max(by: { $0.changePercent < $1.changePercent })
            let worst = storageService.watchlist.compactMap { stockService.quotes[$0] }
                .min(by: { $0.changePercent < $1.changePercent })

            let computed = MenuBarStatsCache(
                totalValue: totalVal,
                totalCost: totalCst,
                totalPnl: pnl,
                totalPnlPct: pnlPct,
                todayGain: today.gain,
                todayPct: today.percent,
                bestStock: best,
                worstStock: worst
            )
            cachedMenuBarStats = computed
            stats = computed
        }

        let totalValue = stats.totalValue
        let totalCost = stats.totalCost
        let totalPnl = stats.totalPnl
        let totalPnlPct = stats.totalPnlPct
        let todayGain = stats.todayGain
        let todayPct = stats.todayPct
        let bestStock = stats.bestStock
        let worstStock = stats.worstStock

        let currSymbol = StorageService.currencySymbol(for: storageService.preferredCurrency)
        let title: String
        let color: NSColor

        // Issue #7.1: customizable gain/loss colors.
        let upColor: NSColor = storageService.gainColor
        let downColor: NSColor = storageService.lossColor

        switch displayMode {
        case "todayPnl":
            if totalCost < 0.01 {
                title = " —"
                color = .secondaryLabelColor
            } else {
                title = " Today \(StorageService.formatAmount(todayGain, symbol: currSymbol, decimals: storageService.amountDecimals, signed: true))"
                color = todayGain >= 0 ? upColor : downColor
            }

        case "todayPnlFull":
            if totalCost < 0.01 {
                title = " —"
                color = .secondaryLabelColor
            } else {
                let todayPctSign = todayPct >= 0 ? "+" : ""
                let todayPctPart = storageService.menuBarHidePercent ? "" : " (\(todayPctSign)\(String(format: "%.\(storageService.percentDecimals)f", todayPct))%)"
                title = " Today \(StorageService.formatAmount(todayGain, symbol: currSymbol, decimals: storageService.amountDecimals, signed: true))\(todayPctPart)"
                color = todayGain >= 0 ? upColor : downColor
            }

        case "totalValue":
            title = " \(StorageService.formatAmount(totalValue, symbol: currSymbol, decimals: storageService.amountDecimals))"
            color = totalPnl >= 0 ? upColor : downColor

        case "pnlPercent":
            if totalCost < 0.01 {
                title = " —"
                color = .secondaryLabelColor
            } else {
                let sign = totalPnlPct >= 0 ? "+" : ""
                title = " PnL \(sign)\(String(format: "%.\(storageService.percentDecimals)f", totalPnlPct))%"
                color = totalPnlPct >= 0 ? upColor : downColor
            }

        case "pnlFull":
            if totalCost < 0.01 {
                title = " —"
                color = .secondaryLabelColor
            } else {
                let pctSign = totalPnlPct >= 0 ? "+" : ""
                let pctPart = storageService.menuBarHidePercent ? "" : " (\(pctSign)\(String(format: "%.\(storageService.percentDecimals)f", totalPnlPct))%)"
                title = " \(StorageService.formatAmount(totalPnl, symbol: currSymbol, decimals: storageService.amountDecimals, signed: true))\(pctPart)"
                color = totalPnl >= 0 ? upColor : downColor
            }

        case "bestStock":
            if let best = bestStock {
                let sign = best.changePercent >= 0 ? "+" : ""
                title = " \(best.displayName) \(sign)\(String(format: "%.\(storageService.percentDecimals)f", best.changePercent))%"
                color = best.changePercent >= 0 ? upColor : downColor
            } else {
                title = " --"
                color = .secondaryLabelColor
            }

        case "worstStock":
            if let worst = worstStock {
                let sign = worst.changePercent >= 0 ? "+" : ""
                title = " \(worst.displayName) \(sign)\(String(format: "%.\(storageService.percentDecimals)f", worst.changePercent))%"
                color = worst.changePercent >= 0 ? upColor : downColor
            } else {
                title = " --"
                color = .secondaryLabelColor
            }

        case "bestWorst":
            if let best = bestStock, let worst = worstStock, best.symbol != worst.symbol {
                let bSign = best.changePercent >= 0 ? "+" : ""
                let wSign = worst.changePercent >= 0 ? "+" : ""
                title = " ▲\(best.displayName) \(bSign)\(String(format: "%.\(storageService.percentDecimals)f", best.changePercent))%  ▼\(worst.displayName) \(wSign)\(String(format: "%.\(storageService.percentDecimals)f", worst.changePercent))%"
                color = .labelColor
            } else if let best = bestStock {
                let sign = best.changePercent >= 0 ? "+" : ""
                title = " \(best.displayName) \(sign)\(String(format: "%.\(storageService.percentDecimals)f", best.changePercent))%"
                color = best.changePercent >= 0 ? upColor : downColor
            } else {
                title = " --"
                color = .secondaryLabelColor
            }

        case "portfolioRecap":
            let sign = totalPnlPct >= 0 ? "+" : ""
            let pctPart = storageService.menuBarHidePercent ? "" : " \(sign)\(String(format: "%.\(storageService.percentDecimals)f", totalPnlPct))%"
            title = " \(StorageService.formatAmount(totalValue, symbol: currSymbol, decimals: storageService.amountDecimals))\(pctPart)"
            color = totalPnl >= 0 ? upColor : downColor

        case "ticker":
            // #8.1: cycle in the user-selected order (as added / by type / alphabetical).
            let symbols = StorageService.tickerOrder(storageService.watchlist, mode: storageService.watchlistSort, types: storageService.symbolType)
            if symbols.isEmpty {
                title = " --"
                color = .secondaryLabelColor
            } else {
                let symbol = symbols[tickerIndex % symbols.count]
                (title, color) = watchlistSlide(symbol: symbol, upColor: upColor, downColor: downColor)
            }

        case "tickerPortfolio":
            // Issue #7.3: cycle through the watchlist AND a portfolio recap slide.
            let symbols = StorageService.tickerOrder(storageService.watchlist, mode: storageService.watchlistSort, types: storageService.symbolType)
            let hasPortfolio = storageService.portfolios.contains { !$0.holdings.isEmpty }
            let slideCount = symbols.count + (hasPortfolio ? 1 : 0)
            if slideCount == 0 {
                title = " --"
                color = .secondaryLabelColor
            } else {
                let index = tickerIndex % slideCount
                if index < symbols.count {
                    // Watchlist slide (same rendering as the "ticker" mode)
                    (title, color) = watchlistSlide(symbol: symbols[index], upColor: upColor, downColor: downColor)
                } else {
                    // Portfolio recap slide
                    let sign = totalPnlPct >= 0 ? "+" : ""
                    title = " \(StorageService.formatAmount(totalValue, symbol: currSymbol, decimals: storageService.amountDecimals)) \(sign)\(String(format: "%.\(storageService.percentDecimals)f", totalPnlPct))%"
                    color = totalPnl >= 0 ? upColor : downColor
                }
            }

        default: // "pnl"
            title = " PnL \(StorageService.formatAmount(totalPnl, symbol: currSymbol, decimals: storageService.amountDecimals, signed: true))"
            color = totalPnl >= 0 ? upColor : downColor
        }

        statusItem?.button?.image = nil
        statusItem?.button?.title = title

        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: color,
            .font: FontRegistration.monospacedDigitsFont(size: menuBarFontSize, weight: .medium)
        ]
        statusItem?.button?.attributedTitle = NSAttributedString(string: title, attributes: attrs)
    }

    @objc private func handlePopoverClosed() {
        updateMenuBarTitle()
        // Update WSS subscriptions in case symbols changed
        webSocketService.updateSymbols(Array(StockService.collectWebSocketSymbols(storageService: self.storageService)))
    }

    private var menuBarImage: NSImage? {
        if let url = Bundle.main.url(forResource: "MenuBarIcon", withExtension: "png") ??
                     Bundle.module.url(forResource: "MenuBarIcon", withExtension: "png") ??
                     Bundle.main.url(forResource: "AppIcon", withExtension: "png") ??
                     Bundle.module.url(forResource: "AppIcon", withExtension: "png") ??
                     Bundle.main.url(forResource: "AppLogo", withExtension: "png") ??
                     Bundle.module.url(forResource: "AppLogo", withExtension: "png"),
           let src = NSImage(contentsOf: url) {
            let targetSize = NSSize(width: 18, height: 18)
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: 36,
                pixelsHigh: 36,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 36 * 4,
                bitsPerPixel: 32
            )
            if let rep {
                rep.size = targetSize
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                src.draw(in: NSRect(x: 0, y: 0, width: 18, height: 18),
                         from: NSRect(x: 0, y: 0, width: src.size.width, height: src.size.height),
                         operation: .copy, fraction: 1.0)
                NSGraphicsContext.restoreGraphicsState()

                let icon = NSImage(size: targetSize)
                icon.addRepresentation(rep)
                return icon
            }
        }
        return NSImage(systemSymbolName: "chart.line.uptrend.xyaxis", accessibilityDescription: "StockDeck")
    }

    @objc func togglePopover() {
        guard let button = statusItem?.button, let popover else { return }
        if popover.isShown {
            closePopover()
        } else {
            if let front = NSWorkspace.shared.frontmostApplication,
               front.processIdentifier != ProcessInfo.processInfo.processIdentifier,
               front.activationPolicy == .regular {
                lastActiveApplication = front
            }
            if popover.contentViewController == nil {
                let contentView = ContentView()
                    .environmentObject(stockService)
                    .environmentObject(storageService)
                    .environmentObject(updaterViewModel)
                    .environment(\.openWindowAction, { [weak self] in self?.showPortfolioWindow() })
                popover.contentViewController = NSHostingController(rootView: contentView)
            }
            let rect = NSRect(x: 0, y: 0, width: button.bounds.width, height: 0)
            popover.show(relativeTo: rect, of: button, preferredEdge: .minY)
            let hasDesktopWindow = (portfolioWindow?.isVisible ?? false) || NSApp.windows.contains {
                $0.isVisible && $0.className != "_NSPopoverWindow"
            }
            if !hasDesktopWindow {
                NSApp.activate(ignoringOtherApps: true)
            }
            if let window = popover.contentViewController?.view.window {
                window.makeKey()
            }
            eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                self?.closePopover()
            }
        }
    }

    private func closePopover() {
        popover?.performClose(nil)
    }

    // MARK: - Portfolio Window

    /// Opens (or focuses) the full navigable Portfolio window. The menu-bar glance
    /// stays put; this is the "expanded" surface over the same shared state. While
    /// the window is up the app shows a Dock icon (regular policy) so it behaves
    /// like a normal app; closing it returns to accessory (menu-bar-only) mode.
    /// Opens (or focuses) the desktop window, then posts `.stockDeckAlertTapped`
    /// so the Portfolio window switches to its Alerts tab.
    func openWindowToAlerts() {
        showPortfolioWindow()
        // Wait until the window is on screen before asking it to navigate; the
        // observer in PortfolioWindowView handles the timing.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            _ = self
            NotificationCenter.default.post(name: .stockDeckAlertTapped, object: nil)
        }
    }

    @objc private func handleBecameActive() {
        // LSUIElement (menu-bar) apps can lose the `didReceive` callback when a
        // banner is clicked. Fallback: whenever we just became active, if a
        // delivered alert notification is still pending on the Notification
        // Center, treat it as a click on that alert — but only when the user
        // did NOT just open the menu-bar popover (a real banner click never
        // opens the popover, so that's our discriminator).
        let now = Date()
        guard now.timeIntervalSince(lastAlertActivationAt) > 2 else { return }
        guard !(popover?.isShown ?? false) else { return }
        UNUserNotificationCenter.current().getDeliveredNotifications { [weak self] delivered in
            Task { @MainActor in
                guard let self else { return }
                guard !(self.popover?.isShown ?? false) else { return }
                guard let pending = delivered.first(where: {
                    now.timeIntervalSince($0.date) < 120 && !$0.request.content.title.isEmpty
                }) else { return }
                self.lastAlertActivationAt = now
                self.openWindowToAlerts()
                UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [pending.request.identifier])
            }
        }
    }

    @objc func toggleDesktopApp() {
        if let window = portfolioWindow, window.isVisible, NSApp.isActive && window.isKeyWindow {
            window.performClose(nil)
        } else {
            showPortfolioWindow()
        }
    }

    @objc func showPortfolioWindow() {
        if lastActiveApplication == nil || lastActiveApplication?.isTerminated == true {
            if let front = NSWorkspace.shared.frontmostApplication,
               front.processIdentifier != ProcessInfo.processInfo.processIdentifier,
               front.activationPolicy == .regular {
                lastActiveApplication = front
            }
        }
        let reusable = portfolioWindow?.isVisible ?? false
        NSLog("[StockDeck] Open clicked — \(reusable ? "focusing existing window" : "creating new window")")
        isPresentingPortfolioWindow = true
        _ = NSApp.setActivationPolicy(.regular)
        if let url = Bundle.module.url(forResource: "AppIcon", withExtension: "icns"),
           let img = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = img
        }
        closePopover()
        // Reuse the window only while it's actually on screen. Once closed with
        // the red button it's ordered out (and not reliably re-showable), so we
        // drop it and build a fresh one — otherwise "Open" would silently no-op.
        if let window = portfolioWindow, window.isVisible {
            bringWindowFront(window)
            return
        }
        portfolioWindow = nil

        let root = PortfolioWindowView()
            .environmentObject(stockService)
            .environmentObject(storageService)
            .environmentObject(updaterViewModel)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1220, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "StockDeck"
        // One uninterrupted surface: transparent titlebar, no system title text
        // (the sidebar brand is the title), only floating traffic lights.
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = false
        window.minSize = NSSize(width: 1000, height: 680)
        // Appearance follows the user's preference (issue #11), applied reactively
        // via `.preferredColorScheme` on the SwiftUI root — not pinned here.
        window.contentViewController = NSHostingController(rootView: root)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setFrameAutosaveName("StockDeckPortfolioWindow")
        window.center()
        portfolioWindow = window

        bringWindowFront(window)
    }

    /// Brings the desktop window reliably in front of every other app and ensures
    /// it assumes frontmost priority in the Cmd+Tab (App Switcher) MRU order.
    private func bringWindowFront(_ window: NSWindow) {
        portfolioActivationGeneration += 1
        let generation = portfolioActivationGeneration

        _ = NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)

        // Focus bounce: Yield focus briefly to the previous active regular application (or Finder)
        // so Dock.app registers StockDeck's promotion to a regular app. When StockDeck re-activates
        // after a 100ms tick, macOS fires a genuine "Frontmost Application Changed" event,
        // placing StockDeck at index 0 and the previous app at index 1 of the Cmd+Tab stack.
        let targetApp = (lastActiveApplication?.isTerminated == false ? lastActiveApplication : nil)
            ?? NSWorkspace.shared.runningApplications.first(where: {
                $0.activationPolicy == .regular &&
                $0.processIdentifier != ProcessInfo.processInfo.processIdentifier &&
                !$0.isHidden
            })

        targetApp?.activate(options: [])

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self, weak window] in
            guard let self, let window,
                  generation == self.portfolioActivationGeneration,
                  window === self.portfolioWindow,
                  window.isVisible else { return }

            NSApp.activate(ignoringOtherApps: true)
            _ = NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            window.makeKeyAndOrderFront(nil)
            self.isPresentingPortfolioWindow = false
            NSLog("[StockDeck] window shown — active=\(NSApp.isActive) visible=\(window.isVisible) key=\(window.isKeyWindow) frame=\(NSStringFromRect(window.frame))")
        }
    }
}

// MARK: - UNUserNotificationCenterDelegate
// Clicking a delivered alert notification opens (or focuses) the desktop
// window and navigates it to the Alerts tab.

extension AppDelegate: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        Task { @MainActor in
            self.openWindowToAlerts()
            completionHandler()
        }
    }
}

// MARK: - NSWindowDelegate

extension AppDelegate: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === portfolioWindow else { return }
        portfolioActivationGeneration += 1
        isPresentingPortfolioWindow = false
        Task { @MainActor in
            if !(popover?.isShown ?? false) { NSApp.setActivationPolicy(.accessory) }
        }
    }
}

// MARK: - NSPopoverDelegate

extension AppDelegate: NSPopoverDelegate {
    func popoverDidClose(_ notification: Notification) {
        CursorManager.reset()
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
        let hasDesktopWindow = NSApp.windows.contains {
            $0.isVisible && $0.className != "_NSPopoverWindow"
        }
        if !isPresentingPortfolioWindow && !hasDesktopWindow {
            NSApp.setActivationPolicy(.accessory)
        }
        NotificationCenter.default.post(name: .popoverDidClose, object: nil)
    }
}
