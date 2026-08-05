import Foundation

struct Watchlist: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String
    var symbols: [String]
    /// Nil keeps imported/older watchlists on the default layout.
    var metrics: [WatchlistMetric]? = nil
}

@MainActor
class StorageService: ObservableObject {
    static let shared = StorageService()

    @Published var watchlists: [Watchlist] = [Watchlist(id: UUID(), name: "Watchlist", symbols: [])] {
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
        currentWatchlist.metrics ?? WatchlistMetric.defaultSelection
    }

    func setWatchlistMetrics(_ metrics: [WatchlistMetric]) {
        objectWillChange.send()
        var updated = watchlists
        for index in updated.indices {
            updated[index].metrics = metrics
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
    @Published var showDayRange: Bool = true {
        didSet { scheduleSave() }
    }
    @Published var show52WeekBar: Bool = true {
        didSet { scheduleSave() }
    }
    @Published var showAbsoluteChange: Bool = true {
        didSet { scheduleSave() }
    }

    // MARK: - Appearance & tabs (issue #11)
    /// "system" | "light" | "dark". The 1.9.0 redesign forced light; this restores
    /// the choice. Read through `appearanceMode` for the typed value.
    @Published var appearanceRaw: String = AppearanceMode.default.rawValue {
        didSet { scheduleSave() }
    }
    /// Show the Home/News tab. Off = the tab is hidden entirely (no fetching, no
    /// tab), for users who want just their watchlist and portfolio.
    @Published var showNewsTab: Bool = true {
        didSet { scheduleSave() }
    }

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

    // MARK: - Menu bar colors (issue #7.1)
    /// Hex color for gains/up moves. Empty = use the system green (dynamic).
    @Published var gainColorHex: String = "" {
        didSet { scheduleSave() }
    }
    /// Hex color for losses/down moves. Empty = use the system red (dynamic).
    @Published var lossColorHex: String = "" {
        didSet { scheduleSave() }
    }
    /// When true, the menu bar ignores gain/loss colors and uses the system label
    /// color (always readable on any background; direction stays in the +/- and ▲▼).
    @Published var menuBarUseSystemColor: Bool = false {
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

    /// Records a symbol's asset class. Ignores empty values and no-ops when
    /// unchanged so it doesn't churn the save loop on every price refresh.
    func setType(_ type: String, for symbol: String) {
        let normalized = type.uppercased()
        guard !normalized.isEmpty, symbolType[symbol] != normalized else { return }
        symbolType[symbol] = normalized
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

    /// Discord/Slack incoming webhook for mirroring notifications.
    @Published var discordWebhookURL: String = "" {
        didSet { scheduleSave() }
    }
    @Published var discordEnabled: Bool = false {
        didSet { scheduleSave() }
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

    var lastSelectedTab: String = "Watchlist"

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
    nonisolated static func formatNumber(_ value: Double, decimals: Int, locale: Locale = .autoupdatingCurrent) -> String {
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
        let fracDigits = parts.count > 1 ? String(parts[1]) : ""

        var grouped = ""
        var count = 0
        for ch in intDigits.reversed() {
            if count > 0 && count % 3 == 0 { grouped.append(contentsOf: groupSep.reversed()) }
            grouped.append(ch)
            count += 1
        }
        var result = String(grouped.reversed())
        if decimals > 0 { result += decSep + fracDigits }
        return (value < 0 ? "-" : "") + result
    }

    /// Formats an amount with the currency symbol *before* the figure, e.g.
    /// "€1,234.56", "+€820.00", "-€540.00". The sign (when shown) precedes the symbol.
    nonisolated static func formatAmount(_ value: Double, symbol: String, decimals: Int = 2, signed: Bool = false,
                             locale: Locale = .autoupdatingCurrent) -> String {
        // When the numeric value is not finite (NaN/Inf), show a dash so the UI
        // doesn't display "NaN" for P&L or cost when a holding has unknown cost.
        guard value.isFinite else { return "-" }
        let sign = signed ? (value >= 0 ? "+" : "-") : (value < 0 ? "-" : "")
        let magnitude = formatNumber(abs(value), decimals: decimals, locale: locale)
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

    static func currencySymbol(for code: String) -> String {
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
    static func formatCompactNumber(_ value: Double, decimals: Int? = nil) -> String {
        let absVal = abs(value)
        let sign = value < 0 ? "-" : ""
        if absVal >= 1_000_000 {
            let m = absVal / 1_000_000
            return "\(sign)\(String(format: m >= 10 ? "%.1fM" : "%.2fM", m))"
        } else if absVal >= 10_000 {
            let k = absVal / 1_000
            return "\(sign)\(String(format: k >= 100 ? "%.0fK" : "%.1fK", k))"
        } else {
            return formatNumber(value, decimals: decimals ?? 0)
        }
    }

    /// Formats an amount compactly with K/M suffixes when ≥ 10,000.
    /// When the value is below the compact threshold and `decimals` is provided,
    /// that decimal count is used so small numbers still respect the user's setting.
    static func formatCompactAmount(_ value: Double, symbol: String, signed: Bool = false, decimals: Int? = nil) -> String {
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
            return formatAmount(value, symbol: symbol, decimals: decimals ?? 0, signed: signed)
        }
    }

    /// Formats market capitalization in compact T/B/M scale with currency symbol.
    /// e.g. Apple → "$3.50T", Toyota → "¥45.2B", small cap → "$850M"
    static func formatMarketCap(_ value: Double, currency: String) -> String {
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
    private var isLoading = false
    private var decodeFailure = false
    private var saveTask: Task<Void, Never>?

    init(fileURL: URL? = nil) {
        if let customURL = fileURL {
            self.fileURL = customURL
        } else {
            guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
                let fallback = FileManager.default.temporaryDirectory
                self.fileURL = fallback.appendingPathComponent("StockDeck_data.json")
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
        isLoading = false
    }

    func addToWatchlist(_ symbol: String, targetWatchlistId: UUID? = nil) {
        let activeId = targetWatchlistId ?? currentWatchlist.id
        guard let idx = watchlists.firstIndex(where: { $0.id == activeId }) else { return }
        guard !watchlists[idx].symbols.contains(symbol) else { return }
        watchlists[idx].symbols.append(symbol)
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
        for s in symbols {
            if !watchlists[idx].symbols.contains(s) {
                watchlists[idx].symbols.append(s)
            }
        }
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
        if BinanceStablecoin.isUSDPegged(base) {
            return "\(base)-USD"
        } else if base.contains("-") {
            return base
        } else {
            return "\(base)-USD"
        }
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
            "ARB", "OP", "SUI",
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

            if let existingIndex = currentHoldings.firstIndex(where: {
                $0.symbol == symbol && ($0.purchaseDate == newH.purchaseDate || ($0.purchaseDate == nil && newH.purchaseDate == nil))
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
    }

    func removeHolding(from portfolioId: UUID, holdingId: UUID) {
        guard let pIndex = portfolios.firstIndex(where: { $0.id == portfolioId }),
              !portfolios[pIndex].isReadOnly else { return }
        portfolios[pIndex].holdings.removeAll { $0.id == holdingId }
    }

    func removeSymbol(from portfolioId: UUID, symbol: String) {
        guard let pIndex = portfolios.firstIndex(where: { $0.id == portfolioId }),
              !portfolios[pIndex].isReadOnly else { return }
        portfolios[pIndex].holdings.removeAll { $0.symbol.caseInsensitiveCompare(symbol) == .orderedSame }
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

    func moveSymbol(symbol: String, from sourcePortfolioId: UUID, to targetPortfolioId: UUID) {
        guard sourcePortfolioId != targetPortfolioId,
              let sIndex = portfolios.firstIndex(where: { $0.id == sourcePortfolioId }),
              !portfolios[sIndex].isReadOnly,
              let tIndex = portfolios.firstIndex(where: { $0.id == targetPortfolioId }),
              !portfolios[tIndex].isReadOnly
        else { return }
        let matchingHoldings = portfolios[sIndex].holdings.filter { $0.symbol.caseInsensitiveCompare(symbol) == .orderedSame }
        guard !matchingHoldings.isEmpty else { return }
        portfolios[sIndex].holdings.removeAll { $0.symbol.caseInsensitiveCompare(symbol) == .orderedSame }
        portfolios[tIndex].holdings.append(contentsOf: matchingHoldings)
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

    func resetToDefaults() {
        preferredCurrency = "EUR"
        stockPriceCurrency = ""
        showExtendedHours = true
        showCompanyName = true
        showDayRange = true
        show52WeekBar = true
        showAbsoluteChange = true
        menuBarDisplay = "pnl"
        gainColorHex = ""
        lossColorHex = ""
        menuBarUseSystemColor = false
        percentDecimals = 1
        valueDecimals = -1
        menuBarHidePercent = false
        tickerShowName = false
        advancedPositions = false
        watchlistSort = "manual"
        appLanguage = "en"
        fontSizeLevel = 9
        fontFamily = "Inter Variable"
        appearanceRaw = AppearanceMode.default.rawValue
        showNewsTab = true
        symbolNotes = [:]
        lastSelectedTab = "Watchlist"
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

    func importPortfolios(from data: Data) -> [Portfolio]? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let export = try? decoder.decode(PortfolioExport.self, from: data) else { return nil }
        return export.portfolios
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

    private struct AppData: Codable {
        var watchlist: [String]
        var watchlists: [Watchlist]?
        var selectedWatchlistId: UUID?
        var portfolioColumns: [PortfolioColumnMetric]?
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
        var showDayRange: Bool?
        var show52WeekBar: Bool?
        var showAbsoluteChange: Bool?
        var portfolioNotifications: [String: [PortfolioNotification]]?
        var portfolioSnapshots: [String: [PortfolioSnapshot]]?
        var portfolioChartRanges: [String: String]?
        var discordWebhookURL: String?
        var discordEnabled: Bool?
        var gainColorHex: String?
        var lossColorHex: String?
        var menuBarUseSystemColor: Bool?
        var percentTwoDecimals: Bool?   // legacy (pre-#10) — migrated on decode
        var percentDecimals: Int?
        var valueDecimals: Int?
        var menuBarHidePercent: Bool?
        var tickerShowName: Bool?
        var watchlistSort: String?
        var symbolType: [String: String]?
        var appLanguage: String?
        var advancedPositions: Bool?
        var appearanceRaw: String?
        var showNewsTab: Bool?
    }

    private func scheduleSave() {
        guard !isLoading, !decodeFailure else { return }
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard !Task.isCancelled else { return }
            self.performSave()
        }
    }

    private func performSave() {
        // Backup the existing file before overwriting, so a crash or bug can't
        // destroy all user data without a recovery path.
        let bakURL = fileURL.appendingPathExtension("bak")
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try? FileManager.default.removeItem(at: bakURL)
            try? FileManager.default.copyItem(at: fileURL, to: bakURL)
        }
        let data = AppData(watchlist: watchlist, watchlists: watchlists, selectedWatchlistId: selectedWatchlistId, portfolioColumns: portfolioColumns, portfolios: portfolios, preferredCurrency: preferredCurrency, stockPriceCurrency: stockPriceCurrency, showExtendedHours: showExtendedHours, menuBarDisplay: menuBarDisplay, isinMap: isinMap, fontSizeLevel: fontSizeLevel, fontFamily: fontFamily, alerts: alerts, symbolNotes: symbolNotes.isEmpty ? nil : symbolNotes, showCompanyName: showCompanyName, showDayRange: showDayRange, show52WeekBar: show52WeekBar, showAbsoluteChange: showAbsoluteChange, portfolioNotifications: portfolioNotifications, portfolioSnapshots: portfolioSnapshots, portfolioChartRanges: portfolioChartRanges, discordWebhookURL: discordWebhookURL, discordEnabled: discordEnabled, gainColorHex: gainColorHex, lossColorHex: lossColorHex, menuBarUseSystemColor: menuBarUseSystemColor, percentTwoDecimals: nil, percentDecimals: percentDecimals, valueDecimals: valueDecimals, menuBarHidePercent: menuBarHidePercent, tickerShowName: tickerShowName, watchlistSort: watchlistSort, symbolType: symbolType, appLanguage: appLanguage, advancedPositions: advancedPositions, appearanceRaw: appearanceRaw, showNewsTab: showNewsTab)
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
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoded = try JSONDecoder().decode(AppData.self, from: data)
            if let wls = decoded.watchlists, !wls.isEmpty {
                // Deduplicate watchlists by name/ID and strip leftover empty test lists
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
            } else {
                let def = Watchlist(id: UUID(), name: "Watchlist", symbols: [])
                watchlists = [def]
            }
            portfolios = decoded.portfolios.map { p in
                var updated = p
                if updated.isReadOnly {
                    var aggregated: [String: Holding] = [:]
                    for h in updated.holdings {
                        let normSym = StorageService.normalizeBinanceHoldingSymbol(h.symbol)
                        if var existing = aggregated[normSym] {
                            existing.quantity += h.quantity
                            aggregated[normSym] = existing
                        } else {
                            var newH = h
                            newH.symbol = normSym
                            aggregated[normSym] = newH
                        }
                    }
                    updated.holdings = Array(aggregated.values)
                } else {
                    // Repair manual portfolios if they were mistakenly appended with -USD for non-crypto symbols
                    updated.holdings = updated.holdings.map { h in
                        var newH = h
                        if newH.symbol.hasSuffix("-USD") {
                            let base = String(newH.symbol.dropLast(4))
                            if !StorageService.isStandardCryptoSymbol(base) {
                                newH.symbol = base
                            }
                        }
                        return newH
                    }
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
            discordWebhookURL = decoded.discordWebhookURL ?? ""
            discordEnabled = decoded.discordEnabled ?? false
            gainColorHex = decoded.gainColorHex ?? ""
            lossColorHex = decoded.lossColorHex ?? ""
            menuBarUseSystemColor = decoded.menuBarUseSystemColor ?? false
            // #10: migrate the old on/off toggle (2 vs 1) to the free decimal count.
            percentDecimals = decoded.percentDecimals ?? (decoded.percentTwoDecimals == true ? 2 : 1)
            valueDecimals = decoded.valueDecimals ?? -1
            menuBarHidePercent = decoded.menuBarHidePercent ?? false
            tickerShowName = decoded.tickerShowName ?? false
            advancedPositions = decoded.advancedPositions ?? false
            watchlistSort = decoded.watchlistSort ?? "manual"
            symbolType = decoded.symbolType ?? [:]
            appLanguage = decoded.appLanguage ?? "en"
            showCompanyName = decoded.showCompanyName ?? true
            showDayRange = decoded.showDayRange ?? true
            show52WeekBar = decoded.show52WeekBar ?? true
            showAbsoluteChange = decoded.showAbsoluteChange ?? true
            fontSizeLevel = decoded.fontSizeLevel ?? 9
            fontFamily = decoded.fontFamily ?? "Inter Variable"
            appearanceRaw = decoded.appearanceRaw ?? AppearanceMode.default.rawValue
            showNewsTab = decoded.showNewsTab ?? true
            portfolioColumns = decoded.portfolioColumns
            FontRegistration.familyName = fontFamily
            FontRegistration.sizeOffset = CGFloat(fontSizeLevel - 9)
        } catch {
            // The file exists but couldn't be decoded (schema change, corruption, etc.).
            // Rename it so the original data is preserved for recovery, and set a flag
            // that blocks any automatic save from overwriting the renamed backup.
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
