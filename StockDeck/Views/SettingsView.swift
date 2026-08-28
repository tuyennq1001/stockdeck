#if os(macOS)
import AppKit
import Sparkle
#endif
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var storageService: StorageService
    @EnvironmentObject var stockService: StockService
    @EnvironmentObject var updaterViewModel: UpdaterViewModel
    @Environment(\.openURL) private var openURL
    @State private var showResetAlert = false
    @State private var showClearPortfolioNotifs = false

    // Collapsible category state — remembered across popover opens. General is
    // open by default (theme/language live there); the rest start collapsed so
    // the list is short and you drill into what you need.
    @AppStorage("settings.group.general") private var groupGeneral = true
    @AppStorage("settings.group.currency") private var groupCurrency = false
    @AppStorage("settings.group.positions") private var groupPositions = false
    @AppStorage("settings.group.menubar") private var groupMenuBar = false
    @AppStorage("settings.group.notifications") private var groupNotifications = false
    @AppStorage("settings.group.ai") private var groupAI = false
    @AppStorage("settings.group.investor_profile") private var groupInvestorProfile = false
    @AppStorage("settings.group.about") private var groupAbout = false
    @AppStorage("settings.group.icloud") private var groupICloud = false
    @State private var showEditProfileSheet = false
    @ObservedObject private var syncService = iCloudSyncService.shared
    @State private var isLoadingModels = false
    @State private var modelFetchError: String? = nil
    @State private var aiTestResult: String? = nil
    @State private var aiTestIsLoading = false
    @State private var showCustomModelField = false
    @State private var showApiKeyText = false

    private var availableModelOptions: [String] {
        storageService.availableModels(for: storageService.aiProvider)
    }

    private func loadModels(silent: Bool = false) {
        guard !storageService.aiBaseURL.isEmpty, !storageService.aiApiKey.isEmpty else { return }
        if !silent {
            isLoadingModels = true
        }
        modelFetchError = nil
        let currentProvider = storageService.aiProvider
        Task {
            do {
                let models = try await AIReviewService.shared.fetchModels(
                    baseURL: storageService.aiBaseURL,
                    apiKey: storageService.aiApiKey
                )
                await MainActor.run {
                    self.storageService.setCachedModels(models, for: currentProvider)
                    self.isLoadingModels = false
                    if let first = models.first, (self.storageService.aiModel.isEmpty || !models.contains(self.storageService.aiModel)) {
                        self.storageService.aiModel = first
                    }
                }
            } catch {
                await MainActor.run {
                    if !silent {
                        self.modelFetchError = error.localizedDescription
                    }
                    self.isLoadingModels = false
                }
            }
        }
    }

    private func runAITest() async {
        aiTestIsLoading = true
        aiTestResult = nil
        defer { aiTestIsLoading = false }
        let result = await TestAI.testConnection(storageService: storageService)
        aiTestResult = result.message
    }

    /// Small secondary caption used throughout the settings list.
    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.inter(10, relativeTo: .caption))
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Sub-section label inside a category (e.g. "Language" under "General").
    private func subHeader(_ text: String) -> some View {
        Text(text)
            .font(.inter(11, weight: .semibold, relativeTo: .subheadline))
            .foregroundColor(.secondary)
    }

    private func chooseWorkspaceFolder() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose a folder StockDeck AI Review should use as long-term memory (ai-context.md)."
        if panel.runModal() == .OK, let url = panel.url {
            storageService.aiWorkspacePath = url.path
        }
        #endif
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                // MARK: - General (language, appearance, font, startup)
                SettingsGroup(title: "General", icon: "gearshape", isExpanded: $groupGeneral) {
                    #if os(macOS)
                    subHeader("Startup")
                    Toggle("Launch at login", isOn: $storageService.launchAtLogin)
                        .toggleStyle(.switch)
                    caption("Automatically start StockDeck when you log into your Mac.")
                    #endif

                    subHeader("Language")
                    Picker("Language", selection: $storageService.appLanguage) {
                        ForEach(StorageService.supportedLanguages, id: \.code) { lang in
                            Text(lang.name).tag(lang.code)
                        }
                    }
                    .pickerStyle(.menu)
                    caption("Choose the app's language. Default is English.")

                    subHeader("Appearance")
                    Picker("Theme", selection: Binding(
                        get: { storageService.appearanceMode },
                        set: { storageService.appearanceMode = $0 }
                    )) {
                        ForEach(AppearanceMode.allCases, id: \.self) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    caption("Follow the system, or force Light or Dark.")
                    Toggle("Show News tab", isOn: $storageService.showNewsTab)
                        .toggleStyle(.switch)
                    caption("The Home news feed is off by default when hidden — it only fetches while its tab is open (throttled, no background use).")

                    subHeader("Font")
                    Picker("Font family", selection: $storageService.fontFamily) {
                        ForEach(FontRegistration.availableFonts, id: \.family) { font in
                            Text(font.label)
                                .font(.custom(font.family, size: 13))
                                .tag(font.family)
                        }
                    }
                    .pickerStyle(.menu)
                    HStack {
                        Text("A")
                            .font(.inter(10, relativeTo: .caption))
                            .foregroundColor(.secondary)
                        Slider(value: Binding(
                            get: { Double(storageService.fontSizeLevel) },
                            set: { storageService.fontSizeLevel = Int($0) }
                        ), in: 7...13, step: 1)
                        Text("A")
                            .font(.inter(18, weight: .bold, relativeTo: .title2))
                            .foregroundColor(.secondary)
                    }
                    caption("Size: \(storageService.fontSizeLevel)")
                }

                // MARK: - iCloud Sync
                SettingsGroup(title: "iCloud Sync", icon: "icloud", isExpanded: $groupICloud) {
                    Toggle("Enable iCloud Sync", isOn: $storageService.iCloudSyncEnabled)
                        .toggleStyle(.switch)
                        .onChange(of: storageService.iCloudSyncEnabled) {
                            syncService.onSyncToggleChanged(enabled: storageService.iCloudSyncEnabled)
                        }
                    caption("Automatically syncs watchlists, portfolios, alerts, and notes across all your devices via iCloud.")

                    if storageService.iCloudSyncEnabled {
                        if !syncService.isiCloudAvailable {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.orange)
                                Text("iCloud not signed in on this device. Please sign in to Apple ID in System Settings.")
                                    .font(.inter(10, relativeTo: .caption))
                                    .foregroundColor(.secondary)
                            }
                            .padding(8)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
                        }

                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 5) {
                                    Circle()
                                        .fill(syncService.syncStatus.contains("Fail") ? Color.red : Color.green)
                                        .frame(width: 6, height: 6)
                                    Text(syncService.syncStatus)
                                        .font(.inter(11, weight: .semibold, relativeTo: .subheadline))
                                }
                                if let lastDate = syncService.lastSyncDate {
                                    Text("Last: \(lastDate.formatted(date: .abbreviated, time: .shortened))")
                                        .font(.inter(10, relativeTo: .caption))
                                        .foregroundColor(.secondary)
                                } else {
                                    Text("Not synced yet")
                                        .font(.inter(10, relativeTo: .caption))
                                        .foregroundColor(.secondary)
                                }
                            }
                            Spacer()
                            Button(syncService.isSyncing ? "Syncing…" : "Sync Now") {
                                syncService.pullAndMerge(force: true)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(syncService.isSyncing)
                        }

                        HStack(spacing: 8) {
                            Button("Push to iCloud") {
                                syncService.pushLocalData()
                            }
                            .buttonStyle(.borderless)
                            .font(.inter(10, relativeTo: .caption))
                            .foregroundStyle(DS.brand)

                            Text("·").font(.inter(10, relativeTo: .caption)).foregroundColor(.secondary)

                            Button("Pull from iCloud") {
                                syncService.pullAndMerge(force: true)
                            }
                            .buttonStyle(.borderless)
                            .font(.inter(10, relativeTo: .caption))
                            .foregroundStyle(DS.brand)
                        }
                    }
                }

                // MARK: - Currency
                SettingsGroup(title: "Currency", icon: "eurosign.circle", isExpanded: $groupCurrency) {
                    subHeader("Stock price currency")
                    Picker("Price currency", selection: $storageService.stockPriceCurrency) {
                        Text("Original").tag("")
                        ForEach(StorageService.supportedCurrencies, id: \.self) { code in
                            Text("\(StorageService.currencySymbol(for: code)) \(code)")
                                .tag(code)
                        }
                    }
                    .pickerStyle(.menu)
                    .onChange(of: storageService.stockPriceCurrency) {
                        stockService.exchangeRates.removeAll()
                        Task {
                            await stockService.refreshAll(storageService: storageService)
                        }
                    }
                    caption(storageService.stockPriceCurrency.isEmpty
                            ? "Prices shown in their native currency"
                            : "All prices converted to \(storageService.stockPriceCurrency)")

                    subHeader("Portfolio currency")
                    Picker("Portfolio currency", selection: $storageService.preferredCurrency) {
                        ForEach(StorageService.supportedCurrencies, id: \.self) { code in
                            Text("\(StorageService.currencySymbol(for: code)) \(code)")
                                .tag(code)
                        }
                    }
                    .pickerStyle(.menu)
                    .onChange(of: storageService.preferredCurrency) {
                        stockService.exchangeRates.removeAll()
                        Task {
                            await stockService.refreshAll(storageService: storageService)
                        }
                    }
                    caption("Portfolio totals and P&L converted to \(storageService.preferredCurrency)")
                }

                // MARK: - Positions & Market
                SettingsGroup(title: "Positions & Market", icon: "chart.line.uptrend.xyaxis", isExpanded: $groupPositions) {
                    Toggle("Enable short positions & leverage", isOn: $storageService.advancedPositions)
                        .toggleStyle(.switch)
                    caption("Adds a leverage field and lets you enter a negative quantity for short positions, so a portfolio can be a relative long/short basket.")

                    Toggle("Show extended hours (Pre/Post)", isOn: $storageService.showExtendedHours)
                        .toggleStyle(.switch)
                    caption("Show pre-market and after-hours prices")

                    subHeader("Default chart")
                    Picker("Default chart", selection: $storageService.defaultChartStyle) {
                        Text("Line chart").tag("line")
                        Text("Trading View").tag("tradingview")
                    }
                    .pickerStyle(.menu)
                    caption("Default style when opening a stock chart")
                }

                // MARK: - AI Review
                SettingsGroup(title: "AI Review", icon: "sparkles", isExpanded: $groupAI) {
                    subHeader("Provider")
                    Picker("Provider", selection: $storageService.aiProvider) {
                            ForEach(AIProviderOption.allCases) { p in
                                Text(p.label).tag(p.rawValue)
                            }
                        }
                        .pickerStyle(.menu)
                        .onChange(of: storageService.aiProvider) { _, newValue in
                            storageService.applyAIPreset(newValue)
                            loadModels(silent: true)
                        }
                        if storageService.aiProvider == "custom" {
                            caption("Custom base URL")
                            TextField("https://api.example.com/v1", text: $storageService.aiBaseURL)
                                .textFieldStyle(.roundedBorder)
                        }
                        subHeader("Model")
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 8) {
                                if showCustomModelField {
                                    TextField("Model ID (e.g. gemini-2.0-flash)", text: $storageService.aiModel)
                                        .textFieldStyle(.roundedBorder)
                                } else {
                                    Picker("Model", selection: $storageService.aiModel) {
                                        ForEach(availableModelOptions, id: \.self) { option in
                                            Text(option).tag(option)
                                        }
                                    }
                                    .pickerStyle(.menu)
                                }

                                Button {
                                    loadModels()
                                } label: {
                                    if isLoadingModels {
                                        ProgressView().controlSize(.small)
                                    } else {
                                        Image(systemName: "arrow.clockwise")
                                            .font(.system(size: 11, weight: .semibold))
                                    }
                                }
                                .buttonStyle(.bordered)
                                .disabled(isLoadingModels || storageService.aiApiKey.isEmpty || storageService.aiBaseURL.isEmpty)
                                .help("Load available models from provider")

                                Button {
                                    withAnimation {
                                        showCustomModelField.toggle()
                                    }
                                } label: {
                                    Image(systemName: showCustomModelField ? "list.bullet" : "pencil")
                                        .font(.system(size: 11, weight: .medium))
                                }
                                .buttonStyle(.bordered)
                                .help(showCustomModelField ? "Switch to model dropdown" : "Type custom model ID")
                            }

                            if let err = modelFetchError {
                                caption("Lỗi tải danh sách model: \(err)")
                                    .foregroundStyle(DS.down)
                            } else if let cached = storageService.cachedModelsByProvider[storageService.aiProvider], !cached.isEmpty {
                                caption("Đã tải \(cached.count) models từ server")
                                    .foregroundStyle(DS.up)
                            }
                        }

                        if storageService.aiProvider == "deepseek" {
                            Toggle("Thinking mode (V4)", isOn: $storageService.aiDeepseekThinking)
                                .toggleStyle(.switch)
                            caption("DeepSeek V4 defaults to thinking on. Turn off for fast chat (like the retired deepseek-chat).")
                        }
                        subHeader("API key")
                        HStack(spacing: 8) {
                            if showApiKeyText {
                                TextField("sk-… / AIzaSy…", text: Binding(
                                    get: { storageService.aiApiKey },
                                    set: {
                                        storageService.aiApiKey = $0
                                        if !storageService.aiApiKey.isEmpty {
                                            loadModels(silent: true)
                                        }
                                    }))
                                    .textFieldStyle(.roundedBorder)
                                    .disableAutocorrection(true)
                            } else {
                                SecureField("sk-… / AIzaSy…", text: Binding(
                                    get: { storageService.aiApiKey },
                                    set: {
                                        storageService.aiApiKey = $0
                                        if !storageService.aiApiKey.isEmpty {
                                            loadModels(silent: true)
                                        }
                                    }))
                                    .textFieldStyle(.roundedBorder)
                                    .disableAutocorrection(true)
                            }

                            Button {
                                withAnimation {
                                    showApiKeyText.toggle()
                                }
                            } label: {
                                Image(systemName: showApiKeyText ? "eye.slash" : "eye")
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .buttonStyle(.bordered)
                            .help(showApiKeyText ? "Hide API key" : "Show API key")
                        }
                        caption("Stored securely in the macOS Keychain. Never persisted as plaintext. An OpenAI-compatible key works with OpenAI, DeepSeek, Groq, OpenRouter, Google Gemini, etc.")

                        subHeader("Workspace folder")
                        HStack(spacing: 8) {
                            Button("Choose…") {
                                chooseWorkspaceFolder()
                            }
                            .buttonStyle(.bordered)
                            if !storageService.aiWorkspacePath.isEmpty {
                                Text((storageService.aiWorkspacePath as NSString).lastPathComponent)
                                    .font(DS.micro)
                                    .foregroundStyle(DS.inkSecondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Button {
                                    storageService.aiWorkspacePath = ""
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(DS.inkTertiary)
                                }
                                .buttonStyle(.plain)
                                .help("Remove workspace folder")
                            }
                        }
                        caption("A folder the assistant reads & writes as long-term memory (ai-context.md) — so durable notes survive across sessions instead of being re-asked.")

                        subHeader("Connection Diagnostic")
                        HStack {
                            if let result = aiTestResult {
                                Text(result)
                                    .font(DS.micro)
                                    .foregroundStyle(result.hasPrefix("✓") ? DS.up : DS.down)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer()
                            } else {
                                Spacer()
                            }
                            if aiTestIsLoading {
                                HStack(spacing: 6) {
                                    ProgressView().controlSize(.small)
                                    Text("Testing…").font(DS.micro).foregroundStyle(DS.inkSecondary)
                                }
                            } else {
                                Button("Test connection") {
                                    Task { await runAITest() }
                                }
                                .buttonStyle(.bordered)
                                .font(.inter(11, weight: .medium, relativeTo: .caption))
                                .disabled(!storageService.hasAIConfiguration)
                            }
                        }
                        .padding(.top, 2)
                }

                // MARK: - Investor Profile
                SettingsGroup(title: "Investor Profile & Goals", icon: "person.text.rectangle", isExpanded: $groupInvestorProfile) {
                    if let profile = storageService.investorProfile {
                        subHeader("Current Profile")
                        Text(profile.summaryDescription)
                            .font(.inter(11.5, weight: .medium, relativeTo: .caption))
                            .foregroundStyle(DS.ink)
                        if !profile.primaryGoal.isEmpty {
                            subHeader("Primary Goal")
                            Text(profile.primaryGoal)
                                .font(.inter(11, relativeTo: .caption))
                                .foregroundStyle(DS.inkSecondary)
                        }
                        HStack {
                            Button("Reset") {
                                storageService.investorProfile = nil
                            }
                            .buttonStyle(.bordered)
                            .tint(.red)

                            Spacer()

                            Button("Edit Profile…") {
                                showEditProfileSheet = true
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(DS.brand)
                        }
                        .padding(.top, 4)
                    } else {
                        subHeader("Status")
                        caption("No profile set up yet. Create a profile to receive personalized advice tailored to your goals.")
                        Button("Set up Investor Profile…") {
                            showEditProfileSheet = true
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(DS.brand)
                        .padding(.top, 4)
                    }
                }

                #if os(macOS)
                // MARK: - Menu Bar (display + colors)
                SettingsGroup(title: "Menu Bar", icon: "menubar.rectangle", isExpanded: $groupMenuBar) {
                    subHeader("Display")
                    Picker("Display", selection: $storageService.menuBarDisplay) {
                        Text("P&L (+321.09€)").tag("pnl")
                        Text("P&L % (+2.3%)").tag("pnlPercent")
                        Text("P&L + % (+321.09€ +2.3%)").tag("pnlFull")
                        Text("Today (+321.09€ +1.2%)").tag("todayPnlFull")
                        Text("Total Value (14396.67€)").tag("totalValue")
                        Text("Best Stock (▲ AAPL +1.2%)").tag("bestStock")
                        Text("Worst Stock (▼ TSLA -0.8%)").tag("worstStock")
                        Text("Best & Worst").tag("bestWorst")
                        Text("Portfolio (14396.67€ +1.2%)").tag("portfolioRecap")
                        Text("Ticker (cycle watchlist)").tag("ticker")
                        Text("Ticker + Portfolio (cycle)").tag("tickerPortfolio")
                        Text("Icon Only").tag("icon")
                    }
                    .pickerStyle(.menu)
                    caption("Choose what to show in the menu bar")
                    if storageService.menuBarDisplay == "todayPnlFull" {
                        caption("Uses regular-market prices. Crypto Today resets at 00:00 UTC.")
                    }

                    HStack {
                        Text("Percentage decimals")
                        Spacer()
                        Picker("", selection: $storageService.percentDecimals) {
                            ForEach(0...4, id: \.self) { Text("\($0)").tag($0) }
                        }
                        .labelsHidden().pickerStyle(.menu).frame(width: 90)
                    }
                    caption("Digits after the decimal point in percentages (e.g. +2.34% with 2).")

                    HStack {
                        Text("Value decimals")
                        Spacer()
                        Picker("", selection: $storageService.valueDecimals) {
                            Text("Auto").tag(-1)
                            ForEach(0...4, id: \.self) { Text("\($0)").tag($0) }
                        }
                        .labelsHidden().pickerStyle(.menu).frame(width: 90)
                    }
                    caption("Prices & amounts. Auto keeps extra precision for forex / sub-dollar prices.")

                    Toggle("Hide percentage change", isOn: $storageService.menuBarHidePercent)
                    caption("Show only price / value in the menu bar, without the % change.")

                    // Ticker-specific options (issue #8) — only relevant in ticker modes.
                    if storageService.menuBarDisplay == "ticker" || storageService.menuBarDisplay == "tickerPortfolio" {
                        Toggle("Show name instead of symbol", isOn: $storageService.tickerShowName)
                        caption("Shows the readable name in the ticker (e.g. \"S&P 500\" instead of \"^GSPC\").")

                        Picker("Ticker order", selection: $storageService.watchlistSort) {
                            Text("As added").tag("manual")
                            Text("By type (stocks, ETFs, indices…)").tag("type")
                            Text("Alphabetical").tag("alpha")
                        }
                        .pickerStyle(.menu)
                        caption("Order in which watchlist entries cycle in the menu bar.")
                    }

                    subHeader("Global shortcut")
                    HStack {
                        Text("Toggle menu bar")
                        Spacer()
                        ShortcutRecorderView(shortcut: $storageService.menuBarShortcut)
                    }
                    caption("Press anywhere on macOS to open or close the menu bar popup.")

                    subHeader("Colors")
                    #if os(macOS)
                    ColorPicker("Gain color", selection: Binding(
                        get: { Color(nsColor: storageService.gainColor) },
                        set: { storageService.gainColorHex = $0.hexString }
                    ))
                    ColorPicker("Loss color", selection: Binding(
                        get: { Color(nsColor: storageService.lossColor) },
                        set: { storageService.lossColorHex = $0.hexString }
                    ))
                    #else
                    ColorPicker("Gain color", selection: Binding(
                        get: { Color(uiColor: storageService.gainColor) },
                        set: { storageService.gainColorHex = $0.hexString }
                    ))
                    ColorPicker("Loss color", selection: Binding(
                        get: { Color(uiColor: storageService.lossColor) },
                        set: { storageService.lossColorHex = $0.hexString }
                    ))
                    #endif
                    Button("Reset to default green/red") {
                        storageService.gainColorHex = ""
                        storageService.lossColorHex = ""
                    }
                    .font(.inter(10, relativeTo: .caption))
                    caption("Gain/loss colors apply across the whole app — menu bar, watchlist and portfolios.")

                }
                #endif

                // MARK: - Notifications
                SettingsGroup(title: "Notifications", icon: "bell", isExpanded: $groupNotifications) {
                    // Channels (Discord / Slack webhook)
                    subHeader("Channels")
                    Toggle("Mirror notifications to a Discord/Slack webhook", isOn: $storageService.discordEnabled)
                        .toggleStyle(.switch)
                    TextField("https://discord.com/api/webhooks/… or hooks.slack.com/…", text: $storageService.discordWebhookURL)
                        .textFieldStyle(.roundedBorder)
                        .font(.inter(10, relativeTo: .caption))
                        .disabled(!storageService.discordEnabled)
                    let trimmed = storageService.discordWebhookURL.trimmingCharacters(in: .whitespacesAndNewlines)
                    if storageService.discordEnabled && !trimmed.isEmpty && !WebhookNotifier.isValid(trimmed) {
                        Text("Not a valid Discord or Slack webhook URL (must be https).")
                            .font(.inter(10, relativeTo: .caption))
                            .foregroundColor(.red)
                    } else {
                        caption("Price alerts and portfolio notifications are also sent here.")
                    }
                    Button("Send test") {
                        NotificationManager.shared.send(
                            title: "StockDeck test",
                            body: "Webhook is working ✅",
                            sentiment: .positive)
                    }
                    .controlSize(.small)
                    .disabled(!storageService.discordEnabled || !WebhookNotifier.isValid(trimmed))

                    // Portfolio notifications
                    let withNotifs = storageService.portfolios.filter {
                        !storageService.notifications(for: $0.id).isEmpty
                    }
                    HStack {
                        subHeader("Portfolio notifications")
                        Spacer()
                        if !withNotifs.isEmpty {
                            Button(action: { showClearPortfolioNotifs = true }) {
                                Text("Clear all")
                                    .font(.inter(10, relativeTo: .caption))
                            }
                            .buttonStyle(.borderless)
                            .foregroundColor(.red)
                        }
                    }
                    if withNotifs.isEmpty {
                        caption("None. Right-click a portfolio → “Notifications…” to add one.")
                    } else {
                        ForEach(withNotifs) { portfolio in
                            Text(portfolio.name)
                                .font(.inter(10, weight: .medium, relativeTo: .caption))
                            ForEach(storageService.notifications(for: portfolio.id)) { n in
                                PortfolioNotifRow(portfolioId: portfolio.id, notification: n)
                            }
                        }
                    }
                }

                // MARK: - About & Data (updates, sponsor, reset)
                SettingsGroup(title: "About & Data", icon: "info.circle", isExpanded: $groupAbout) {
                    #if os(macOS)
                    subHeader("Updates")
                    Button("Check for Updates...") {
                        NSApp.setActivationPolicy(.regular)
                        NSApp.activate(ignoringOtherApps: true)
                        updaterViewModel.checkForUpdates()
                    }
                    .disabled(!updaterViewModel.canCheckForUpdates)
                    #endif

                    subHeader("Enjoying StockDeck?")
                    caption("StockDeck is free and open source — and always will be. If you'd like to support me, you can become a sponsor, or simply star the repo. Both help, and every feature stays free for everyone.")
                    HStack(spacing: 8) {
                        Button {
                            if let url = URL(string: "https://github.com/sponsors/tuyennq1001") {
                                #if os(macOS)
                                NSWorkspace.shared.open(url)
                                #else
                                UIApplication.shared.open(url)
                                #endif
                            }
                        } label: {
                            Label("Become a Sponsor", systemImage: "heart.fill")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(.pink)

                        Button {
                            if let url = URL(string: "https://github.com/tuyennq1001/stockdeck") {
                                #if os(macOS)
                                NSWorkspace.shared.open(url)
                                #else
                                UIApplication.shared.open(url)
                                #endif
                            }
                        } label: {
                            Label("Star on GitHub", systemImage: "star.fill")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(.yellow)
                    }

                    subHeader("Reset")
                    Button("Reset to Default Settings") {
                        showResetAlert = true
                    }
                    .foregroundColor(.red)
                    caption("This will not erase your portfolios or watchlist")
                }
            }
            .padding(16)
        }
        .alert("Reset Settings", isPresented: $showResetAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Reset", role: .destructive) {
                storageService.resetToDefaults()
                Task {
                    stockService.exchangeRates.removeAll()
                    await stockService.refreshAll(storageService: storageService)
                }
            }
        } message: {
            Text("This will reset all settings to their defaults. Your portfolios and watchlist will not be affected.")
        }
        .alert("Clear all portfolio notifications", isPresented: $showClearPortfolioNotifs) {
            Button("Cancel", role: .cancel) {}
            Button("Clear all", role: .destructive) {
                storageService.removeAllPortfolioNotifications()
            }
        } message: {
            Text("This will delete all portfolio notifications across every portfolio. This cannot be undone.")
        }
        .sheet(isPresented: $showEditProfileSheet) {
            InvestorProfileEditorSheet(
                initialProfile: storageService.investorProfile ?? InvestorProfile(),
                onSave: { updated in
                    storageService.investorProfile = updated
                    showEditProfileSheet = false
                },
                onCancel: {
                    showEditProfileSheet = false
                }
            )
        }
        #if os(macOS)
        .onAppear {
            storageService.syncLaunchAtLoginStatus()
        }
        #endif
    }

}

/// A collapsible settings category: a tappable header (icon + title + chevron)
/// that expands to reveal its controls. Keeps the (long) settings list short —
/// you drill into the category you need. Expansion state is owned by the caller
/// (persisted via @AppStorage) so it survives popover reopenings.
struct SettingsGroup<Content: View>: View {
    let title: String
    let icon: String
    @Binding var isExpanded: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.22)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: icon)
                        .font(.inter(11, relativeTo: .caption))
                        .foregroundColor(.accentColor)
                        .frame(width: 16)
                    Text(title)
                        .font(.inter(13, weight: .bold, relativeTo: .headline))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.inter(10, weight: .semibold, relativeTo: .caption))
                        .foregroundColor(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .contentShape(Rectangle())
                .padding(.vertical, 9)
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    content()
                }
                .padding(.leading, 25)
                .padding(.bottom, 10)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            Divider()
        }
    }
}

/// A single alert row in Settings: enable/re-arm toggle, description and delete.
struct AlertRow: View {
    @EnvironmentObject var storageService: StorageService
    let alert: PriceAlert

    private var currencySymbol: String {
        StorageService.currencySymbol(for: StockService.shared.quotes[alert.symbol]?.currency
            ?? storageService.preferredCurrency)
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: alert.condition.systemImage)
                .font(.inter(10, relativeTo: .caption))
                .foregroundColor(alert.isEnabled ? .accentColor : .secondary)
                .frame(width: 14)
            SymbolLogo(symbol: alert.symbol, size: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(StockService.beautifiedSymbol(alert.symbol))
                    .font(.inter(12, weight: .semibold, relativeTo: .body))
                Text(AlertEvaluator.describe(alert, currencySymbol: currencySymbol))
                    .font(.inter(9, relativeTo: .caption2))
                    .foregroundColor(.secondary)
            }
            Spacer()
            if !alert.isEnabled {
                Text("triggered")
                    .font(.inter(8, weight: .semibold, relativeTo: .caption2))
                    .foregroundColor(.orange)
            }
            Toggle("", isOn: Binding(
                get: { alert.isEnabled },
                set: { storageService.setAlertEnabled(id: alert.id, enabled: $0) }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()
            .help(alert.isEnabled ? "Enabled" : "Re-arm alert")
            Button(action: { storageService.removeAlert(id: alert.id) }) {
                Image(systemName: "trash")
                    .font(.inter(10, relativeTo: .caption))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 2)
    }
}

/// A single portfolio-notification row in Settings: enable toggle, description and delete.
struct PortfolioNotifRow: View {
    @EnvironmentObject var storageService: StorageService
    let portfolioId: UUID
    let notification: PortfolioNotification

    private var currencySymbol: String {
        StorageService.currencySymbol(for: storageService.preferredCurrency)
    }

    private var description: String {
        let n = notification
        switch n.mode {
        case .dailyPercent:
            return "Every ±\(String(format: "%g", n.threshold))% move today"
        case .dailyAbsolute:
            return "Every ±\(currencySymbol)\(String(format: "%g", n.threshold)) move today"
        case .milestone:
            return "Every \(currencySymbol)\(String(format: "%g", n.threshold)) crossed"
        case .dailySummary:
            return "Daily after \(String(format: "%.0f", n.threshold)):00"
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: notification.mode.systemImage)
                .font(.inter(10, relativeTo: .caption))
                .foregroundColor(notification.isEnabled ? .accentColor : .secondary)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(notification.mode.label)
                    .font(.inter(12, weight: .semibold, relativeTo: .body))
                Text(description)
                    .font(.inter(9, relativeTo: .caption2))
                    .foregroundColor(.secondary)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { notification.isEnabled },
                set: { storageService.setPortfolioNotificationEnabled(id: notification.id, in: portfolioId, enabled: $0) }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()
            Button(action: { storageService.removePortfolioNotification(id: notification.id, from: portfolioId) }) {
                Image(systemName: "trash")
                    .font(.inter(10, relativeTo: .caption))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 2)
    }
}
