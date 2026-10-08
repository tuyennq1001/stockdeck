import SwiftUI
import AppKit

/// Desktop settings, dressed in the app's own card system (white premium cards,
/// hairline dividers, emerald controls) so the tab matches Overview/Watchlist
/// instead of the system-gray grouped form. Same bindings as the popover —
/// changes apply everywhere at once.
struct SettingsWideView: View {
    var body: some View {
        PageScaffold("Settings", caption: "Preferences are shared with the menu bar.") {
            EmptyView()
        } content: {
            ScrollView {
                SettingsContentView()
            }
        }
        .navigationTitle("Settings")
    }
}

private struct SettingsContentView: View {
    @EnvironmentObject var storageService: StorageService
    @EnvironmentObject var stockService: StockService
    @EnvironmentObject var updaterViewModel: UpdaterViewModel
    @State private var showResetAlert = false
    @State private var showClearPortfolioNotifs = false
    @State private var aiTestResult: String?
    @State private var aiTestIsLoading = false
    @State private var showAiKeyHelp = false
    @State private var showEditProfileSheet = false
    @State private var isLoadingModels = false
    @State private var modelFetchError: String? = nil
    @State private var showCustomModelField = false
    @State private var showApiKeyText = false
    @State private var telegramTesting = false
    @State private var telegramTestResult: (success: Bool, message: String)? = nil
    @State private var newScheduleDate: Date = {
        var c = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        c.hour = 7; c.minute = 30
        return Calendar.current.date(from: c) ?? Date()
    }()

    private var availableModelOptions: [(String, String)] {
        let list = storageService.availableModels(for: storageService.aiProvider)
        return list.map { ($0, $0) }
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
    var body: some View {
        // Two balanced columns so Settings occupies the same content
        // width as every other tab.
                HStack(alignment: .top, spacing: DS.gap) {
                    VStack(alignment: .leading, spacing: DS.gap) {
                        generalCard
                        aiReviewCard
                        investorProfileCard
                        menuBarCard
                        let withNotifs = storageService.portfolios.filter { !storageService.notifications(for: $0.id).isEmpty }
                        if !withNotifs.isEmpty { portfolioNotifsCard(withNotifs) }
                    }
                    VStack(alignment: .leading, spacing: DS.gap) {
                        tradingCard
                        notificationsCard
                        appearanceCard
                        aboutCard
                    }
                }
                .pageColumn()
                .padding(.top, 4)
        .dsAlert($showResetAlert, title: "Reset Settings",
                 message: "This will reset all settings to their defaults. Your portfolios and watchlist will not be affected.",
                 confirmTitle: "Reset", destructive: true) {
            storageService.resetToDefaults()
            Task { stockService.exchangeRates.removeAll(); await stockService.refreshAll(storageService: storageService) }
        }
        .dsAlert($showClearPortfolioNotifs, title: "Clear all portfolio notifications",
                 message: "This will delete all portfolio notifications across every portfolio. This cannot be undone.",
                 confirmTitle: "Clear all", destructive: true) { storageService.removeAllPortfolioNotifications() }
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
        .onAppear {
            storageService.syncLaunchAtLoginStatus()
        }
    }

    // MARK: - Cards

    private var investorProfileCard: some View {
        SettingsCard(title: "Investor Profile & Goals") {
            if let profile = storageService.investorProfile {
                SettingRow("Summary", caption: "Used by AI Review for customized portfolio advice") {
                    Text(profile.summaryDescription)
                        .font(.inter(11.5, weight: .medium, relativeTo: .caption))
                        .foregroundStyle(DS.ink)
                }
                SettingDivider()
                SettingRow("Primary goal", caption: profile.primaryGoal) {
                    EmptyView()
                }
                SettingDivider()
                HStack {
                    Button {
                        storageService.investorProfile = nil
                    } label: {
                        Text("Reset profile")
                            .font(.inter(11, weight: .medium, relativeTo: .caption))
                            .foregroundStyle(DS.down)
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()

                    Spacer()

                    Button {
                        showEditProfileSheet = true
                    } label: {
                        Text("Edit profile…")
                            .font(.inter(11, weight: .medium, relativeTo: .caption))
                            .foregroundStyle(DS.brand)
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                }
                .padding(.vertical, 2)
            } else {
                SettingRow("Status", caption: "Not configured yet. Set up your profile to receive tailored advice.") {
                    Button {
                        showEditProfileSheet = true
                    } label: {
                        Text("Set up profile…")
                            .font(.inter(11, weight: .semibold, relativeTo: .caption))
                            .foregroundStyle(DS.brand)
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                }
            }
        }
    }

    private var generalCard: some View {
        SettingsCard(title: "General") {
            SettingRow("Language") {
                DSPicker(options: StorageService.supportedLanguages.map { ($0.code, $0.name) },
                         selection: $storageService.appLanguage, width: 200)
            }
            SettingDivider()
            SettingRow("Stock price currency", caption: "How individual quotes are shown") {
                DSPicker(options: [("", "Original")] + StorageService.supportedCurrencies.map { ($0, "\(StorageService.currencySymbol(for: $0)) \($0)") },
                         selection: $storageService.stockPriceCurrency, width: 200)
                    .onChange(of: storageService.stockPriceCurrency) {
                        stockService.exchangeRates.removeAll()
                        Task { await stockService.refreshAll(storageService: storageService) }
                    }
            }
            SettingDivider()
            SettingRow("Portfolio currency", caption: "Totals and PnL are converted here") {
                DSPicker(options: StorageService.supportedCurrencies.map { ($0, "\(StorageService.currencySymbol(for: $0)) \($0)") },
                         selection: $storageService.preferredCurrency, width: 200)
                    .onChange(of: storageService.preferredCurrency) {
                        stockService.exchangeRates.removeAll()
                        Task { await stockService.refreshAll(storageService: storageService) }
                    }
            }
            SettingDivider()
            SettingRow("Secondary currency", caption: "Shows converted total (e.g. ≈ ₫) under portfolio totals") {
                DSPicker(options: [("", "None")] + StorageService.supportedCurrencies.map { ($0, "\(StorageService.currencySymbol(for: $0)) \($0)") },
                         selection: $storageService.secondaryCurrency, width: 200)
                    .onChange(of: storageService.secondaryCurrency) {
                        Task { await stockService.refreshExchangeRates(storageService: storageService, force: true) }
                    }
            }
            SettingDivider()
            SettingToggle("Launch at login",
                          caption: "Automatically start StockDeck when you log into your Mac",
                          isOn: $storageService.launchAtLogin)
        }
    }

    private var aiReviewCard: some View {
        SettingsCard(title: "AI Review") {
            SettingRow("API key", caption: "Stored in the Keychain, never in plaintext files") {
                DSFocusableContainer { focused in
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
                                .textFieldStyle(.plain)
                                .font(.inter(11.5, relativeTo: .caption).monospacedDigit())
                                .focused(focused)
                        } else {
                            SecureField("sk-… / AIzaSy…", text: Binding(
                                get: { storageService.aiApiKey },
                                set: {
                                    storageService.aiApiKey = $0
                                    if !storageService.aiApiKey.isEmpty {
                                        loadModels(silent: true)
                                    }
                                }))
                                .textFieldStyle(.plain)
                                .font(.inter(11.5, relativeTo: .caption).monospacedDigit())
                                .focused(focused)
                        }

                        Button {
                            withAnimation {
                                showApiKeyText.toggle()
                            }
                        } label: {
                            Image(systemName: showApiKeyText ? "eye.slash" : "eye")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(DS.inkSecondary)
                        }
                        .buttonStyle(.plain)
                        .pointingHandCursor()
                        .help(showApiKeyText ? "Hide API key" : "Show API key")

                        Button {
                            storageService.aiApiKey = ""
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(storageService.aiApiKey.isEmpty ? DS.inkTertiary : DS.down)
                        }
                        .buttonStyle(.plain)
                        .disabled(storageService.aiApiKey.isEmpty)
                        .pointingHandCursor()
                        .help("Remove the stored API key")
                    }
                }
            }
            SettingDivider()
            SettingRow("Provider", caption: "Google Gemini, OpenAI, DeepSeek, Groq, OpenRouter, etc.") {
                DSPicker(options: AIProviderOption.all.map { ($0.value.rawValue, $0.label) },
                         selection: $storageService.aiProvider, width: 200)
                    .onChange(of: storageService.aiProvider) { _, newValue in
                        storageService.applyAIPreset(newValue)
                        loadModels(silent: true)
                    }
            }
            SettingDivider()
            if storageService.aiProvider == "custom" {
                SettingRow("Base URL") {
                    TextField("https://api.example.com/v1", text: $storageService.aiBaseURL)
                        .textFieldStyle(.plain)
                        .font(.inter(11, relativeTo: .caption).monospacedDigit())
                        .frame(width: 220)
                }
                SettingDivider()
            }
            SettingRow("Model") {
                HStack(spacing: 8) {
                    if showCustomModelField {
                        TextField("Model ID (e.g. gemini-2.0-flash)", text: $storageService.aiModel)
                            .textFieldStyle(.plain)
                            .font(.inter(11, relativeTo: .caption).monospacedDigit())
                            .frame(width: 200)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(DS.cardAlt))
                    } else {
                        DSPicker(options: availableModelOptions, selection: $storageService.aiModel, width: 200)
                    }

                    Button {
                        loadModels()
                    } label: {
                        HStack(spacing: 4) {
                            if isLoadingModels {
                                DSSpinner(size: 10)
                            } else {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 10, weight: .semibold))
                            }
                            Text("Load")
                                .font(.inter(10.5, weight: .medium, relativeTo: .caption))
                        }
                        .foregroundStyle(DS.brand)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(DS.cardAlt))
                    }
                    .buttonStyle(.plain)
                    .disabled(isLoadingModels || storageService.aiApiKey.isEmpty || storageService.aiBaseURL.isEmpty)
                    .pointingHandCursor()
                    .help("Fetch available models from provider")

                    Button {
                        withAnimation {
                            showCustomModelField.toggle()
                        }
                    } label: {
                        Image(systemName: showCustomModelField ? "list.bullet" : "pencil")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(DS.inkSecondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 5)
                            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(DS.cardAlt))
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                    .help(showCustomModelField ? "Switch to model dropdown" : "Type custom model ID")
                }
            }
            if let err = modelFetchError {
                Text("Lỗi tải danh sách model: \(err)")
                    .font(DS.micro)
                    .foregroundStyle(DS.down)
                    .padding(.horizontal, 16)
            } else if let cached = storageService.cachedModelsByProvider[storageService.aiProvider], !cached.isEmpty {
                Text("Đã tải \(cached.count) models từ server")
                    .font(DS.micro)
                    .foregroundStyle(DS.up)
                    .padding(.horizontal, 16)
            }
            if storageService.aiProvider == "deepseek" {
                SettingDivider()
                SettingToggle("Thinking mode (V4)",
                              caption: "DeepSeek V4 defaults to thinking on. Turn off for fast chat (like the retired deepseek-chat).",
                              isOn: $storageService.aiDeepseekThinking)
            }
            SettingDivider()
            SettingRow("Workspace folder", caption: "A folder the assistant reads & writes as long-term memory (ai-context.md). Durable notes survive across sessions — no need to re-answer every time.") {
                workspaceFolderControl
            }
            SettingDivider()
            HStack {
                if let result = aiTestResult {
                    Text(result)
                        .font(DS.micro)
                        .foregroundStyle(result.hasPrefix("✓") ? DS.up : DS.down)
                        .lineLimit(2)
                    Spacer()
                } else {
                    Spacer()
                }
                if aiTestIsLoading {
                    HStack(spacing: 6) {
                        DSSpinner(size: 11)
                        Text("Testing…").font(.inter(11, weight: .medium, relativeTo: .caption)).foregroundStyle(DS.inkSecondary)
                    }
                } else {
                    Button("Test connection") {
                        Task { await runAITest() }
                    }
                    .buttonStyle(.plain)
                    .font(.inter(11, weight: .medium, relativeTo: .caption))
                    .foregroundStyle(storageService.hasAIConfiguration ? DS.brand : DS.inkTertiary)
                    .disabled(!storageService.hasAIConfiguration)
                    .pointingHandCursor()
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func runAITest() async {
        aiTestIsLoading = true
        aiTestResult = nil
        defer { aiTestIsLoading = false }
        let result = await TestAI.testConnection(storageService: storageService)
        aiTestResult = result.message
    }

    @ViewBuilder
    private var workspaceFolderControl: some View {
        VStack(alignment: .leading, spacing: 6) {
            if storageService.aiWorkspacePath.isEmpty {
                Text("Not set")
                    .font(.inter(11.5, relativeTo: .caption))
                    .foregroundStyle(DS.inkTertiary)
            } else {
                Text((storageService.aiWorkspacePath as NSString).lastPathComponent)
                    .font(.inter(11.5, weight: .medium, relativeTo: .caption))
                    .foregroundStyle(DS.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(storageService.aiWorkspacePath)
            }
            HStack(spacing: 8) {
                Button("Choose…") {
                    chooseWorkspaceFolder()
                }
                .buttonStyle(.plain)
                .font(.inter(11, weight: .medium, relativeTo: .caption))
                .foregroundStyle(DS.brand)
                .pointingHandCursor()
                if !storageService.aiWorkspacePath.isEmpty {
                    Button("Open") {
                        if let folder = storageService.ensureAIWorkspace() {
                            NSWorkspace.shared.open(folder)
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.inter(11, weight: .medium, relativeTo: .caption))
                    .foregroundStyle(DS.inkSecondary)
                    .pointingHandCursor()
                    Button("Remove") {
                        storageService.aiWorkspacePath = ""
                    }
                    .buttonStyle(.plain)
                    .font(.inter(11, weight: .medium, relativeTo: .caption))
                    .foregroundStyle(DS.down)
                    .pointingHandCursor()
                }
            }
        }
    }

    private func chooseWorkspaceFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose a folder StockDeck AI Review should use as long-term memory (ai-context.md)."
        if panel.runModal() == .OK, let url = panel.url {
            storageService.aiWorkspacePath = url.path
        }
    }

    private var tradingCard: some View {
        SettingsCard(title: "Trading") {
            SettingToggle("Short positions & leverage",
                          caption: "Unlocks negative quantity and a leverage field",
                          isOn: $storageService.advancedPositions)
            SettingDivider()
            SettingToggle("Extended hours (Pre/Post)",
                          caption: "Show pre-market and after-hours prices",
                          isOn: $storageService.showExtendedHours)
            SettingDivider()
            SettingRow("Default chart", caption: "Style used when opening a stock chart") {
                DSPicker(options: [("line", "Line chart"), ("tradingview", "TradingView")],
                         selection: $storageService.defaultChartStyle, width: 160)
            }
        }
    }


    private var menuBarCard: some View {
        SettingsCard(title: "Menu bar") {
            SettingRow("Display") {
                DSPicker(options: [
                    ("pnl", "PnL (+321.09€)"),
                    ("pnlPercent", "PnL % (+2.3%)"),
                    ("pnlFull", "PnL + %"),
                    ("todayPnlFull", "Today (+321.09€ +1.2%)"),
                    ("totalValue", "Total value"),
                    ("bestStock", "Best stock"),
                    ("worstStock", "Worst stock"),
                    ("bestWorst", "Best & Worst"),
                    ("portfolioRecap", "Portfolio recap"),
                    ("ticker", "Ticker (cycle watchlist)"),
                    ("tickerPortfolio", "Ticker + Portfolio"),
                    ("icon", "Icon only"),
                ], selection: $storageService.menuBarDisplay, width: 230)
            }
            if storageService.menuBarDisplay == "todayPnlFull" {
                Text("Uses regular-market prices. Crypto Today resets at 00:00 UTC.")
                    .font(DS.micro)
                    .foregroundStyle(DS.inkTertiary)
            }
            SettingDivider()
            SettingRow("Percentage decimals", caption: "Digits after the decimal point (e.g. +2.34%)") {
                DSPicker(options: [(0, "0"), (1, "1"), (2, "2"), (3, "3"), (4, "4")],
                         selection: $storageService.percentDecimals, width: 110)
            }
            SettingDivider()
            SettingRow("Value decimals", caption: "Prices & amounts. Auto = extra precision for forex / sub-dollar") {
                DSPicker(options: [(-1, "Auto"), (0, "0"), (1, "1"), (2, "2"), (3, "3"), (4, "4")],
                         selection: $storageService.valueDecimals, width: 110)
            }
            SettingDivider()
            SettingToggle("Hide percentage change",
                          caption: "Show only price / value, no % in the menu bar",
                          isOn: $storageService.menuBarHidePercent)
            if storageService.menuBarDisplay == "ticker" || storageService.menuBarDisplay == "tickerPortfolio" {
                SettingDivider()
                SettingToggle("Show name instead of symbol",
                              caption: "\"S&P 500\" instead of \"^GSPC\"",
                              isOn: $storageService.tickerShowName)
                SettingDivider()
                SettingRow("Ticker order") {
                    DSPicker(options: [("manual", "As added"), ("type", "By type"), ("alpha", "Alphabetical")],
                             selection: $storageService.watchlistSort, width: 180)
                }
            }
            SettingDivider()
            SettingRow("Menu bar shortcut", caption: "Press anywhere on macOS to open or close the menu bar popup") {
                ShortcutRecorderView(shortcut: $storageService.menuBarShortcut)
            }
            SettingDivider()
            SettingRow("Desktop app shortcut", caption: "Press anywhere on macOS to open or close the desktop app window") {
                ShortcutRecorderView(
                    shortcut: $storageService.desktopAppShortcut,
                    presets: [
                        ("⌥ D (Option + D)", .presetOptionD),
                        ("⌘ ⇧ D (Command + Shift + D)", .presetCmdShiftD),
                        ("⌃ ⌥ D (Control + Option + D)", .presetControlOptionD),
                        ("⌥ Space (Option + Space)", .presetOptionSpace)
                    ]
                )
            }
            SettingDivider()
            SettingRow("Gain color", caption: "Applies across the whole app — menu bar, watchlist and portfolios") {
                DSColorWell(color: Binding(
                    get: { Color(nsColor: storageService.gainColor) },
                    set: { storageService.gainColorHex = $0.hexString }))
            }
            SettingDivider()
            SettingRow("Loss color") {
                DSColorWell(color: Binding(
                    get: { Color(nsColor: storageService.lossColor) },
                    set: { storageService.lossColorHex = $0.hexString }))
            }
            SettingDivider()
            HStack {
                Spacer()
                Button("Reset to default green/red") {
                    storageService.gainColorHex = ""; storageService.lossColorHex = ""
                }
                .buttonStyle(.plain)
                .font(.inter(11, weight: .medium, relativeTo: .caption))
                .foregroundStyle(DS.brand)
            }
            .padding(.vertical, 6)
        }
    }

    private var notificationsCard: some View {
        SettingsCard(title: "Notifications") {
            // MARK: - Telegram Bot Section
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(DS.brand)
                    Text("Telegram Bot")
                        .font(DS.bodyStrong)
                        .foregroundStyle(DS.ink)
                }

                SettingToggle("Send reports to Telegram Bot",
                              caption: "Receive consolidated All-Portfolios summaries & price alerts directly on your phone",
                              isOn: $storageService.telegramEnabled)

                if storageService.telegramEnabled {
                    SettingDivider()

                    VStack(alignment: .leading, spacing: 12) {
                        // Bot Token
                        VStack(alignment: .leading, spacing: 4) {
                            Text("BOT TOKEN")
                                .font(DS.label)
                                .foregroundStyle(DS.inkTertiary)
                                .tracking(0.8)

                            DSFocusableContainer { focused in
                                HStack(spacing: 8) {
                                    Image(systemName: "key.fill")
                                        .font(.system(size: 10))
                                        .foregroundStyle(DS.inkTertiary)
                                    SecureField("123456789:ABCdefGhIJKlmNoPQRsTUVwxyZ", text: $storageService.telegramBotToken)
                                        .textFieldStyle(.plain)
                                        .font(.inter(11.5, relativeTo: .caption).monospacedDigit())
                                        .focused(focused)
                                }
                            }

                            Text("Get a Bot Token by messaging @BotFather on Telegram.")
                                .font(DS.micro)
                                .foregroundStyle(DS.inkTertiary)
                        }

                        // Chat ID
                        VStack(alignment: .leading, spacing: 4) {
                            Text("CHAT ID")
                                .font(DS.label)
                                .foregroundStyle(DS.inkTertiary)
                                .tracking(0.8)

                            DSFocusableContainer { focused in
                                HStack(spacing: 8) {
                                    Image(systemName: "number")
                                        .font(.system(size: 10))
                                        .foregroundStyle(DS.inkTertiary)
                                    TextField("123456789 or @channel", text: $storageService.telegramChatId)
                                        .textFieldStyle(.plain)
                                        .font(.inter(11.5, relativeTo: .caption).monospacedDigit())
                                        .focused(focused)
                                }
                            }

                            Text("Your Telegram user ID from @userinfobot or group/channel username.")
                                .font(DS.micro)
                                .foregroundStyle(DS.inkTertiary)
                        }

                        // Test button & status
                        HStack {
                            if let res = telegramTestResult {
                                HStack(spacing: 4) {
                                    Image(systemName: res.success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                        .foregroundStyle(res.success ? DS.up : DS.down)
                                    Text(res.message)
                                        .font(DS.micro)
                                        .foregroundStyle(res.success ? DS.up : DS.down)
                                }
                            }
                            Spacer()
                            Button(action: sendTelegramReport) {
                                if telegramTesting {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Text("Send Report")
                                }
                            }
                            .buttonStyle(.plain)
                            .font(.inter(11, weight: .medium, relativeTo: .caption))
                            .foregroundStyle(!storageService.telegramBotToken.isEmpty && !storageService.telegramChatId.isEmpty ? DS.brand : DS.inkTertiary)
                            .disabled(telegramTesting || storageService.telegramBotToken.isEmpty || storageService.telegramChatId.isEmpty)
                        }

                        SettingDivider()

                        // Multiple Schedules Section
                        VStack(alignment: .leading, spacing: 8) {
                            Text("SCHEDULED SUMMARIES (ALL PORTFOLIOS)")
                                .font(DS.label)
                                .foregroundStyle(DS.inkTertiary)
                                .tracking(0.8)

                            Text("Consolidated summary of all portfolios will be sent at these times every day:")
                                .font(DS.micro)
                                .foregroundStyle(DS.inkSecondary)

                            if storageService.telegramSchedules.isEmpty {
                                Text("No schedules configured. Add one below.")
                                    .font(DS.micro)
                                    .foregroundStyle(DS.inkTertiary)
                                    .padding(.vertical, 4)
                            } else {
                                VStack(spacing: 6) {
                                    ForEach(storageService.telegramSchedules, id: \.self) { sched in
                                        HStack(spacing: 8) {
                                            Image(systemName: "clock.fill")
                                                .font(.system(size: 11))
                                                .foregroundStyle(DS.brand)

                                            Text(sched)
                                                .font(.inter(12, weight: .semibold, relativeTo: .body).monospacedDigit())
                                                .foregroundStyle(DS.ink)

                                            Text(TelegramReportBuilder.scheduleDescription(sched, lang: storageService.appLanguage))
                                                .font(DS.micro)
                                                .foregroundStyle(DS.inkTertiary)

                                            Spacer()

                                            Button {
                                                removeSchedule(sched)
                                            } label: {
                                                Image(systemName: "trash")
                                                    .font(.system(size: 11))
                                                    .foregroundStyle(DS.inkTertiary)
                                            }
                                            .buttonStyle(.plain)
                                            .pointingHandCursor()
                                        }
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 6)
                                        .background(RoundedRectangle(cornerRadius: 6).fill(DS.cardAlt.opacity(0.6)))
                                    }
                                }
                            }

                            // Presets & Custom add
                            HStack(spacing: 6) {
                                Text("Presets:")
                                    .font(DS.micro)
                                    .foregroundStyle(DS.inkTertiary)

                                Button("+ 07:30 (US)") { addSchedule("07:30") }
                                    .buttonStyle(.bordered)
                                    .controlSize(.mini)
                                    .disabled(storageService.telegramSchedules.contains("07:30"))

                                Button("+ 15:30 (VN/JP)") { addSchedule("15:30") }
                                    .buttonStyle(.bordered)
                                    .controlSize(.mini)
                                    .disabled(storageService.telegramSchedules.contains("15:30"))

                                Button("+ 21:00") { addSchedule("21:00") }
                                    .buttonStyle(.bordered)
                                    .controlSize(.mini)
                                    .disabled(storageService.telegramSchedules.contains("21:00"))

                                Spacer()

                                DatePicker("", selection: $newScheduleDate, displayedComponents: .hourAndMinute)
                                    .labelsHidden()
                                    .controlSize(.small)

                                Button("Add") {
                                    let f = DateFormatter()
                                    f.dateFormat = "HH:mm"
                                    addSchedule(f.string(from: newScheduleDate))
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(DS.brand)
                                .controlSize(.mini)
                            }
                            .padding(.top, 4)
                        }

                        SettingDivider()

                        SettingToggle("Forward Stock Price & Buy Target Alerts",
                                      caption: "Alerts when a stock enters your buy target zone or crosses price thresholds",
                                      isOn: $storageService.telegramNotifyBuyTargets)
                    }
                    .padding(.vertical, 4)
                }
            }

            SettingDivider()

            // MARK: - Discord / Slack Webhook Section
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "bubble.left.and.bubble.right.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(DS.inkSecondary)
                    Text("Discord / Slack Webhook")
                        .font(DS.bodyStrong)
                        .foregroundStyle(DS.ink)
                }

                SettingToggle("Mirror to a Discord/Slack webhook",
                              caption: "Price alerts and portfolio notifications are also sent there",
                              isOn: $storageService.discordEnabled)

                if storageService.discordEnabled {
                    SettingDivider()
                    let trimmed = storageService.discordWebhookURL.trimmingCharacters(in: .whitespacesAndNewlines)
                    VStack(alignment: .leading, spacing: 8) {
                        DSFocusableContainer { focused in
                            HStack(spacing: 8) {
                                Image(systemName: "link").font(.system(size: 10)).foregroundStyle(DS.inkTertiary)
                                TextField("https://discord.com/api/webhooks/…", text: $storageService.discordWebhookURL)
                                    .textFieldStyle(.plain)
                                    .font(.inter(11.5, relativeTo: .caption).monospacedDigit())
                                    .focused(focused)
                            }
                        }

                        HStack {
                            if !trimmed.isEmpty && !WebhookNotifier.isValid(trimmed) {
                                Text("Not a valid Discord or Slack webhook URL (must be https).")
                                    .font(DS.micro).foregroundStyle(DS.down)
                            }
                            Spacer()
                            Button("Send test") {
                                NotificationManager.shared.send(title: "StockDeck test", body: "Webhook is working ✅", sentiment: .positive)
                            }
                            .buttonStyle(.plain)
                            .font(.inter(11, weight: .medium, relativeTo: .caption))
                            .foregroundStyle(WebhookNotifier.isValid(trimmed) ? DS.brand : DS.inkTertiary)
                            .disabled(!WebhookNotifier.isValid(trimmed))
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private func addSchedule(_ sched: String) {
        guard !storageService.telegramSchedules.contains(sched) else { return }
        var list = storageService.telegramSchedules
        list.append(sched)
        list.sort()
        storageService.telegramSchedules = list
    }

    private func removeSchedule(_ sched: String) {
        storageService.telegramSchedules.removeAll { $0 == sched }
    }

    private func sendTelegramReport() {
        telegramTesting = true
        telegramTestResult = nil
        Task {
            let res = await TelegramService.sendReport(
                storageService: storageService,
                stockService: stockService
            )
            await MainActor.run {
                telegramTesting = false
                switch res {
                case .success(let msg):
                    telegramTestResult = (true, msg)
                case .failure(let err):
                    telegramTestResult = (false, err.localizedDescription)
                }
            }
        }
    }

    private func portfolioNotifsCard(_ portfolios: [Portfolio]) -> some View {
        SettingsCard(title: "Portfolio notifications") {
            ForEach(portfolios) { portfolio in
                Text(portfolio.name)
                    .font(DS.bodyStrong).foregroundStyle(DS.inkSecondary)
                    .padding(.top, 4)
                ForEach(storageService.notifications(for: portfolio.id)) { n in
                    PortfolioNotifRow(portfolioId: portfolio.id, notification: n)
                }
                if portfolio.id != portfolios.last?.id { SettingDivider() }
            }
            SettingDivider()
            HStack {
                Spacer()
                Button("Clear all portfolio notifications") { showClearPortfolioNotifs = true }
                    .buttonStyle(.plain)
                    .font(.inter(11, weight: .medium, relativeTo: .caption))
                    .foregroundStyle(DS.down)
            }
            .padding(.vertical, 6)
        }
    }

    private var appearanceCard: some View {
        SettingsCard(title: "Appearance") {
            SettingRow("Theme") {
                DSPicker(options: AppearanceMode.allCases.map { ($0, $0.label) },
                         selection: Binding(get: { storageService.appearanceMode },
                                            set: { storageService.appearanceMode = $0 }),
                         width: 160)
            }
            SettingDivider()
            SettingRow("Font") {
                DSPicker(options: FontRegistration.availableFonts.map { ($0.family, $0.label) },
                         selection: $storageService.fontFamily, width: 200)
            }
            SettingDivider()
            SettingRow("Text size") {
                HStack(spacing: 10) {
                    Text("A").font(.inter(10, relativeTo: .caption)).foregroundStyle(DS.inkTertiary)
                    DSSlider(value: Binding(get: { Double(storageService.fontSizeLevel) },
                                            set: { storageService.fontSizeLevel = Int($0) }),
                             range: 7...13, step: 1, width: 160)
                    Text("A").font(.inter(15, weight: .bold, relativeTo: .body)).foregroundStyle(DS.inkTertiary)
                    Text("\(storageService.fontSizeLevel)")
                        .font(DS.figure).foregroundStyle(DS.inkSecondary)
                        .frame(width: 18, alignment: .trailing)
                }
            }
        }
    }

    private var aboutCard: some View {
        SettingsCard(title: "About") {
            SettingRow("Updates") {
                Button("Check for Updates…") {
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate(ignoringOtherApps: true)
                    updaterViewModel.checkForUpdates()
                }
                .buttonStyle(.plain)
                .font(.inter(11.5, weight: .medium, relativeTo: .caption))
                .foregroundStyle(updaterViewModel.canCheckForUpdates ? DS.brand : DS.inkTertiary)
                .disabled(!updaterViewModel.canCheckForUpdates)
            }
            SettingDivider()
            SettingRow("StockDeck is free and open source",
                       caption: "If you'd like to support me, become a sponsor — or simply star the repo. Both help, and every feature stays free.") {
                HStack(spacing: 8) {
                    Button {
                        if let url = URL(string: "https://github.com/sponsors/tuyennq1001") { NSWorkspace.shared.open(url) }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "heart.fill").font(.system(size: 9))
                            Text("Sponsor").font(.inter(11.5, weight: .semibold, relativeTo: .caption)).lineLimit(1)
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12).padding(.vertical, 5)
                        .background(Capsule().fill(Color(red: 0.86, green: 0.30, blue: 0.46)))
                    }
                    .buttonStyle(.plain)

                    Button {
                        if let url = URL(string: "https://github.com/tuyennq1001/stockdeck") { NSWorkspace.shared.open(url) }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "star.fill").font(.system(size: 9))
                            Text("Star").font(.inter(11.5, weight: .semibold, relativeTo: .caption)).lineLimit(1)
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12).padding(.vertical, 5)
                        .background(Capsule().fill(Color(red: 0.92, green: 0.70, blue: 0.15)))
                    }
                    .buttonStyle(.plain)
                }
                .fixedSize()
            }
            SettingDivider()
            SettingRow("Reset", caption: "Portfolios and watchlist are not affected") {
                Button("Reset to Defaults…") { showResetAlert = true }
                    .buttonStyle(.plain)
                    .font(.inter(11.5, weight: .medium, relativeTo: .caption))
                    .foregroundStyle(DS.down)
            }
        }
    }
}

// MARK: - Settings building blocks

/// A premium card holding a stack of setting rows.
private struct SettingsCard<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(title)
                .padding(.bottom, 4)
            content
        }
        .padding(.horizontal, DS.pad)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .premiumCard()
    }
}

/// Label (+ optional caption) on the left, control on the right.
private struct SettingRow<Control: View>: View {
    let label: String
    var caption: String? = nil
    @ViewBuilder var control: Control

    init(_ label: String, caption: String? = nil, @ViewBuilder control: () -> Control) {
        self.label = label
        self.caption = caption
        self.control = control()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey(label)).font(DS.body).foregroundStyle(DS.ink)
                if let caption {
                    Text(LocalizedStringKey(caption)).font(DS.micro).foregroundStyle(DS.inkTertiary)
                }
            }
            Spacer(minLength: 16)
            control
        }
        .padding(.vertical, 7)
    }
}

/// A toggle row in the app's emerald.
private struct SettingToggle: View {
    let label: String
    var caption: String? = nil
    @Binding var isOn: Bool

    init(_ label: String, caption: String? = nil, isOn: Binding<Bool>) {
        self.label = label
        self.caption = caption
        self._isOn = isOn
    }

    var body: some View {
        SettingRow(label, caption: caption) {
            DSToggle(isOn: $isOn)
        }
    }
}

private struct SettingDivider: View {
    var body: some View {
        Divider().overlay(DS.hairline.opacity(0.6))
    }
}
