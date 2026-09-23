import Foundation
import AppKit
import ServiceManagement

struct Watchlist: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String
    var symbols: [String]
    /// Nil keeps imported/older watchlists on the default layout.
    var metrics: [WatchlistMetric]? = nil
    var sortKey: String? = nil
    var sortAsc: Bool? = nil

    enum CodingKeys: String, CodingKey {
        case id, name, symbols, metrics, sortKey, sortAsc
    }

    init(id: UUID = UUID(), name: String, symbols: [String], metrics: [WatchlistMetric]? = nil, sortKey: String? = nil, sortAsc: Bool? = nil) {
        self.id = id
        self.name = name
        self.symbols = symbols
        self.metrics = metrics
        self.sortKey = sortKey
        self.sortAsc = sortAsc
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.name = try container.decode(String.self, forKey: .name)
        self.symbols = try container.decode([String].self, forKey: .symbols)
        if let rawMetrics = try container.decodeIfPresent([String].self, forKey: .metrics) {
            let decoded = rawMetrics.compactMap(WatchlistMetric.init(rawValue:))
            self.metrics = decoded.isEmpty ? nil : decoded
        } else {
            self.metrics = nil
        }
        self.sortKey = try container.decodeIfPresent(String.self, forKey: .sortKey)
        self.sortAsc = try container.decodeIfPresent(Bool.self, forKey: .sortAsc)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(symbols, forKey: .symbols)
        try container.encodeIfPresent(metrics?.map(\.rawValue), forKey: .metrics)
        try container.encodeIfPresent(sortKey, forKey: .sortKey)
        try container.encodeIfPresent(sortAsc, forKey: .sortAsc)
    }
}

/// Where a dragged item lands relative to its drop target: before it, or after
/// it (the lower/right half of the target — which lets an item reach the end of
/// a list, since there is no drop zone beyond the last row).
enum InsertPlacement {
    case before
    case after
}

@MainActor
class StorageService: ObservableObject {
    static let shared = StorageService()

    @Published var watchlists: [Watchlist] = [] {
        didSet { scheduleSave() }
    }

    @Published var selectedWatchlistId: UUID? = nil {
        didSet { scheduleSave() }
    }

    /// The currently selected watchlist object (falls back to first watchlist)
    var currentWatchlist: Watchlist {
        if let id = selectedWatchlistId, let wl = watchlists.first(where: { $0.id == id }) {
            return wl
        }
        if let first = watchlists.first { return first }
        let def = Watchlist(id: UUID(), name: "Watchlist", symbols: [])
        return def
    }

    /// Symbols in the active watchlist (backward-compatible API)
    var watchlist: [String] {
        get { currentWatchlist.symbols }
        set {
            let activeId = currentWatchlist.id
            if let idx = watchlists.firstIndex(where: { $0.id == activeId }) {
                watchlists[idx].symbols = newValue
            } else if !watchlists.isEmpty {
                watchlists[0].symbols = newValue
            } else {
                let newWl = Watchlist(id: activeId, name: "Watchlist", symbols: newValue)
                watchlists = [newWl]
                selectedWatchlistId = newWl.id
            }
        }
    }

    /// All watchlists share a unified metric layout across the app.
    var watchlistMetrics: [WatchlistMetric] {
        (currentWatchlist.metrics ?? WatchlistMetric.defaultSelection).filter { $0 != .today && $0 != .price }
    }

    func setWatchlistMetrics(_ metrics: [WatchlistMetric]) {
        objectWillChange.send()
        let cleaned = metrics.filter { $0 != .today && $0 != .price }
        var updated = watchlists
        for index in updated.indices {
            updated[index].metrics = cleaned
        }
        watchlists = updated
    }

    // MARK: - Portfolio columns customization

    /// Optional columns in the portfolio positions table. Rank (#) and Symbol
    /// stay fixed; this list controls the investment metrics that follow them.
    /// Nil keeps older installs on the default layout.
    @Published var portfolioColumns: [PortfolioColumnMetric]? = nil {
        didSet { scheduleSave() }
    }

    var resolvedPortfolioColumns: [PortfolioColumnMetric] {
        portfolioColumns ?? PortfolioColumnMetric.defaultSelection
    }

    func setPortfolioColumns(_ columns: [PortfolioColumnMetric]) {
        objectWillChange.send()
        portfolioColumns = columns
    }

    @Published var portfolios: [Portfolio] = [] {
        didSet { scheduleSave() }
    }

    @Published var preferredCurrency: String = "EUR" {
        didSet { scheduleSave() }
    }

    @Published var stockPriceCurrency: String = "" {
        didSet { scheduleSave() }
    }

    @Published var showExtendedHours: Bool = true {
        didSet { scheduleSave() }
    }

    // MARK: - Watchlist row display toggles
    @Published var showCompanyName: Bool = true {
        didSet { scheduleSave() }
    }
    @Published var showWatchlistSparkline: Bool = true {
        didSet { scheduleSave() }
    }
    @Published var showDayRange: Bool = true {
        didSet { scheduleSave() }
    }
    @Published var show52WeekBar: Bool = true {
        didSet { scheduleSave() }
    }
    @Published var showAbsoluteChange: Bool = false {
        didSet { scheduleSave() }
    }
    @Published var showInsiderMarkers: Bool = true {
        didSet { scheduleSave() }
    }

    // MARK: - Appearance & tabs (issue #11)
    /// "system" | "light" | "dark". The 1.9.0 redesign forced light; this restores
    /// the choice. Read through `appearanceMode` for the typed value.
    @Published var appearanceRaw: String = AppearanceMode.default.rawValue {
        didSet { scheduleSave() }
    }

    // MARK: - Launch at Login (macOS)
    /// Whether the app is configured to automatically launch at system login.
    @Published var launchAtLogin: Bool = false {
        didSet {
            guard !isLoading else { return }
            updateLaunchAtLogin(launchAtLogin)
        }
    }

    /// Sync the in-memory setting with the actual macOS system registration status.
    func syncLaunchAtLoginStatus() {
        let isEnabled = (SMAppService.mainApp.status == .enabled)
        if launchAtLogin != isEnabled {
            launchAtLogin = isEnabled
        }
    }

    /// Register or unregister the app from macOS Login Items.
    private func updateLaunchAtLogin(_ enabled: Bool) {
        let currentStatus = SMAppService.mainApp.status
        do {
            if enabled {
                if currentStatus != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if currentStatus == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
        } catch {
            NSLog("[StorageService] Failed to set launch at login: %@", error.localizedDescription)
            let actualStatus = (SMAppService.mainApp.status == .enabled)
            if launchAtLogin != actualStatus {
                launchAtLogin = actualStatus
            }
        }
    }

    private var isSharedInstance: Bool {
        !isCustomStorage
    }

    // MARK: - iCloud Sync
    @Published var iCloudSyncEnabled: Bool = false {
        didSet {
            scheduleSave()
            if isSharedInstance && !isLoading {
                iCloudSyncService.shared.onSyncToggleChanged(enabled: iCloudSyncEnabled)
            }
        }
    }
    @Published var lastiCloudSyncDate: Date? = nil

    /// Typed appearance preference, tolerant of unknown persisted values.
    var appearanceMode: AppearanceMode {
        get { AppearanceMode(rawValue: appearanceRaw) ?? .default }
        set { appearanceRaw = newValue.rawValue }
    }

    /// What to display in the menu bar (for example "pnl", "todayPnlFull",
    /// "totalValue", or "icon").
    @Published var menuBarDisplay: String = "pnl" {
        didSet { scheduleSave() }
    }

    /// Direct callback for when menu bar hotkey triggers.
    var onHotKeyTriggered: (() -> Void)?
    /// Direct callback for when desktop app hotkey triggers.
    var onDesktopHotKeyTriggered: (() -> Void)?

    /// Global keyboard shortcut to toggle/show the menu bar popover.
    @Published var menuBarShortcut: MenuBarShortcut? = nil {
        didSet {
            if !isLoading {
                saveNow()
            }
            updateHotKeyRegistration()
        }
    }

    /// Global keyboard shortcut to toggle/show the full desktop app window.
    @Published var desktopAppShortcut: MenuBarShortcut? = nil {
        didSet {
            if !isLoading {
                saveNow()
            }
            updateHotKeyRegistration()
        }
    }

    /// Updates the global Carbon hotkey registration with the current settings.
    func updateHotKeyRegistration() {
        guard !isLoading else { return }
        if let shortcut = menuBarShortcut {
            GlobalHotKeyManager.shared.register(id: 1, shortcut: shortcut) { [weak self] in
                Task { @MainActor in
                    if let callback = self?.onHotKeyTriggered {
                        callback()
                    } else if let appDelegate = NSApp.delegate as? AppDelegate {
                        appDelegate.togglePopover()
                    }
                }
            }
        } else {
            GlobalHotKeyManager.shared.unregister(id: 1)
        }

        if let shortcut = desktopAppShortcut {
            GlobalHotKeyManager.shared.register(id: 2, shortcut: shortcut) { [weak self] in
                Task { @MainActor in
                    if let callback = self?.onDesktopHotKeyTriggered {
                        callback()
                    } else if let appDelegate = NSApp.delegate as? AppDelegate {
                        appDelegate.toggleDesktopApp()
                    }
                }
            }
        } else {
            GlobalHotKeyManager.shared.unregister(id: 2)
        }
    }

    // MARK: - Menu bar colors (issue #7.1)
    /// Hex color for gains/up moves. Empty = use the system green (dynamic).
    @Published var gainColorHex: String = "" {
        didSet { scheduleSave() }
    }
    /// Hex color for losses/down moves. Empty = use the system red (dynamic).
    @Published var lossColorHex: String = "" {
        didSet { scheduleSave() }
    }


    /// Issue #7.4 / #10: number of decimal places shown for percentages (0–4),
    /// everywhere a % appears (menu bar, watchlist, portfolios). Clamped on set.
    @Published var percentDecimals: Int = 1 {
        didSet {
            let clamped = min(max(percentDecimals, 0), 4)
            if clamped != percentDecimals { percentDecimals = clamped; return }
            scheduleSave()
        }
    }

    /// Issue #10: decimal places for *values* — prices and currency amounts.
    /// -1 = Auto (smart per #10: forex/sub-dollar get more precision, amounts use 2);
    /// 0–4 = force that many decimals everywhere (prices AND amounts).
    @Published var valueDecimals: Int = -1 {
        didSet {
            let clamped = min(max(valueDecimals, -1), 4)
            if clamped != valueDecimals { valueDecimals = clamped; return }
            scheduleSave()
        }
    }

    /// Price decimals honoring the manual override; Auto (-1) falls back to the
    /// smart per-symbol logic.
    func resolvedPriceDecimals(symbol: String, price: Double) -> Int {
        valueDecimals >= 0 ? valueDecimals : StorageService.priceDecimals(symbol: symbol, price: price)
    }

    /// Decimals for currency amounts (totals, P&L, position values); Auto (-1) = 2.
    var amountDecimals: Int { valueDecimals >= 0 ? valueDecimals : 2 }

    /// Issue #10: hide the percentage change in the menu bar (ticker/recap modes
    /// show just price / value). Off by default.
    @Published var menuBarHidePercent: Bool = false {
        didSet { scheduleSave() }
    }

    /// Unlocks short positions (negative quantity) and per-holding leverage in
    /// the add/edit holding sheets. Off by default to keep the common long-only
    /// flow simple.
    @Published var advancedPositions: Bool = false {
        didSet { scheduleSave() }
    }

    /// Default chart style for holding / quote charts: "line" (native line
    /// chart) or "tradingview" (embedded TradingView widget). The style picker
    /// on each chart still lets the user switch on the fly.
    @Published var defaultChartStyle: String = "line" {
        didSet { scheduleSave() }
    }

    /// Issue #8.2: show the human-readable name (e.g. "S&P 500") instead of the
    /// raw symbol ("^GSPC") in the menu bar ticker. Off keeps the bar compact.
    @Published var tickerShowName: Bool = false {
        didSet { scheduleSave() }
    }

    /// Issue #8.1: order of the watchlist entries cycled in the menu bar ticker.
    /// "manual" = as added, "type" = grouped by asset class, "alpha" = alphabetical.
    @Published var watchlistSort: String = "manual" {
        didSet { scheduleSave() }
    }

    /// In-app UI language override (ISO code). Defaults to English.
    @Published var appLanguage: String = "en" {
        didSet { scheduleSave() }
    }

    /// Supported UI languages: (ISO code, native display name).
    static let supportedLanguages: [(code: String, name: String)] = [
        ("en", "English"),
        ("vi", "Tiếng Việt"),
        ("ja", "日本語"),
        ("de", "Deutsch"),
        ("fr", "Français"),
        ("es", "Español"),
        ("it", "Italiano"),
        ("pt", "Português"),
    ]

    /// Maps symbol → ISIN for watchlist filtering
    @Published var isinMap: [String: String] = [:] {
        didSet { scheduleSave() }
    }

    /// Issue #8: maps symbol → Yahoo asset class ("EQUITY", "ETF", "INDEX",
    /// "FUTURE", …), uppercased. A symbol's type is stable, so it's resolved once
    /// (from search on add, or from the quote/chart feeds) and cached/persisted.
    @Published var symbolType: [String: String] = [:] {
        didSet { scheduleSave() }
    }

    /// Maps symbol → Exchange ("HOSE", "HNX", "NASDAQ", "NYSE", "BINANCE", ...), uppercased.
    @Published var symbolExchange: [String: String] = [:] {
        didSet { scheduleSave() }
    }

    /// Records a symbol's asset class. Ignores empty values and no-ops when
    /// unchanged so it doesn't churn the save loop on every price refresh.
    func setType(_ type: String, for symbol: String) {
        let normalized = type.uppercased()
        guard !normalized.isEmpty, symbolType[symbol] != normalized else { return }
        symbolType[symbol] = normalized
    }

    /// Records a symbol's exchange. Ignores empty values.
    func setExchange(_ exchange: String, for symbol: String) {
        let normalized = exchange.uppercased()
        guard !normalized.isEmpty else { return }
        if symbolExchange[symbol] != normalized || symbolExchange[symbol.uppercased()] != normalized {
            symbolExchange[symbol] = normalized
            symbolExchange[symbol.uppercased()] = normalized
        }
    }

    /// Primary exchange for a symbol, if recorded.
    func exchange(for symbol: String) -> String {
        if let stored = symbolExchange[symbol] ?? symbolExchange[symbol.uppercased()], !stored.isEmpty {
            return stored
        }
        return ""
    }

    /// Asset class for a symbol, using fallback heuristics if not yet known.
    func type(for symbol: String) -> String {
        if let stored = symbolType[symbol] ?? symbolType[symbol.uppercased()], !stored.isEmpty {
            return stored
        }
        if StockService.isJapaneseMutualFund(symbol) {
            return "MUTUALFUND"
        }
        if StockService.isVietnameseStock(symbol) || StockService.isJapaneseStock(symbol) {
            return "EQUITY"
        }
        if StorageService.isIndex(symbol: symbol, type: symbolType[symbol]) {
            return "INDEX"
        }
        return ""
    }

    /// One-shot price alerts.
    @Published var alerts: [PriceAlert] = [] {
        didSet { scheduleSave() }
    }

    /// User-authored notes per symbol, shared across watchlist and portfolio.
    @Published var symbolNotes: [String: [SymbolNote]] = [:] {
        didSet { scheduleSave() }
    }

    /// Recurring portfolio notifications, keyed by portfolio id (uuidString).
    @Published var portfolioNotifications: [String: [PortfolioNotification]] = [:] {
        didSet { scheduleSave() }
    }

    /// Daily value/P&L snapshots for the Portfolio window's history chart, keyed
    /// by portfolio id (uuidString). Accumulates forward — see `PortfolioSnapshot`.
    @Published var portfolioSnapshots: [String: [PortfolioSnapshot]] = [:] {
        didSet { scheduleSave() }
    }

    /// Preferred timeline range option per portfolio scope (e.g. "3Y", "1Y", "All").
    @Published var portfolioChartRanges: [String: String] = [:] {
        didSet { scheduleSave() }
    }

    /// Preferred daily P&L range option per portfolio scope (e.g. "3M", "6M", "1Y").
    @Published var portfolioDailyPnlRanges: [String: String] = [:] {
        didSet { scheduleSave() }
    }

    /// Preferred monthly P&L range option per portfolio scope (e.g. "1Y", "3Y", "All").
    @Published var portfolioMonthlyPnlRanges: [String: String] = [:] {
        didSet { scheduleSave() }
    }

    /// Preferred P&L view mode per portfolio scope (e.g. "Daily P&L", "Monthly P&L").
    @Published var portfolioPnlViewModes: [String: String] = [:] {
        didSet { scheduleSave() }
    }

    /// Discord/Slack incoming webhook for mirroring notifications.
    @Published var discordWebhookURL: String = "" {
        didSet { scheduleSave() }
    }
    @Published var discordEnabled: Bool = false {
        didSet { scheduleSave() }
    }

    // MARK: - AI Review

    /// OpenAI-compatible chat history for the AI Review tab. Stored in full
    /// locally (free); only a sliding window of messages is ever sent to the
    /// provider so a long conversation stays cheap on tokens.
    @Published var aiChatSections: [AIChatSection] = [] {
        didSet { scheduleSave() }
    }

    /// Provider base URL for chat completions (OpenAI-compatible). Users can
    /// point this at OpenAI, DeepSeek, Groq, OpenRouter, etc.
    @Published var aiBaseURL: String = "https://api.openai.com/v1" {
        didSet { scheduleSave() }
    }
    /// Model name sent to the provider.
    @Published var aiModel: String = "gpt-4o-mini" {
        didSet { scheduleSave() }
    }
    /// Chosen provider preset; "custom" unlocks the free-form base URL field.
    @Published var aiProvider: String = "openai" {
        didSet { scheduleSave() }
    }

    /// Path to the AI Review workspace folder (mirrors the Codex/cowork idea: a
    /// folder the AI treats as long-term memory). When set, the app reads
    /// `<folder>/ai-context.md` on every request so durable notes survive across
    /// sessions instead of being re-asked each time.
    @Published var aiWorkspacePath: String = "" {
        didSet { scheduleSave() }
    }

    /// DeepSeek V4 thinking mode. V4 models default to thinking enabled; turning
    /// it off restores the classic fast-chat behavior of the retired
    /// `deepseek-chat` alias. Only sent for DeepSeek.
    @Published var aiDeepseekThinking: Bool = false {
        didSet { scheduleSave() }
    }

    /// User's investor profile (age, risk tolerance, investment style, goals).
    /// Used by AI Review across the app for personalized consultation.
    @Published var investorProfile: InvestorProfile? = nil {
        didSet { scheduleSave() }
    }

    /// Dynamic models fetched from provider server, cached by provider key.
    @Published var cachedModelsByProvider: [String: [String]] = [:] {
        didSet { scheduleSave() }
    }

    /// Known OpenAI-compatible provider presets.
    static let aiProviders: [(id: String, label: String)] = [
        ("openai", "OpenAI"),
        ("gemini", "Google Gemini"),
        ("deepseek", "DeepSeek"),
        ("groq", "Groq"),
        ("openrouter", "OpenRouter"),
        ("custom", "Custom…")
    ]

    /// Sensible default models for the preset providers.
    static let aiProviderDefaults: [String: String] = [
        "openai": "gpt-4o-mini",
        "gemini": "gemini-2.0-flash",
        "deepseek": "deepseek-v4-flash",
        "groq": "llama-3.3-70b-versatile",
        "openrouter": "google/gemini-2.0-flash-001"
    ]

    /// Preset standard models per provider (used when server list is not yet loaded).
    static let providerPresetModels: [String: [String]] = [
        "openai": [
            "gpt-4o-mini",
            "gpt-4o",
            "gpt-4.5-preview",
            "o3-mini",
            "o1-mini",
            "o1"
        ],
        "gemini": [
            "gemini-2.0-flash",
            "gemini-2.5-flash",
            "gemini-2.5-pro",
            "gemini-1.5-flash",
            "gemini-1.5-pro",
            "gemini-2.0-flash-lite"
        ],
        "deepseek": [
            "deepseek-v4-flash",
            "deepseek-v4-pro",
            "deepseek-chat",
            "deepseek-reasoner"
        ],
        "groq": [
            "llama-3.3-70b-versatile",
            "llama-3.1-8b-instant",
            "mixtral-8x7b-32768"
        ],
        "openrouter": [
            "google/gemini-2.0-flash-001",
            "openai/gpt-4o-mini",
            "anthropic/claude-3.5-sonnet",
            "meta-llama/llama-3.3-70b-instruct"
        ]
    ]

    /// Base URL for the preset providers (without trailing slash).
    static let aiProviderBaseURLs: [String: String] = [
        "openai": "https://api.openai.com/v1",
        "gemini": "https://generativelanguage.googleapis.com/v1beta/openai",
        "deepseek": "https://api.deepseek.com/v1",
        "groq": "https://api.groq.com/openai/v1",
        "openrouter": "https://openrouter.ai/api/v1"
    ]

    /// Legacy flat model list (kept for backwards compatibility).
    static var aiModelOptions: [(String, String)] {
        var all: [String] = []
        for (_, models) in providerPresetModels {
            for m in models {
                if !all.contains(m) { all.append(m) }
            }
        }
        return all.map { ($0, $0) }
    }

    private static let aiApiKeyKeychainKey = "aiReview_apiKey"

    /// The user's provider API key. Stored in the Keychain (never persisted as
    /// plaintext in data.json); empty string = not configured.
    var aiApiKey: String {
        get { KeychainService.loadString(forKey: Self.aiApiKeyKeychainKey) ?? "" }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                _ = KeychainService.delete(key: Self.aiApiKeyKeychainKey)
            } else {
                _ = KeychainService.saveString(trimmed, forKey: Self.aiApiKeyKeychainKey)
                // Auto-detect provider if key has distinctive prefix and user is on default
                if let detected = Self.autoDetectProvider(from: trimmed), detected != aiProvider {
                    applyAIPreset(detected)
                }
            }
        }
    }

    var hasAIConfiguration: Bool {
        !aiApiKey.isEmpty && !aiBaseURL.isEmpty
    }

    /// Auto-detects AI provider based on known API key patterns.
    static func autoDetectProvider(from key: String) -> String? {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("AIzaSy") {
            return "gemini"
        }
        if trimmed.hasPrefix("gsk_") {
            return "groq"
        }
        if trimmed.hasPrefix("sk-or-") {
            return "openrouter"
        }
        return nil
    }

    /// Returns the live or preset models for a given provider.
    func availableModels(for provider: String) -> [String] {
        var list: [String] = []
        if let cached = cachedModelsByProvider[provider], !cached.isEmpty {
            list = cached
        } else if let presets = Self.providerPresetModels[provider] {
            list = presets
        }
        if !aiModel.isEmpty && !list.contains(aiModel) && aiProvider == provider {
            list.insert(aiModel, at: 0)
        }
        return list
    }

    /// Updates the cached server models for a specific provider.
    func setCachedModels(_ models: [String], for provider: String) {
        guard !models.isEmpty else { return }
        cachedModelsByProvider[provider] = models
        scheduleSave()
    }

    func applyAIPreset(_ provider: String) {
        aiProvider = provider
        if let url = Self.aiProviderBaseURLs[provider] {
            aiBaseURL = url
        }
        if let defaultModel = Self.aiProviderDefaults[provider] {
            aiModel = defaultModel
        }
    }

    /// Resolves the workspace folder, creating it (plus a starter `ai-context.md`
    /// if absent) the first time it's referenced. Returns nil when no workspace
    /// is configured.
    @discardableResult
    func ensureAIWorkspace() -> URL? {
        let path = aiWorkspacePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let notes = folder.appendingPathComponent("ai-context.md")
            if !FileManager.default.fileExists(atPath: notes.path) {
                try """
                # AI Review workspace notes

                Anything you want the assistant to remember across conversations —
                your approach, goals, risk tolerance, important context — goes here.
                The AI reads this file on every request.

                """.write(to: notes, atomically: true, encoding: .utf8)
            }
            return folder
        } catch {
            return nil
        }
    }

    /// The current content of `<workspace>/ai-context.md`, ready to be injected
    /// into the AI prompt. Returns nil when no workspace is configured or the
    /// file is empty.
    func aiWorkspaceContextText() -> String? {
        guard let folder = ensureAIWorkspace() else { return nil }
        let notes = folder.appendingPathComponent("ai-context.md")
        guard let text = try? String(contentsOf: notes, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Appends a note to `<workspace>/ai-context.md` (creates the workspace and
    /// file if needed). Returns false when no workspace is configured.
    @discardableResult
    func appendAIWorkspaceNote(_ note: String) -> Bool {
        guard let folder = ensureAIWorkspace() else { return false }
        let notes = folder.appendingPathComponent("ai-context.md")
        let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .short)
        var content = "\n## \(stamp)\n\n\(note)\n"
        if let existing = try? String(contentsOf: notes, encoding: .utf8) {
            content = existing.trimmingCharacters(in: .whitespacesAndNewlines) + "\n" + content
        }
        do {
            try content.write(to: notes, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Daily AI Insight Cache
    @Published var dailyAIInsight: HomeAIInsight?

    private var dailyAIInsightFileURL: URL {
        fileURL.deletingLastPathComponent().appendingPathComponent("daily_ai_insight.json")
    }

    func loadDailyAIInsight() -> HomeAIInsight? {
        if let cached = dailyAIInsight {
            return cached
        }
        guard let data = try? Data(contentsOf: dailyAIInsightFileURL),
              let insight = try? JSONDecoder().decode(HomeAIInsight.self, from: data) else {
            return nil
        }
        self.dailyAIInsight = insight
        return insight
    }

    func saveDailyAIInsight(_ insight: HomeAIInsight) {
        self.dailyAIInsight = insight
        if let data = try? JSONEncoder().encode(insight) {
            try? data.write(to: dailyAIInsightFileURL, options: .atomic)
        }
    }

    @Published var fontSizeLevel: Int = 9 {
        didSet {
            FontRegistration.sizeOffset = CGFloat(fontSizeLevel - 9)
            scheduleSave()
        }
    }

    @Published var fontFamily: String = "Inter Variable" {
        didSet {
            FontRegistration.familyName = fontFamily
            scheduleSave()
        }
    }

    func setISIN(_ isin: String, for symbol: String) {
        isinMap[symbol] = isin
    }

    // MARK: - Alerts

    func addAlert(_ alert: PriceAlert) {
        alerts.append(alert)
    }

    func removeAlert(id: UUID) {
        alerts.removeAll { $0.id == id }
    }

    func removeAllAlerts() {
        alerts.removeAll()
    }

    func removeAlerts(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        alerts.removeAll { ids.contains($0.id) }
    }

    func updateAlert(id: UUID, condition: AlertCondition, threshold: Double) {
        guard let i = alerts.firstIndex(where: { $0.id == id }) else { return }
        alerts[i].condition = condition
        alerts[i].threshold = threshold
        // An edited alert counts as a fresh one: re-arm it and clear the
        // "triggered" state so it can fire again immediately.
        alerts[i].isEnabled = true
        alerts[i].lastTriggeredAt = nil
        // A changed condition also resets the MA cross state (nil = prime next
        // evaluation without firing).
        alerts[i].lastPositionAboveMA = nil
    }

    /// Records the latest above/below side for a crossing MA alert.
    func updateAlertPosition(id: UUID, nowAbove: Bool) {
        guard let i = alerts.firstIndex(where: { $0.id == id }) else { return }
        alerts[i].lastPositionAboveMA = nowAbove
    }

    func setAlertEnabled(id: UUID, enabled: Bool) {
        guard let i = alerts.firstIndex(where: { $0.id == id }) else { return }
        alerts[i].isEnabled = enabled
        if enabled { alerts[i].lastTriggeredAt = nil }
    }

    /// Marks an alert as fired: records the time and disables it (one-shot).
    func markAlertTriggered(id: UUID, at date: Date = Date()) {
        guard let i = alerts.firstIndex(where: { $0.id == id }) else { return }
        alerts[i].isEnabled = false
        alerts[i].lastTriggeredAt = date
    }

    func alerts(for symbol: String) -> [PriceAlert] {
        alerts.filter { $0.symbol == symbol }
    }

    // MARK: - Symbol notes

    /// Returns notes for a symbol, newest first.
    func notes(for symbol: String) -> [SymbolNote] {
        symbolNotes[symbol] ?? []
    }

    func addNote(to symbol: String, title: String = "", content: String) {
        let note = SymbolNote(title: title, content: content)
        symbolNotes[symbol, default: []].insert(note, at: 0)
    }

    func updateNote(id: UUID, for symbol: String, title: String? = nil, content: String? = nil) {
        guard let idx = symbolNotes[symbol]?.firstIndex(where: { $0.id == id }) else { return }
        if let title = title { symbolNotes[symbol]?[idx].title = title }
        if let content = content { symbolNotes[symbol]?[idx].content = content }
        symbolNotes[symbol]?[idx].updatedAt = Date()
    }

    func deleteNote(id: UUID, from symbol: String) {
        symbolNotes[symbol]?.removeAll { $0.id == id }
        if symbolNotes[symbol]?.isEmpty == true {
            symbolNotes[symbol] = nil
        }
    }

    // MARK: - Portfolio notifications

    func notifications(for portfolioId: UUID) -> [PortfolioNotification] {
        portfolioNotifications[portfolioId.uuidString] ?? []
    }

    func addPortfolioNotification(_ notification: PortfolioNotification, to portfolioId: UUID) {
        portfolioNotifications[portfolioId.uuidString, default: []].append(notification)
    }

    func removeAllPortfolioNotifications() {
        portfolioNotifications = [:]
    }

    func removePortfolioNotification(id: UUID, from portfolioId: UUID) {
        portfolioNotifications[portfolioId.uuidString]?.removeAll { $0.id == id }
        if portfolioNotifications[portfolioId.uuidString]?.isEmpty == true {
            portfolioNotifications[portfolioId.uuidString] = nil
        }
    }

    func setPortfolioNotificationEnabled(id: UUID, in portfolioId: UUID, enabled: Bool) {
        guard let i = portfolioNotifications[portfolioId.uuidString]?.firstIndex(where: { $0.id == id }) else { return }
        portfolioNotifications[portfolioId.uuidString]?[i].isEnabled = enabled
        if enabled {
            portfolioNotifications[portfolioId.uuidString]?[i].lastStepUp = nil
            portfolioNotifications[portfolioId.uuidString]?[i].lastStepDown = nil
            portfolioNotifications[portfolioId.uuidString]?[i].lastDay = nil
        }
    }

    /// Persists the anti-spam high-water state after a notification fires (or primes silently).
    func updatePortfolioNotificationState(id: UUID, in portfolioId: UUID,
                                          lastStepUp: Double?, lastStepDown: Double?, lastDay: String?) {
        guard let i = portfolioNotifications[portfolioId.uuidString]?.firstIndex(where: { $0.id == id }) else { return }
        portfolioNotifications[portfolioId.uuidString]?[i].lastStepUp = lastStepUp
        portfolioNotifications[portfolioId.uuidString]?[i].lastStepDown = lastStepDown
        portfolioNotifications[portfolioId.uuidString]?[i].lastDay = lastDay
    }

    // MARK: - Portfolio snapshots

    func snapshots(for portfolioId: UUID) -> [PortfolioSnapshot] {
        portfolioSnapshots[portfolioId.uuidString] ?? []
    }

    /// Records a portfolio's value/cost for today, keeping one snapshot per day
    /// (today's is replaced so the latest intraday value wins). The date is
    /// normalized to the start of the local day. No-ops for an empty portfolio so
    /// the history doesn't fill with zeros before any holdings exist.
    func recordSnapshot(for portfolioId: UUID, totalValue: Double, totalCost: Double,
                        now: Date = Date(), calendar: Calendar = .current) {
        guard totalValue != 0 || totalCost != 0 else { return }
        let snapshot = PortfolioSnapshot(date: calendar.startOfDay(for: now),
                                         totalValue: totalValue, totalCost: totalCost)
        let key = portfolioId.uuidString
        portfolioSnapshots[key] = SnapshotLog.upsert(snapshot, into: portfolioSnapshots[key] ?? [], calendar: calendar)
    }

    func chartRange(for scopeKey: String) -> String? {
        portfolioChartRanges[scopeKey]
    }

    func setChartRange(_ rangeRaw: String, for scopeKey: String) {
        portfolioChartRanges[scopeKey] = rangeRaw
    }

    func dailyPnlRange(for scopeKey: String) -> String? {
        portfolioDailyPnlRanges[scopeKey]
    }

    func setDailyPnlRange(_ rangeRaw: String, for scopeKey: String) {
        portfolioDailyPnlRanges[scopeKey] = rangeRaw
    }

    func monthlyPnlRange(for scopeKey: String) -> String? {
        portfolioMonthlyPnlRanges[scopeKey]
    }

    func setMonthlyPnlRange(_ rangeRaw: String, for scopeKey: String) {
        portfolioMonthlyPnlRanges[scopeKey] = rangeRaw
    }

    func pnlViewMode(for scopeKey: String) -> String? {
        portfolioPnlViewModes[scopeKey]
    }

    func setPnlViewMode(_ modeRaw: String, for scopeKey: String) {
        portfolioPnlViewModes[scopeKey] = modeRaw
    }

    @Published var lastStockChartRange: String = "1M" {
        didSet { scheduleSave() }
    }

    @Published var portfolioPositionSorts: [String: String] = [:] {
        didSet { scheduleSave() }
    }

    func positionSort(for scopeKey: String) -> (column: String, ascending: Bool)? {
        guard let raw = portfolioPositionSorts[scopeKey] else { return nil }
        let parts = raw.split(separator: ":")
        guard parts.count == 2 else { return nil }
        return (column: String(parts[0]), ascending: parts[1] == "asc")
    }

    func setPositionSort(column: String, ascending: Bool, for scopeKey: String) {
        portfolioPositionSorts[scopeKey] = "\(column):\(ascending ? "asc" : "desc")"
    }

    func setWatchlistSort(key: String, ascending: Bool, for watchlistId: UUID) {
        guard let idx = watchlists.firstIndex(where: { $0.id == watchlistId }) else { return }
        if watchlists[idx].sortKey != key || watchlists[idx].sortAsc != ascending {
            watchlists[idx].sortKey = key
            watchlists[idx].sortAsc = ascending
        }
    }

    @Published var lastSelectedTab: String = {
        if let stored = UserDefaults.standard.string(forKey: "lastSelectedTab") {
            return stored == "Watchlist" ? "Watchlists" : stored
        }
        return "Watchlists"
    }() {
        didSet {
            UserDefaults.standard.set(lastSelectedTab, forKey: "lastSelectedTab")
            scheduleSave()
        }
    }

    static let supportedCurrencies = ["EUR", "USD", "GBP", "CHF", "JPY", "VND", "CAD", "AUD"]

    /// Issue #10: how many decimals to show for a *market price*. Two decimals is
    /// right for normal stocks, but forex pairs (e.g. CADUSD=X = 0.7119) and any
    /// sub-dollar instrument (penny stocks, low-priced crypto) lose meaningful
    /// precision at 2 decimals, so they get 4. Big forex crosses (e.g. USDJPY ≈ 149)
    /// stay at 2 to avoid pointless trailing zeros.
    nonisolated static func priceDecimals(symbol: String, price: Double) -> Int {
        let isForex = symbol.uppercased().hasSuffix("=X")
        let magnitude = abs(price)
        if isForex { return magnitude >= 50 ? 2 : 4 }
        if magnitude > 0 && magnitude < 1 { return 4 }
        return 2
    }

    /// Formats a plain number with a thousands grouping separator and locale-aware
    /// decimal separator, e.g. "1,234.56" (en) / "1.234,56" (it). Falls back to a
    /// non-grouped representation if the formatter ever fails.
    nonisolated static func formatNumber(_ value: Double, decimals: Int, locale: Locale = .autoupdatingCurrent,
                                         stripTrailingZeros: Bool = false) -> String {
        // When a numeric value is not finite, show a dash so UI cells display
        // "-" instead of "NaN" for missing/unknown data (e.g. unknown cost).
        guard value.isFinite else { return "-" }
        // Grouping is inserted manually (every 3 digits from the right) so every value
        // > 1,000 is separated regardless of the locale's CLDR rule (e.g. it/es only group
        // from 10,000 by default), and without needing macOS 15's `minimumGroupingDigits`.
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        let groupSep = formatter.groupingSeparator ?? ","
        let decSep = formatter.decimalSeparator ?? "."

        // %f always emits "." as the decimal separator, independent of locale.
        let rounded = String(format: "%.\(decimals)f", abs(value))
        let parts = rounded.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        let intDigits = String(parts[0])
        var fracDigits = parts.count > 1 ? String(parts[1]) : ""

        if stripTrailingZeros && !fracDigits.isEmpty {
            while fracDigits.hasSuffix("0") {
                fracDigits.removeLast()
            }
        }

        var grouped = ""
        var count = 0
        for ch in intDigits.reversed() {
            if count > 0 && count % 3 == 0 { grouped.append(contentsOf: groupSep.reversed()) }
            grouped.append(ch)
            count += 1
        }
        var result = String(grouped.reversed())
        if !fracDigits.isEmpty { result += decSep + fracDigits }
        return (value < 0 ? "-" : "") + result
    }

    /// Formats an amount with the currency symbol *before* the figure, e.g.
    /// "€1,234.56", "+€820.00", "-€540.00". The sign (when shown) precedes the symbol.
    nonisolated static func formatAmount(_ value: Double, symbol: String, decimals: Int = 2, signed: Bool = false,
                                         locale: Locale = .autoupdatingCurrent, stripTrailingZeros: Bool = false) -> String {
        // When the numeric value is not finite (NaN/Inf), show a dash so the UI
        // doesn't display "NaN" for P&L or cost when a holding has unknown cost.
        guard value.isFinite else { return "-" }
        let sign = signed ? (value >= 0 ? "+" : "-") : (value < 0 ? "-" : "")
        let magnitude = formatNumber(abs(value), decimals: decimals, locale: locale, stripTrailingZeros: stripTrailingZeros)
        return "\(sign)\(symbol)\(magnitude)"
    }

    /// Issue #8.3: true when a symbol is a market index, which has no associated
    /// currency (so no currency symbol should prefix its value). Uses the resolved
    /// Yahoo type when known, falling back to the "^" convention (e.g. ^GSPC).
    nonisolated static func isIndex(symbol: String, type: String?) -> Bool {
        if let t = type, !t.isEmpty { return t.uppercased() == "INDEX" }
        return symbol.hasPrefix("^")
    }

    /// Issue #8.1: orders watchlist symbols for the menu bar ticker cycle.
    /// "type" groups by asset class (stocks → ETFs → indices → futures → …),
    /// keeping the original relative order within each group (stable). Symbols with
    /// an unknown type sort last. "alpha" sorts alphabetically. "manual" (default)
    /// preserves the as-added order.
    nonisolated static func tickerOrder(_ symbols: [String], mode: String, types: [String: String]) -> [String] {
        switch mode {
        case "alpha":
            return symbols.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        case "type":
            func rank(_ symbol: String) -> Int {
                switch (types[symbol] ?? "").uppercased() {
                case "EQUITY": return 0
                case "ETF": return 1
                case "INDEX": return 2
                case "FUTURE": return 3
                case "MUTUALFUND": return 4
                case "CURRENCY": return 5
                case "CRYPTOCURRENCY": return 6
                case "": return 100 // unknown type → end
                default: return 50
                }
            }
            return symbols.enumerated()
                .sorted { a, b in
                    let ra = rank(a.element), rb = rank(b.element)
                    return ra != rb ? ra < rb : a.offset < b.offset // stable within a group
                }
                .map { $0.element }
        default:
            return symbols
        }
    }

    /// Orders rows by their pre/post-market % move (the meaningful figure during
    /// extended hours), NOT by the raw extended-hours price. Rows without an
    /// extended-hours quote (`nil` percent) always sink to the bottom, regardless
    /// of sort direction. Descending puts the biggest movers first.
    nonisolated static func sortedByExtendedPercent<Row>(
        _ rows: [Row], ascending: Bool, percent: (Row) -> Double?
    ) -> [Row] {
        rows.sorted { a, b in
            switch (percent(a), percent(b)) {
            case let (x?, y?): return ascending ? x < y : x > y
            case (_?, nil):    return true   // a has ext data, b doesn't → a first
            case (nil, _?):    return false  // b has ext data → b first
            case (nil, nil):   return false
            }
        }
    }

    /// Canonical watchlist sorting method shared across Desktop and Popover views.
    /// Guarantees 100% identical row ordering, FX conversion, missing-data handling,
    /// and stable tie-breaking across the entire app.
    nonisolated static func sortWatchlistSymbols(
        _ symbols: [String],
        key: WatchlistSortKey,
        ascending: Bool,
        quotes: [String: StockQuote],
        history: [String: [PricePoint]] = [:],
        priceHistoryMax: [String: [PricePoint]] = [:],
        priceRate: (String) -> Double = { _ in 1.0 },
        rate: (String) -> Double = { _ in 1.0 },
        showExtendedHours: Bool = true
    ) -> [String] {
        if key == .order {
            return ascending ? symbols : Array(symbols.reversed())
        }
        if key == .symbol {
            return symbols.sorted { ascending ? $0.localizedCompare($1) == .orderedAscending : $0.localizedCompare($1) == .orderedDescending }
        }

        let calendar = Calendar.current
        let now = Date()
        let monthStart = calendar.date(byAdding: .month, value: -1, to: now)
        let threeMonthStart = calendar.date(byAdding: .month, value: -3, to: now)
        let sixMonthStart = calendar.date(byAdding: .month, value: -6, to: now)
        let yearStart = calendar.date(from: calendar.dateComponents([.year], from: now))
        let oneYearStart = calendar.date(byAdding: .year, value: -1, to: now)
        let twoYearStart = calendar.date(byAdding: .year, value: -2, to: now)
        let threeYearStart = calendar.date(byAdding: .year, value: -3, to: now)
        let fiveYearStart = calendar.date(byAdding: .year, value: -5, to: now)
        let tenYearStart = calendar.date(byAdding: .year, value: -10, to: now)

        func value(for symbol: String) -> Double? {
            let q = quotes[symbol]
            let pRate = q.map { priceRate($0.currency) } ?? 1
            let mRate = q.map { rate($0.currency) } ?? 1
            let hist = history[symbol] ?? []
            let histMax = priceHistoryMax[symbol] ?? []
            let regularPrice = q?.price ?? 0

            switch key {
            case .order, .symbol:
                return nil
            case .price:
                return q != nil ? regularPrice * pRate : nil
            case .changePercent:
                return q?.changePercent
            case .extChangePercent:
                guard showExtendedHours, let q, q.isExtendedHours else { return nil }
                return q.extendedChangePercent
            case .metric(let m):
                switch m {
                case .price:
                    return q != nil ? regularPrice * pRate : nil
                case .today:
                    return q?.changePercent
                case .todayChange:
                    return q.map { $0.change * pRate }
                case .oneMonth:
                    return monthStart.flatMap { PriceHistory.percentChange(points: hist, currentPrice: regularPrice, since: $0) }
                case .threeMonths:
                    return threeMonthStart.flatMap { PriceHistory.percentChange(points: hist, currentPrice: regularPrice, since: $0) }
                case .sixMonths:
                    return sixMonthStart.flatMap { PriceHistory.percentChange(points: hist, currentPrice: regularPrice, since: $0) }
                case .ytd:
                    return yearStart.flatMap { PriceHistory.percentChange(points: hist, currentPrice: regularPrice, since: $0) }
                case .oneYear:
                    return oneYearStart.flatMap { PriceHistory.percentChange(points: hist, currentPrice: regularPrice, since: $0) }
                case .twoYears:
                    return twoYearStart.flatMap { PriceHistory.percentChange(points: hist, currentPrice: regularPrice, since: $0) }
                case .threeYears:
                    return threeYearStart.flatMap { PriceHistory.percentChange(points: hist, currentPrice: regularPrice, since: $0) }
                case .fiveYears:
                    return fiveYearStart.flatMap { PriceHistory.percentChange(points: histMax.isEmpty ? hist : histMax, currentPrice: regularPrice, since: $0) }
                case .tenYears:
                    return tenYearStart.flatMap { PriceHistory.percentChange(points: histMax.isEmpty ? hist : histMax, currentPrice: regularPrice, since: $0) }
                case .ath:
                    var histHigh: Double? = nil
                    for p in histMax {
                        let h = p.effectiveHigh
                        if histHigh == nil || h > histHigh! { histHigh = h }
                    }
                    let quoteHigh = max(q?.fiftyTwoWeekHigh ?? 0, q?.price ?? 0)
                    if let h = histHigh { return max(h, quoteHigh) * pRate }
                    if quoteHigh > 0 { return quoteHigh * pRate }
                    return nil
                case .atl:
                    var histLow: Double? = nil
                    for p in histMax {
                        let l = p.effectiveLow
                        if histLow == nil || l < histLow! { histLow = l }
                    }
                    let qLow = q?.fiftyTwoWeekLow != nil ? min(q!.fiftyTwoWeekLow!, q?.price ?? Double.greatestFiniteMagnitude) : q?.price
                    if let l = histLow, let ql = qLow, ql > 0 { return min(l, ql) * pRate }
                    if let l = histLow { return l * pRate }
                    if let ql = qLow, ql > 0 { return ql * pRate }
                    return nil
                case .fromAth:
                    var histHigh: Double? = nil
                    for p in histMax {
                        let h = p.effectiveHigh
                        if histHigh == nil || h > histHigh! { histHigh = h }
                    }
                    let quoteHigh = max(q?.fiftyTwoWeekHigh ?? 0, q?.price ?? 0)
                    let ath: Double?
                    if let h = histHigh { ath = max(h, quoteHigh) * pRate }
                    else if quoteHigh > 0 { ath = quoteHigh * pRate }
                    else { ath = nil }
                    guard let ath, ath > 0, regularPrice > 0 else { return nil }
                    let priceConverted = regularPrice * pRate
                    if priceConverted >= ath { return 0.0 }
                    return min(0.0, (priceConverted - ath) / ath * 100)
                case .fromAtl:
                    var histLow: Double? = nil
                    for p in histMax {
                        let l = p.effectiveLow
                        if histLow == nil || l < histLow! { histLow = l }
                    }
                    let qLow = q?.fiftyTwoWeekLow != nil ? min(q!.fiftyTwoWeekLow!, q?.price ?? Double.greatestFiniteMagnitude) : q?.price
                    let atl: Double?
                    if let l = histLow, let ql = qLow, ql > 0 { atl = min(l, ql) * pRate }
                    else if let l = histLow { atl = l * pRate }
                    else if let ql = qLow, ql > 0 { atl = ql * pRate }
                    else { atl = nil }
                    guard let atl, atl > 0, regularPrice > 0 else { return nil }
                    let priceConverted = regularPrice * pRate
                    if priceConverted <= atl { return 0.0 }
                    return max(0.0, (priceConverted - atl) / atl * 100)
                case .marketCap:
                    return q?.marketCap.map { $0 * mRate }
                case .chart24h, .chart7d, .chart30d, .chart60d, .chart90d, .chartYtd, .chart1y:
                    return nil
                }
            }
        }

        let symbolOrder = Dictionary(uniqueKeysWithValues: symbols.enumerated().map { ($0.element, $0.offset) })
        let evaluatedValues = Dictionary(uniqueKeysWithValues: symbols.map { ($0, value(for: $0)) })

        return symbols.sorted { lhs, rhs in
            let lv = evaluatedValues[lhs] ?? nil
            let rv = evaluatedValues[rhs] ?? nil
            switch (lv, rv) {
            case let (l?, r?) where l != r:
                return ascending ? l < r : l > r
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                return (symbolOrder[lhs] ?? 0) < (symbolOrder[rhs] ?? 0)
            }
        }
    }

    nonisolated static func currencySymbol(for code: String) -> String {
        switch code {
        case "EUR": return "€"
        case "USD": return "$"
        case "GBP": return "£"
        case "CHF": return "CHF"
        case "JPY": return "¥"
        case "VND": return "₫"
        case "CAD": return "C$"
        case "AUD": return "A$"
        default: return code
        }
    }

    /// Formats a number compactly with K/M suffixes when ≥ 10,000.
    /// When the value is below the compact threshold and `decimals` is provided,
    /// that decimal count is used so small numbers still respect the user's setting.
    nonisolated static func formatCompactNumber(_ value: Double, decimals: Int? = nil, stripTrailingZeros: Bool = false) -> String {
        let absVal = abs(value)
        let sign = value < 0 ? "-" : ""
        if absVal >= 1_000_000 {
            let m = absVal / 1_000_000
            return "\(sign)\(String(format: m >= 10 ? "%.1fM" : "%.2fM", m))"
        } else if absVal >= 10_000 {
            let k = absVal / 1_000
            return "\(sign)\(String(format: k >= 100 ? "%.0fK" : "%.1fK", k))"
        } else {
            return formatNumber(value, decimals: decimals ?? 0, stripTrailingZeros: stripTrailingZeros)
        }
    }

    /// Formats an amount compactly with K/M suffixes when ≥ 10,000.
    /// When the value is below the compact threshold and `decimals` is provided,
    /// that decimal count is used so small numbers still respect the user's setting.
    nonisolated static func formatCompactAmount(_ value: Double, symbol: String, signed: Bool = false, decimals: Int? = nil,
                                                stripTrailingZeros: Bool = false) -> String {
        let absVal = abs(value)
        let sign = value < 0 ? "-" : (signed && value > 0 ? "+" : "")
        if absVal >= 1_000_000 {
            let m = absVal / 1_000_000
            let formatted = String(format: m >= 10 ? "%.1fM" : "%.2fM", m)
            return "\(sign)\(symbol)\(formatted)"
        } else if absVal >= 10_000 {
            let k = absVal / 1_000
            let formatted = String(format: k >= 100 ? "%.0fK" : "%.1fK", k)
            return "\(sign)\(symbol)\(formatted)"
        } else {
            return formatAmount(value, symbol: symbol, decimals: decimals ?? 0, signed: signed, stripTrailingZeros: stripTrailingZeros)
        }
    }

    /// Formats market capitalization in compact T/B/M scale with currency symbol.
    /// e.g. Apple → "$3.50T", Toyota → "¥45.2B", small cap → "$850M"
    nonisolated static func formatMarketCap(_ value: Double, currency: String) -> String {
        let absVal = abs(value)
        let currSymbol = currencySymbol(for: currency)
        if absVal >= 1_000_000_000_000 {
            let t = absVal / 1_000_000_000_000
            return "\(currSymbol)\(String(format: t >= 100 ? "%.1fT" : "%.2fT", t))"
        } else if absVal >= 1_000_000_000 {
            let b = absVal / 1_000_000_000
            return "\(currSymbol)\(String(format: b >= 100 ? "%.1fB" : "%.2fB", b))"
        } else {
            let m = absVal / 1_000_000
            return "\(currSymbol)\(String(format: m >= 100 ? "%.0fM" : "%.1fM", m))"
        }
    }

    private let fileURL: URL
    private let isCustomStorage: Bool
    private var isLoading = false
    private var decodeFailure = false
    private var saveTask: Task<Void, Never>?

    init(fileURL: URL? = nil) {
        self.isCustomStorage = (fileURL != nil)
        if let customURL = fileURL {
            self.fileURL = customURL
        } else {
            guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
                let fallback = FileManager.default.temporaryDirectory
                self.fileURL = fallback.appendingPathComponent("StockDeck_data.json")
                isLoading = true
                load()
                isLoading = false
                return
            }
            let dirName = "StockDeck"
            let dir = appSupport.appendingPathComponent(dirName, isDirectory: true)
            let oldDir = appSupport.appendingPathComponent("StockBar", isDirectory: true)
            if FileManager.default.fileExists(atPath: oldDir.path) && !FileManager.default.fileExists(atPath: dir.path) {
                try? FileManager.default.moveItem(at: oldDir, to: dir)
            }
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.fileURL = dir.appendingPathComponent("data.json")
        }
        isLoading = true
        load()
        if watchlists.isEmpty {
            let def = Watchlist(id: UUID(), name: "Watchlist", symbols: [])
            watchlists = [def]
            selectedWatchlistId = def.id
        }
        self.launchAtLogin = (SMAppService.mainApp.status == .enabled)
        isLoading = false
        updateHotKeyRegistration()
    }

    func addToWatchlist(_ symbol: String, targetWatchlistId: UUID? = nil) {
        let activeId = targetWatchlistId ?? currentWatchlist.id
        guard let idx = watchlists.firstIndex(where: { $0.id == activeId }) else { return }
        guard !watchlists[idx].symbols.contains(symbol) else { return }
        watchlists[idx].symbols.append(symbol)
        prefetchLogo(symbol)
    }

    func removeFromWatchlist(_ symbol: String) {
        let activeId = currentWatchlist.id
        guard let idx = watchlists.firstIndex(where: { $0.id == activeId }) else { return }
        watchlists[idx].symbols.removeAll { $0 == symbol }
    }

    func removeMultipleFromWatchlist(_ symbols: Set<String>) {
        let activeId = currentWatchlist.id
        guard let idx = watchlists.firstIndex(where: { $0.id == activeId }) else { return }
        watchlists[idx].symbols.removeAll { symbols.contains($0) }
    }

    func addMultipleToWatchlist(_ symbols: Set<String>, targetWatchlistId: UUID) {
        guard let idx = watchlists.firstIndex(where: { $0.id == targetWatchlistId }) else { return }
        let toAdd = symbols.filter { !watchlists[idx].symbols.contains($0) }
        watchlists[idx].symbols.append(contentsOf: toAdd)
        toAdd.forEach { prefetchLogo($0) }
    }

    func moveWatchlistItem(from source: IndexSet, to destination: Int) {
        watchlist.move(fromOffsets: source, toOffset: destination)
    }

    func moveWatchlistSymbol(_ symbol: String, toIndex destination: Int) {
        guard let sourceIndex = watchlist.firstIndex(of: symbol),
              destination >= 0, destination < watchlist.count,
              sourceIndex != destination else { return }
        let item = watchlist.remove(at: sourceIndex)
        watchlist.insert(item, at: destination)
    }

    func moveWatchlistSymbol(_ sourceSymbol: String, beforeOrAfter targetSymbol: String) {
        guard sourceSymbol != targetSymbol,
              let srcIndex = watchlist.firstIndex(of: sourceSymbol),
              let tgtIndex = watchlist.firstIndex(of: targetSymbol) else { return }
        let item = watchlist.remove(at: srcIndex)
        let newTargetIndex = watchlist.firstIndex(of: targetSymbol) ?? tgtIndex
        watchlist.insert(item, at: newTargetIndex)
    }

    func reorderWatchlist(fromOffsets source: IndexSet, toOffset destination: Int, currentProjections: [String]) {
        guard !currentProjections.isEmpty else { return }
        if currentProjections == watchlist {
            watchlist.move(fromOffsets: source, toOffset: destination)
            return
        }
        var list = watchlist
        let itemsToMove = source.compactMap { idx in idx < currentProjections.count ? currentProjections[idx] : nil }
        guard !itemsToMove.isEmpty else { return }
        list.removeAll { itemsToMove.contains($0) }
        var targetIndex: Int
        if destination >= currentProjections.count {
            targetIndex = list.count
        } else if destination <= 0 {
            targetIndex = 0
        } else {
            let anchorSymbol = currentProjections[destination]
            targetIndex = list.firstIndex(of: anchorSymbol) ?? list.count
        }
        list.insert(contentsOf: itemsToMove, at: targetIndex)
        watchlist = list
    }

    // MARK: - Multi-watchlist operations

    @discardableResult
    func createWatchlist(name: String) -> Watchlist {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmed.isEmpty ? "Watchlist \(watchlists.count + 1)" : trimmed
        let currentMetrics = watchlistMetrics
        let newWl = Watchlist(id: UUID(), name: finalName, symbols: [], metrics: currentMetrics)
        watchlists.append(newWl)
        selectedWatchlistId = newWl.id
        return newWl
    }

    func renameWatchlist(id: UUID, newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let idx = watchlists.firstIndex(where: { $0.id == id }) else { return }
        watchlists[idx].name = trimmed
    }

    func deleteWatchlist(id: UUID) {
        guard let idx = watchlists.firstIndex(where: { $0.id == id }) else { return }
        watchlists.remove(at: idx)
        if watchlists.isEmpty {
            let def = Watchlist(id: UUID(), name: "Watchlist", symbols: [])
            watchlists = [def]
            selectedWatchlistId = def.id
        } else if selectedWatchlistId == id {
            selectedWatchlistId = watchlists[min(idx, watchlists.count - 1)].id
        }
    }

    func selectWatchlist(id: UUID) {
        guard watchlists.contains(where: { $0.id == id }) else { return }
        selectedWatchlistId = id
    }

    func moveWatchlist(from sourceId: UUID, beforeOrAfter targetId: UUID) {
        guard sourceId != targetId,
              let srcIndex = watchlists.firstIndex(where: { $0.id == sourceId }),
              let tgtIndex = watchlists.firstIndex(where: { $0.id == targetId }) else { return }
        let item = watchlists.remove(at: srcIndex)
        let newTargetIndex = watchlists.firstIndex(where: { $0.id == targetId }) ?? tgtIndex
        watchlists.insert(item, at: newTargetIndex)
    }

    func moveWatchlist(from sourceId: UUID, relativeTo targetId: UUID, placement: InsertPlacement) {
        guard sourceId != targetId,
              let srcIndex = watchlists.firstIndex(where: { $0.id == sourceId }),
              let tgtIndex = watchlists.firstIndex(where: { $0.id == targetId }) else { return }
        var result = watchlists
        let item = result.remove(at: srcIndex)
        let newTargetIndex = result.firstIndex(where: { $0.id == targetId }) ?? tgtIndex
        let insertIndex = placement == .before ? newTargetIndex : newTargetIndex + 1
        guard insertIndex >= 0, insertIndex <= result.count, result != watchlists else { return }
        result.insert(item, at: insertIndex)
        watchlists = result
    }

    func movePortfolio(from sourceId: UUID, beforeOrAfter targetId: UUID) {
        movePortfolio(from: sourceId, relativeTo: targetId, placement: .before)
    }

    func movePortfolio(from sourceId: UUID, relativeTo targetId: UUID, placement: InsertPlacement) {
        guard sourceId != targetId,
              let srcIndex = portfolios.firstIndex(where: { $0.id == sourceId }),
              let tgtIndex = portfolios.firstIndex(where: { $0.id == targetId }) else { return }
        var result = portfolios
        let item = result.remove(at: srcIndex)
        let newTargetIndex = result.firstIndex(where: { $0.id == targetId }) ?? tgtIndex
        let insertIndex = placement == .before ? newTargetIndex : newTargetIndex + 1
        guard insertIndex >= 0, insertIndex <= result.count,
              result.map(\.id) != portfolios.map(\.id) else { return }
        result.insert(item, at: insertIndex)
        portfolios = result
    }

    /// Persists a full reordering of the watchlists built by a local drag
    /// preview. Validates membership so a stale preview never clobbers a
    /// concurrent add/remove/switch.
    func commitWatchlistOrder(_ orderedIds: [UUID]) {
        guard orderedIds.count == watchlists.count,
              Set(orderedIds) == Set(watchlists.map(\.id)) else { return }
        let byId = Dictionary(uniqueKeysWithValues: watchlists.map { ($0.id, $0) })
        watchlists = orderedIds.compactMap { byId[$0] }
    }

    /// Persists a full reordering of the portfolios built by a local drag
    /// preview. Validates membership so a stale preview never clobbers a
    /// concurrent add/remove.
    func commitPortfolioOrder(_ orderedIds: [UUID]) {
        guard orderedIds.count == portfolios.count,
              Set(orderedIds) == Set(portfolios.map(\.id)) else { return }
        let byId = Dictionary(uniqueKeysWithValues: portfolios.map { ($0.id, $0) })
        portfolios = orderedIds.compactMap { byId[$0] }
    }

    func addPortfolio(name: String) {
        portfolios.append(Portfolio(name: name))
    }

    @discardableResult
    func createPortfolio(name: String) -> Portfolio {
        let p = Portfolio(name: name)
        portfolios.append(p)
        return p
    }

    func renamePortfolio(id: UUID, name: String) {
        guard let index = portfolios.firstIndex(where: { $0.id == id }) else { return }
        portfolios[index].name = name
    }

    func deletePortfolio(at offsets: IndexSet) {
        for index in offsets {
            let p = portfolios[index]
            if case .binance(let keyId) = p.sourceType {
                _ = KeychainService.delete(key: "\(keyId)_apiKey")
                _ = KeychainService.delete(key: "\(keyId)_secretKey")
            }
        }
        let removedIds = offsets.map { portfolios[$0].id.uuidString }
        portfolios.remove(atOffsets: offsets)
        removedIds.forEach {
            portfolioNotifications[$0] = nil
            portfolioSnapshots[$0] = nil
        }
    }

    func deletePortfolio(id: UUID) {
        if let p = portfolios.first(where: { $0.id == id }), case .binance(let keyId) = p.sourceType {
            _ = KeychainService.delete(key: "\(keyId)_apiKey")
            _ = KeychainService.delete(key: "\(keyId)_secretKey")
        }
        portfolios.removeAll { $0.id == id }
        portfolioNotifications[id.uuidString] = nil
        portfolioSnapshots[id.uuidString] = nil
    }

    nonisolated static func normalizeBinanceHoldingSymbol(_ symbol: String) -> String {
        let upper = symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        var base = upper
        if upper.hasSuffix("-USD") {
            base = String(upper.dropLast(4))
        }
        if base.hasPrefix("LD") && base.count > 2 {
            base = String(base.dropFirst(2))
        }
        if base.hasPrefix("EQ_") && base.count > 3 {
            base = String(base.dropFirst(3))
        }
        if BinanceStablecoin.isUSDPegged(base) {
            return "\(base)-USD"
        } else if isStandardCryptoSymbol(base) {
            return "\(base)-USD"
        } else if base.contains("-") {
            return base
        } else {
            return base
        }
    }

    /// Normalizes and aggregates Binance holdings by symbol. Holdings with and
    /// without a known cost basis are kept in separate buckets, so a
    /// Spot-reconstructed portion and an untracked remainder of the same symbol
    /// both survive a reload without being merged into one ambiguous lot.
    nonisolated static func aggregateBinanceHoldings(_ holdings: [Holding]) -> [Holding] {
        var aggregated: [String: Holding] = [:]
        for h in holdings {
            let normSym = StorageService.normalizeBinanceHoldingSymbol(h.symbol)
            let hasCost = h.avgPrice.isFinite && h.avgPrice > 0
            let key = normSym + (hasCost ? "|c" : "|n")
            if var existing = aggregated[key] {
                existing.quantity += h.quantity
                aggregated[key] = existing
            } else {
                var newH = h
                newH.symbol = normSym
                aggregated[key] = newH
            }
        }
        return Array(aggregated.values)
    }

    /// Whether a base symbol (e.g. "PEPE", "FDUSD") is a known cryptocurrency
    /// traded on Binance. Symbols that are NOT in this set fall through to Yahoo
    /// Finance, which is less reliable for crypto and can fail for newer tokens.
    /// Whether a symbol is already a native Binance pair (e.g. "BTCUSDT",
    /// "BTCUSDC", "BTCETH"). Detects by checking the trailing quote asset.
    nonisolated static func isBinanceNativePair(_ symbol: String) -> Bool {
        let upper = symbol.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let quoteAssets: Set<String> = ["USDT", "USDC", "BUSD", "DAI", "TUSD", "FDUSD", "USD", "BTC", "ETH", "BNB"]
        guard !BinanceStablecoin.isUSDPegged(upper) else { return false }
        for q in quoteAssets where upper.hasSuffix(q) && upper.count > q.count {
            let base = String(upper.dropLast(q.count))
            if base.count >= 2 && (isStandardCryptoSymbol(base) || base.allSatisfy({ $0.isLetter })) {
                return true
            }
        }
        return false
    }

    nonisolated static func isStandardCryptoSymbol(_ symbol: String) -> Bool {
        let knownCrypto: Set<String> = [
            // Major / Layer 1
            "BTC", "ETH", "SOL", "BNB", "XRP", "ADA", "DOGE", "AVAX",
            "DOT", "LINK", "MATIC", "POL", "SHIB", "LTC", "UNI", "NEAR", "APT", "SUI", "ATOM",
            "TRX", "ETC", "XLM", "BCH", "FIL", "ICP", "HBAR", "VET", "ALGO", "TON",
            "INJ", "SEI", "TIA", "RUNE", "AAVE", "MKR", "CRV", "ENA", "ONDO", "JUP", "PYTH",
            "FET", "RENDER", "TAO", "WLD", "STRK", "METIS",
            "ARB", "OP", "SUI", "HYPE", "HYPER", "DRIFT", "GRASS",
            // Meme coins
            "PEPE", "WIF", "BONK", "FLOKI", "DOGS", "PNUT", "ORDI", "SATS",
            // Stablecoins & USD-pegged (BUSD is legacy but still mapped 1.0)
            "USDT", "USDC", "BUSD", "DAI", "TUSD", "FDUSD", "USDP", "PAXG", "USD",
            // Binance liquid staking / ETH staking wrappers
            "BETH", "WBETH"
        ]
        let upper = symbol.uppercased()
        let clean = upper.hasSuffix("-USD") ? String(upper.dropLast(4)) : upper
        return knownCrypto.contains(clean)
    }

    @discardableResult
    func createBinancePortfolio(name: String, apiKey: String, secretKey: String) async throws -> Portfolio {
        let portfolioId = UUID()
        let keychainId = portfolioId.uuidString

        _ = KeychainService.saveString(apiKey, forKey: "\(keychainId)_apiKey")
        _ = KeychainService.saveString(secretKey, forKey: "\(keychainId)_secretKey")

        let initialHoldings = try await BinanceAPIService.shared.fetchAccountBalances(apiKey: apiKey, secretKey: secretKey)

        let portfolio = Portfolio(
            id: portfolioId,
            name: name,
            holdings: initialHoldings,
            sourceType: .binance(keychainId: keychainId),
            lastSyncedAt: Date()
        )

        portfolios.append(portfolio)
        Task { @MainActor in
            await StockService.shared.refreshAll(storageService: self)
        }
        return portfolio
    }

    func syncBinancePortfolio(id: UUID) async throws {
        guard let index = portfolios.firstIndex(where: { $0.id == id }) else { return }
        let p = portfolios[index]
        guard case .binance(let keychainId) = p.sourceType else { return }

        guard let apiKey = KeychainService.loadString(forKey: "\(keychainId)_apiKey"),
              let secretKey = KeychainService.loadString(forKey: "\(keychainId)_secretKey") else {
            throw BinanceAPIError.invalidCredentials
        }

        let holdings = try await BinanceAPIService.shared.fetchAccountBalances(apiKey: apiKey, secretKey: secretKey)

        portfolios[index].holdings = holdings
        portfolios[index].lastSyncedAt = Date()
        Task { @MainActor in
            await StockService.shared.refreshAll(storageService: self)
        }
    }

    /// Syncs all configured Binance read-only portfolios in parallel.
    func syncAllBinancePortfolios() async {
        let binancePortfolios = portfolios.filter { $0.isReadOnly }
        guard !binancePortfolios.isEmpty else { return }
        for portfolio in binancePortfolios {
            do {
                try await syncBinancePortfolio(id: portfolio.id)
            } catch {
                print("[StockDeck] Binance sync failed for \(portfolio.name): \(error.localizedDescription)")
            }
        }
    }

    /// Returns credentials for the first configured Binance read-only portfolio.
    /// Market quotes are public account-scoped data, while the API key is still
    /// required by Binance's Stocks Trading market-data endpoint.
    func firstBinanceCredentials() -> (apiKey: String, secretKey: String)? {
        for portfolio in portfolios {
            guard case .binance(let keychainId) = portfolio.sourceType,
                  let apiKey = KeychainService.loadString(forKey: "\(keychainId)_apiKey"),
                  let secretKey = KeychainService.loadString(forKey: "\(keychainId)_secretKey") else { continue }
            return (apiKey, secretKey)
        }
        return nil
    }

    func addHolding(to portfolioId: UUID, symbol: String, quantity: Double, avgPrice: Double, purchaseDate: Date? = nil, leverage: Double? = nil) {
        guard let index = portfolios.firstIndex(where: { $0.id == portfolioId }),
              !portfolios[index].isReadOnly else { return }
        let holding = Holding(symbol: symbol, quantity: quantity, avgPrice: avgPrice, purchaseDate: purchaseDate, leverage: leverage)
        portfolios[index].holdings.append(holding)

        let cleanSymbol = symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let scale = StockService.isJapaneseMutualFund(cleanSymbol) ? 10000.0 : 1.0
        let tx = Transaction(
            date: purchaseDate ?? Date(),
            symbol: cleanSymbol,
            type: .buy,
            quantity: quantity,
            price: avgPrice,
            amount: (quantity * avgPrice) / scale,
            currency: StockService.detectedCurrency(for: cleanSymbol),
            notes: "Manual position add"
        )
        portfolios[index].transactions.insert(tx, at: 0)

        prefetchLogo(symbol)
    }

    func addHoldingsBatch(_ newHoldings: [Holding], to portfolioId: UUID) {
        guard let pIndex = portfolios.firstIndex(where: { $0.id == portfolioId }),
              !portfolios[pIndex].isReadOnly else { return }

        var currentHoldings = portfolios[pIndex].holdings

        for newH in newHoldings {
            var symbol = newH.symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            guard !symbol.isEmpty else { continue }
            let jpStockRegex = "^[0-9]{3}[0-9A-Z]$"
            if symbol.count == 4 && symbol.range(of: jpStockRegex, options: .regularExpression) != nil {
                symbol += ".T"
            }

            // Exact fingerprint match (account + symbol + date + qty + avg price).
            // Re-importing a cumulative trade-history file must never double-count
            // an identical transaction; two accounts buying the same fund on the
            // same day are kept apart by their account name.
            let isExactDuplicate = currentHoldings.contains {
                $0.symbol == symbol
                    && $0.account == newH.account
                    && ($0.purchaseDate == newH.purchaseDate || ($0.purchaseDate == nil && newH.purchaseDate == nil))
                    && abs($0.quantity - newH.quantity) < 1e-9
                    && ($0.avgPrice.isNaN || newH.avgPrice.isNaN || abs($0.avgPrice - newH.avgPrice) < 1e-6)
            }
            if isExactDuplicate { continue }

            if let existingIndex = currentHoldings.firstIndex(where: {
                $0.symbol == symbol
                    && $0.account == newH.account
                    && ($0.purchaseDate == newH.purchaseDate || ($0.purchaseDate == nil && newH.purchaseDate == nil))
            }) {
                let existing = currentHoldings[existingIndex]
                let totalQty = existing.quantity + newH.quantity
                if abs(totalQty) > 1e-9 {
                    let totalCost = (existing.quantity * existing.avgPrice) + (newH.quantity * newH.avgPrice)
                    let newAvg = totalCost / totalQty
                    currentHoldings[existingIndex].quantity = totalQty
                    currentHoldings[existingIndex].avgPrice = newAvg
                } else {
                    currentHoldings.remove(at: existingIndex)
                }
            } else {
                var cleanHolding = newH
                cleanHolding.symbol = symbol
                currentHoldings.append(cleanHolding)
            }
        }

        portfolios[pIndex].holdings = currentHoldings
        Set(currentHoldings.map(\.symbol)).forEach { prefetchLogo($0) }
    }

    private func prefetchLogo(_ symbol: String) {
        guard StockService.isVietnameseStock(symbol, exchange: exchange(for: symbol)) else { return }
        Task { await LogoCache.shared.ensureLogo(for: symbol) }
    }

    func removeHolding(from portfolioId: UUID, holdingId: UUID) {
        guard let pIndex = portfolios.firstIndex(where: { $0.id == portfolioId }),
              !portfolios[pIndex].isReadOnly else { return }
        portfolios[pIndex].holdings.removeAll { $0.id == holdingId }
    }

    func moveHolding(holdingId: UUID, from sourcePortfolioId: UUID, to targetPortfolioId: UUID) {
        guard sourcePortfolioId != targetPortfolioId,
              let sIndex = portfolios.firstIndex(where: { $0.id == sourcePortfolioId }),
              let tIndex = portfolios.firstIndex(where: { $0.id == targetPortfolioId }),
              let hIndex = portfolios[sIndex].holdings.firstIndex(where: { $0.id == holdingId })
        else { return }
        let holding = portfolios[sIndex].holdings.remove(at: hIndex)
        portfolios[tIndex].holdings.append(holding)
    }


    func updateHolding(in portfolioId: UUID, holdingId: UUID, symbol: String? = nil, quantity: Double, avgPrice: Double, purchaseDate: Date? = nil, leverage: Double? = nil) {
        guard let pIndex = portfolios.firstIndex(where: { $0.id == portfolioId }),
              !portfolios[pIndex].isReadOnly,
              let hIndex = portfolios[pIndex].holdings.firstIndex(where: { $0.id == holdingId })
        else { return }
        if let newSymbol = symbol, !newSymbol.trimmingCharacters(in: .whitespaces).isEmpty {
            portfolios[pIndex].holdings[hIndex].symbol = newSymbol.trimmingCharacters(in: .whitespaces).uppercased()
        }
        portfolios[pIndex].holdings[hIndex].quantity = quantity
        portfolios[pIndex].holdings[hIndex].avgPrice = avgPrice
        portfolios[pIndex].holdings[hIndex].purchaseDate = purchaseDate
        portfolios[pIndex].holdings[hIndex].leverage = leverage
    }

    func addClosedTradesBatch(_ newTrades: [ClosedTrade], to portfolioId: UUID) {
        guard let pIndex = portfolios.firstIndex(where: { $0.id == portfolioId }),
              !portfolios[pIndex].isReadOnly else { return }

        var currentClosed = portfolios[pIndex].closedTrades
        for newT in newTrades {
            let isDuplicate = currentClosed.contains {
                $0.id == newT.id || (
                    $0.symbol.caseInsensitiveCompare(newT.symbol) == .orderedSame
                    && abs($0.quantity - newT.quantity) < 1e-6
                    && abs($0.buyPrice - newT.buyPrice) < 1e-4
                    && abs($0.sellPrice - newT.sellPrice) < 1e-4
                    && $0.sellDate == newT.sellDate
                    && $0.buyDate == newT.buyDate
                )
            }
            if !isDuplicate {
                currentClosed.append(newT)
            }
        }
        portfolios[pIndex].closedTrades = currentClosed
    }

    func removeClosedTrade(from portfolioId: UUID, tradeId: UUID) {
        removeClosedTrades(from: portfolioId, tradeIds: [tradeId])
    }

    func removeClosedTrades(from portfolioId: UUID, tradeIds: Set<UUID>) {
        guard let pIndex = portfolios.firstIndex(where: { $0.id == portfolioId }),
              !portfolios[pIndex].isReadOnly else { return }
        portfolios[pIndex].closedTrades.removeAll { tradeIds.contains($0.id) }
    }

    func addTransactionsBatch(_ newTransactions: [Transaction], to portfolioId: UUID) {
        guard let pIndex = portfolios.firstIndex(where: { $0.id == portfolioId }),
              !portfolios[pIndex].isReadOnly else { return }

        var currentTransactions = portfolios[pIndex].transactions
        var existingSignatures = Set(currentTransactions.map { $0.signature })
        existingSignatures.formUnion(currentTransactions.map { $0.id.uuidString })

        for tx in newTransactions {
            if !existingSignatures.contains(tx.signature) && !existingSignatures.contains(tx.id.uuidString) {
                currentTransactions.append(tx)
                existingSignatures.insert(tx.signature)
                existingSignatures.insert(tx.id.uuidString)
            }
        }
        // Sort chronologically descending (newest first)
        currentTransactions.sort { $0.date > $1.date }
        portfolios[pIndex].transactions = currentTransactions
    }

    func removeTransaction(from portfolioId: UUID, transactionId: UUID) {
        removeTransactions(from: portfolioId, transactionIds: [transactionId])
    }

    func removeTransactions(from portfolioId: UUID, transactionIds: Set<UUID>) {
        guard let pIndex = portfolios.firstIndex(where: { $0.id == portfolioId }),
              !portfolios[pIndex].isReadOnly else { return }
        portfolios[pIndex].transactions.removeAll { transactionIds.contains($0.id) }
    }

    func updateTransaction(in portfolioId: UUID, transaction: Transaction) {
        guard let pIndex = portfolios.firstIndex(where: { $0.id == portfolioId }),
              !portfolios[pIndex].isReadOnly,
              let tIndex = portfolios[pIndex].transactions.firstIndex(where: { $0.id == transaction.id })
        else { return }
        portfolios[pIndex].transactions[tIndex] = transaction
    }

    func recordSellTrade(
        portfolioId: UUID,
        holdingId: UUID,
        sellQuantity: Double,
        sellPrice: Double,
        sellDate: Date
    ) {
        guard let pIndex = portfolios.firstIndex(where: { $0.id == portfolioId }),
              !portfolios[pIndex].isReadOnly,
              let hIndex = portfolios[pIndex].holdings.firstIndex(where: { $0.id == holdingId })
        else { return }

        let holding = portfolios[pIndex].holdings[hIndex]
        let qtyToClose = min(abs(holding.quantity), abs(sellQuantity))
        guard qtyToClose > 0 else { return }

        let closedTrade = ClosedTrade(
            symbol: holding.symbol,
            quantity: qtyToClose,
            buyPrice: holding.avgPrice,
            sellPrice: sellPrice,
            buyDate: holding.purchaseDate,
            sellDate: sellDate,
            account: holding.account,
            leverage: holding.leverage
        )

        portfolios[pIndex].closedTrades.append(closedTrade)

        let cleanSymbol = holding.symbol.uppercased()
        let scale = StockService.isJapaneseMutualFund(cleanSymbol) ? 10000.0 : 1.0
        let tx = Transaction(
            date: sellDate,
            symbol: cleanSymbol,
            type: .sell,
            quantity: qtyToClose,
            price: sellPrice,
            amount: (qtyToClose * sellPrice) / scale,
            currency: StockService.detectedCurrency(for: cleanSymbol),
            account: holding.account,
            notes: "Manual position sell"
        )
        portfolios[pIndex].transactions.insert(tx, at: 0)

        let remainingQty = holding.quantity - qtyToClose
        if abs(remainingQty) < 1e-6 {
            portfolios[pIndex].holdings.remove(at: hIndex)
        } else {
            portfolios[pIndex].holdings[hIndex].quantity = remainingQty
        }
    }

    /// Reconstructs ledger transactions from closed trades and active holdings.
    static func reconstructTransactions(fromClosedTrades closedTrades: [ClosedTrade], holdings: [Holding]) -> [Transaction] {
        var results: [Transaction] = []

        // 1. Recover from closed trades (Buy & Sell fills)
        for ct in closedTrades {
            guard ct.quantity > 0 else { continue }
            let scale = StockService.isJapaneseMutualFund(ct.symbol) ? 10000.0 : 1.0
            if let bDate = ct.buyDate, ct.buyPrice > 0 {
                let buyTx = Transaction(
                    date: bDate,
                    symbol: ct.symbol,
                    type: .buy,
                    quantity: ct.quantity,
                    price: ct.buyPrice,
                    amount: (ct.quantity * ct.buyPrice) / scale,
                    currency: StockService.detectedCurrency(for: ct.symbol),
                    account: ct.account,
                    notes: "Historical trade fill"
                )
                results.append(buyTx)
            }
            if let sDate = ct.sellDate, ct.sellPrice > 0 {
                let sellTx = Transaction(
                    date: sDate,
                    symbol: ct.symbol,
                    type: .sell,
                    quantity: ct.quantity,
                    price: ct.sellPrice,
                    amount: (ct.quantity * ct.sellPrice) / scale,
                    currency: StockService.detectedCurrency(for: ct.symbol),
                    account: ct.account,
                    notes: "Historical trade fill"
                )
                results.append(sellTx)
            }
        }

        // 2. Recover from active holdings (Buy fills)
        for h in holdings {
            guard h.quantity > 0 else { continue }
            let price = max(0.0, h.avgPrice.isNaN ? 0.0 : h.avgPrice)
            let scale = StockService.isJapaneseMutualFund(h.symbol) ? 10000.0 : 1.0
            let buyTx = Transaction(
                date: h.purchaseDate ?? Date(),
                symbol: h.symbol,
                type: .buy,
                quantity: h.quantity,
                price: price,
                amount: (h.quantity * price) / scale,
                currency: StockService.detectedCurrency(for: h.symbol),
                account: h.account,
                notes: "Active position fill"
            )
            results.append(buyTx)
        }

        results.sort { $0.date > $1.date }
        return results
    }

    /// Automatically backfills ledger transactions if a manual portfolio has 0 transactions but has holdings or closed trades.
    @discardableResult
    func migrateEmptyTransactionsIfNeeded() -> Bool {
        var didMigrate = false
        for i in 0..<portfolios.count {
            guard !portfolios[i].isReadOnly else { continue }
            guard portfolios[i].transactions.isEmpty else { continue }
            guard !portfolios[i].closedTrades.isEmpty || !portfolios[i].holdings.isEmpty else { continue }

            let recovered = StorageService.reconstructTransactions(
                fromClosedTrades: portfolios[i].closedTrades,
                holdings: portfolios[i].holdings
            )
            guard !recovered.isEmpty else { continue }
            portfolios[i].transactions = recovered
            didMigrate = true
        }
        return didMigrate
    }

    func resetToDefaults() {
        preferredCurrency = "EUR"
        stockPriceCurrency = ""
        showExtendedHours = true
        showCompanyName = true
        showWatchlistSparkline = true
        showDayRange = true
        show52WeekBar = true
        showAbsoluteChange = false
        showInsiderMarkers = true
        menuBarDisplay = "pnl"
        gainColorHex = ""
        lossColorHex = ""
        percentDecimals = 1
        valueDecimals = -1
        menuBarHidePercent = false
        tickerShowName = false
        advancedPositions = false
        defaultChartStyle = "line"
        watchlistSort = "manual"
        appLanguage = "en"
        fontSizeLevel = 9
        fontFamily = "Inter Variable"
        appearanceRaw = AppearanceMode.default.rawValue
        symbolNotes = [:]
        lastSelectedTab = "Watchlists"
        UserDefaults.standard.removeObject(forKey: "lastSelectedTab")
        aiBaseURL = "https://api.openai.com/v1"
        aiModel = "gpt-4o-mini"
        aiProvider = "openai"
        cachedModelsByProvider = [:]
        aiWorkspacePath = ""
        aiDeepseekThinking = false
        menuBarShortcut = nil
        desktopAppShortcut = nil
        if launchAtLogin {
            launchAtLogin = false
        }
    }

    /// Completely wipes all portfolios, watchlists, alerts, and settings back to a clean slate.
    func clearAllAppData() {
        portfolios = []
        watchlists = [Watchlist(id: UUID(), name: "Watchlist", symbols: [])]
        selectedWatchlistId = watchlists.first?.id
        watchlist = []
        alerts = []
        symbolNotes = [:]
        portfolioNotifications = [:]
        portfolioSnapshots = [:]
        portfolioChartRanges = [:]
        portfolioDailyPnlRanges = [:]
        portfolioMonthlyPnlRanges = [:]
        portfolioPnlViewModes = [:]
        portfolioPositionSorts = [:]
        resetToDefaults()
        saveNow()
    }

    // MARK: - Export / Import

    struct PortfolioExport: Codable {
        var version: Int = 1
        var exportDate: Date
        var portfolios: [Portfolio]
    }

    func exportPortfolios(_ portfoliosToExport: [Portfolio]) -> Data? {
        let export = PortfolioExport(exportDate: Date(), portfolios: portfoliosToExport)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(export)
    }

    static func importPortfolios(from data: Data) -> [Portfolio]? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let export = try? decoder.decode(PortfolioExport.self, from: data) else { return nil }
        return export.portfolios
    }

    func importPortfolios(from data: Data) -> [Portfolio]? {
        Self.importPortfolios(from: data)
    }

    func mergeImportedPortfolios(_ imported: [Portfolio]) {
        for var portfolio in imported {
            portfolio.id = UUID()
            for i in portfolio.holdings.indices {
                portfolio.holdings[i].id = UUID()
            }
            let baseName = portfolio.name
            var name = baseName
            var counter = 2
            while portfolios.contains(where: { $0.name == name }) {
                name = "\(baseName) (\(counter))"
                counter += 1
            }
            portfolio.name = name
            portfolios.append(portfolio)
        }
    }

    // MARK: - Persistence

    struct AppData: Codable {
        var watchlist: [String]
        var watchlists: [Watchlist]?
        var selectedWatchlistId: UUID?
        var portfolioColumns: [String]?
        var portfolios: [Portfolio]
        var preferredCurrency: String?
        var stockPriceCurrency: String?
        var showExtendedHours: Bool?
        var menuBarDisplay: String?
        var isinMap: [String: String]?
        var fontSizeLevel: Int?
        var fontFamily: String?
        var alerts: [PriceAlert]?
        var symbolNotes: [String: [SymbolNote]]?
        var showCompanyName: Bool?
        var showWatchlistSparkline: Bool?
        var showDayRange: Bool?
        var show52WeekBar: Bool?
        var showAbsoluteChange: Bool?
        var showInsiderMarkers: Bool?
        var portfolioNotifications: [String: [PortfolioNotification]]?
        var portfolioSnapshots: [String: [PortfolioSnapshot]]?
        var portfolioChartRanges: [String: String]?
        var portfolioDailyPnlRanges: [String: String]?
        var portfolioMonthlyPnlRanges: [String: String]?
        var portfolioPnlViewModes: [String: String]?
        var discordWebhookURL: String?
        var discordEnabled: Bool?
        var gainColorHex: String?
        var lossColorHex: String?
        var percentTwoDecimals: Bool?   // legacy (pre-#10) — migrated on decode
        var percentDecimals: Int?
        var valueDecimals: Int?
        var menuBarHidePercent: Bool?
        var tickerShowName: Bool?
        var watchlistSort: String?
        var symbolType: [String: String]?
        var symbolExchange: [String: String]?
        var appLanguage: String?
        var advancedPositions: Bool?
        var defaultChartStyle: String?
        var appearanceRaw: String?
        var showNewsTab: Bool?
        var aiChatSections: [AIChatSection]?
        var aiBaseURL: String?
        var aiModel: String?
        var aiProvider: String?
        var cachedModelsByProvider: [String: [String]]?
        var aiWorkspacePath: String?
        var aiDeepseekThinking: Bool?
        var investorProfile: InvestorProfile?
        var lastStockChartRange: String?
        var portfolioPositionSorts: [String: String]?
        var lastSelectedTab: String?
        var menuBarShortcut: MenuBarShortcut?
        var desktopAppShortcut: MenuBarShortcut?
        var iCloudSyncEnabled: Bool?
        var lastiCloudSyncDate: Date?
    }

    func exportAppData() -> AppData {
        AppData(
            watchlist: watchlist,
            watchlists: watchlists,
            selectedWatchlistId: selectedWatchlistId,
            portfolioColumns: portfolioColumns?.map(\.rawValue),
            portfolios: portfolios,
            preferredCurrency: preferredCurrency,
            stockPriceCurrency: stockPriceCurrency,
            showExtendedHours: showExtendedHours,
            menuBarDisplay: menuBarDisplay,
            isinMap: isinMap,
            fontSizeLevel: fontSizeLevel,
            fontFamily: fontFamily,
            alerts: alerts,
            symbolNotes: symbolNotes.isEmpty ? nil : symbolNotes,
            showCompanyName: showCompanyName,
            showWatchlistSparkline: showWatchlistSparkline,
            showDayRange: showDayRange,
            show52WeekBar: show52WeekBar,
            showAbsoluteChange: showAbsoluteChange,
            showInsiderMarkers: showInsiderMarkers,
            portfolioNotifications: portfolioNotifications,
            portfolioSnapshots: portfolioSnapshots,
            portfolioChartRanges: portfolioChartRanges,
            portfolioDailyPnlRanges: portfolioDailyPnlRanges,
            portfolioMonthlyPnlRanges: portfolioMonthlyPnlRanges,
            portfolioPnlViewModes: portfolioPnlViewModes,
            discordWebhookURL: discordWebhookURL,
            discordEnabled: discordEnabled,
            gainColorHex: gainColorHex,
            lossColorHex: lossColorHex,
            percentTwoDecimals: nil,
            percentDecimals: percentDecimals,
            valueDecimals: valueDecimals,
            menuBarHidePercent: menuBarHidePercent,
            tickerShowName: tickerShowName,
            watchlistSort: watchlistSort,
            symbolType: symbolType,
            symbolExchange: symbolExchange,
            appLanguage: appLanguage,
            advancedPositions: advancedPositions,
            defaultChartStyle: defaultChartStyle,
            appearanceRaw: appearanceRaw,
            showNewsTab: nil,
            aiChatSections: aiChatSections,
            aiBaseURL: aiBaseURL,
            aiModel: aiModel,
            aiProvider: aiProvider,
            cachedModelsByProvider: cachedModelsByProvider.isEmpty ? nil : cachedModelsByProvider,
            aiWorkspacePath: aiWorkspacePath,
            aiDeepseekThinking: aiDeepseekThinking,
            investorProfile: investorProfile,
            lastStockChartRange: lastStockChartRange,
            portfolioPositionSorts: portfolioPositionSorts,
            lastSelectedTab: lastSelectedTab,
            menuBarShortcut: menuBarShortcut,
            desktopAppShortcut: desktopAppShortcut,
            iCloudSyncEnabled: iCloudSyncEnabled,
            lastiCloudSyncDate: lastiCloudSyncDate
        )
    }

    func applyAppData(_ decoded: AppData, isFromSync: Bool = false) {
        if isFromSync {
            isLoading = true
        }
        if let wls = decoded.watchlists, !wls.isEmpty {
            var seenNames = Set<String>()
            var cleaned: [Watchlist] = []
            for wl in wls {
                let trimmed = wl.name.trimmingCharacters(in: .whitespacesAndNewlines)
                let key = trimmed.lowercased()
                if !wl.symbols.isEmpty {
                    if !seenNames.contains(key) {
                        cleaned.append(wl)
                        seenNames.insert(key)
                    }
                } else if !seenNames.contains(key) && !key.starts(with: "list ") {
                    cleaned.append(wl)
                    seenNames.insert(key)
                }
            }
            if cleaned.count > 1 {
                cleaned.removeAll { $0.symbols.isEmpty && $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "watchlist" }
            }
            watchlists = cleaned.isEmpty ? wls : cleaned
            if let selId = decoded.selectedWatchlistId, watchlists.contains(where: { $0.id == selId }) {
                selectedWatchlistId = selId
            } else {
                selectedWatchlistId = watchlists.first?.id
            }
        } else if !decoded.watchlist.isEmpty {
            let def = Watchlist(id: UUID(), name: "Watchlist", symbols: decoded.watchlist)
            watchlists = [def]
            selectedWatchlistId = def.id
        } else if watchlists.isEmpty {
            let def = Watchlist(id: UUID(), name: "Watchlist", symbols: [])
            watchlists = [def]
            selectedWatchlistId = def.id
        }
        portfolios = decoded.portfolios.map { p in
            var updated = p
            if updated.isReadOnly {
                updated.holdings = StorageService.aggregateBinanceHoldings(updated.holdings)
            } else {
                var seenHoldingIDs = Set<UUID>()
                var uniqueHoldings: [Holding] = []
                for h in updated.holdings {
                    if !seenHoldingIDs.contains(h.id) {
                        seenHoldingIDs.insert(h.id)
                        var newH = h
                        if newH.symbol.hasSuffix("-USD") {
                            let base = String(newH.symbol.dropLast(4))
                            if !StorageService.isStandardCryptoSymbol(base) {
                                newH.symbol = base
                            }
                        }
                        uniqueHoldings.append(newH)
                    }
                }
                updated.holdings = uniqueHoldings
            }
            return updated
        }
        preferredCurrency = decoded.preferredCurrency ?? "EUR"
        stockPriceCurrency = decoded.stockPriceCurrency ?? ""
        showExtendedHours = decoded.showExtendedHours ?? true
        menuBarDisplay = decoded.menuBarDisplay ?? "pnl"
        isinMap = decoded.isinMap ?? [:]
        alerts = decoded.alerts ?? []
        symbolNotes = decoded.symbolNotes ?? [:]
        portfolioNotifications = decoded.portfolioNotifications ?? [:]
        portfolioSnapshots = decoded.portfolioSnapshots ?? [:]
        portfolioChartRanges = decoded.portfolioChartRanges ?? [:]
        portfolioDailyPnlRanges = decoded.portfolioDailyPnlRanges ?? [:]
        portfolioMonthlyPnlRanges = decoded.portfolioMonthlyPnlRanges ?? [:]
        portfolioPnlViewModes = decoded.portfolioPnlViewModes ?? [:]
        discordWebhookURL = decoded.discordWebhookURL ?? ""
        discordEnabled = decoded.discordEnabled ?? false
        gainColorHex = decoded.gainColorHex ?? ""
        lossColorHex = decoded.lossColorHex ?? ""
        percentDecimals = decoded.percentDecimals ?? (decoded.percentTwoDecimals == true ? 2 : 1)
        valueDecimals = decoded.valueDecimals ?? -1
        menuBarHidePercent = decoded.menuBarHidePercent ?? false
        tickerShowName = decoded.tickerShowName ?? false
        advancedPositions = decoded.advancedPositions ?? false
        defaultChartStyle = decoded.defaultChartStyle ?? "line"
        watchlistSort = decoded.watchlistSort ?? "manual"
        symbolType = decoded.symbolType ?? [:]
        symbolExchange = decoded.symbolExchange ?? [:]
        appLanguage = decoded.appLanguage ?? "en"
        showCompanyName = decoded.showCompanyName ?? true
        showWatchlistSparkline = decoded.showWatchlistSparkline ?? true
        showDayRange = decoded.showDayRange ?? true
        show52WeekBar = decoded.show52WeekBar ?? true
        showAbsoluteChange = decoded.showAbsoluteChange ?? false
        showInsiderMarkers = decoded.showInsiderMarkers ?? true
        fontSizeLevel = decoded.fontSizeLevel ?? 9
        fontFamily = decoded.fontFamily ?? "Inter Variable"
        appearanceRaw = decoded.appearanceRaw ?? AppearanceMode.default.rawValue
        aiChatSections = decoded.aiChatSections ?? []
        aiBaseURL = decoded.aiBaseURL ?? "https://api.openai.com/v1"
        aiModel = decoded.aiModel ?? "gpt-4o-mini"
        aiProvider = decoded.aiProvider ?? "openai"
        cachedModelsByProvider = decoded.cachedModelsByProvider ?? [:]
        aiWorkspacePath = decoded.aiWorkspacePath ?? ""
        aiDeepseekThinking = decoded.aiDeepseekThinking ?? false
        investorProfile = decoded.investorProfile
        lastStockChartRange = decoded.lastStockChartRange ?? "1M"
        portfolioPositionSorts = decoded.portfolioPositionSorts ?? [:]
        if let tab = decoded.lastSelectedTab ?? UserDefaults.standard.string(forKey: "lastSelectedTab") {
            lastSelectedTab = (tab == "Watchlist") ? "Watchlists" : tab
        }
        menuBarShortcut = decoded.menuBarShortcut
        desktopAppShortcut = decoded.desktopAppShortcut
        let decodedColumns = decoded.portfolioColumns?.compactMap(PortfolioColumnMetric.init(rawValue:))
        portfolioColumns = (decodedColumns?.isEmpty == false) ? decodedColumns : nil
        if let syncEnabled = decoded.iCloudSyncEnabled {
            iCloudSyncEnabled = syncEnabled
        }
        if let syncDate = decoded.lastiCloudSyncDate {
            lastiCloudSyncDate = syncDate
        }
        FontRegistration.familyName = fontFamily
        FontRegistration.sizeOffset = CGFloat(fontSizeLevel - 9)

        if isFromSync {
            migrateEmptyTransactionsIfNeeded()
            isLoading = false
            performSave()
        }
    }

    private func scheduleSave() {
        guard !isLoading, !decodeFailure else { return }
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard !Task.isCancelled else { return }
            self.performSave()
            if self.isSharedInstance && self.iCloudSyncEnabled {
                iCloudSyncService.shared.schedulePush()
            }
        }
    }

    private func performSave() {
        let bakURL = fileURL.appendingPathExtension("bak")
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try? FileManager.default.removeItem(at: bakURL)
            try? FileManager.default.copyItem(at: fileURL, to: bakURL)
        }
        let data = exportAppData()
        do {
            let encoded = try JSONEncoder().encode(data)
            try encoded.write(to: fileURL, options: .atomic)
        } catch {
            // Error saving is non-fatal; data will be retried on next change
        }
    }

    func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        performSave()
        if isSharedInstance && iCloudSyncEnabled {
            iCloudSyncService.shared.pushLocalData()
        }
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoded = try JSONDecoder().decode(AppData.self, from: data)
            applyAppData(decoded, isFromSync: false)
            if migrateEmptyTransactionsIfNeeded() {
                performSave()
            }
        } catch {
            decodeFailure = true
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            let ts = formatter.string(from: Date())
            let corruptedURL = fileURL
                .deletingPathExtension()
                .appendingPathExtension("corrupted-\(ts).json")
            try? FileManager.default.moveItem(at: fileURL, to: corruptedURL)
            print("[StorageService] Corrupted data.json moved to \(corruptedURL.lastPathComponent). The app will start with defaults and will NOT auto-save until you make an explicit change.")
        }
    }
}
