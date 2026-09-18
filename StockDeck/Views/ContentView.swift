import SwiftUI

enum Tab: String, CaseIterable {
    case home = "Home"
    case watchlist = "Watchlists"
    case portfolios = "Portfolios"
    case utilities = "Utilities"
    case settings = "Settings"
}

extension Tab {
    var icon: String {
        switch self {
        case .home: return "newspaper"
        case .watchlist: return "list.bullet"
        case .portfolios: return "briefcase"
        case .utilities: return "wrench.and.screwdriver"
        case .settings: return "gear"
        }
    }

    static var visible: [Tab] {
        [.home, .watchlist, .portfolios, .utilities, .settings]
    }

    /// Resolve a persisted tab selection against valid tabs.
    static func resolve(stored: String) -> Tab {
        let normalized = stored == "Watchlist" ? "Watchlists" : stored
        if let t = Tab(rawValue: normalized) { return t }
        return .home
    }
}

// Environment keys for navigation from child views
struct ShowSymbolDetailAction {
    let perform: (String) -> Void
}

private struct ShowSymbolDetailActionKey: EnvironmentKey {
    static let defaultValue = ShowSymbolDetailAction { _ in }
}

struct AddHoldingAction {
    let performHandler: (UUID, String?) -> Void

    init(perform: @escaping (UUID, String?) -> Void) {
        self.performHandler = perform
    }

    init(perform: @escaping (UUID) -> Void) {
        self.performHandler = { id, _ in perform(id) }
    }

    func perform(_ portfolioId: UUID, _ symbol: String? = nil) {
        performHandler(portfolioId, symbol)
    }
}

struct EditHoldingAction {
    let perform: (UUID, Holding) -> Void
}

private struct AddHoldingActionKey: EnvironmentKey {
    static let defaultValue = AddHoldingAction { _ in }
}

private struct EditHoldingActionKey: EnvironmentKey {
    static let defaultValue = EditHoldingAction { _, _ in }
}

/// Injected by AppDelegate so the popover opens the desktop window by calling
/// AppDelegate directly — no fragile `NSApp.delegate as? AppDelegate` cast that
/// can silently fail in a SwiftUI app.
private struct OpenWindowActionKey: EnvironmentKey {
    static let defaultValue: () -> Void = {
        NSLog("[StockDeck] Open tapped but no openWindowAction was injected")
    }
}

/// The per-portfolio actions (same as the sidebar right-click menu), injected by
/// AppDelegate/PortfolioWindowView so the Overview header can offer them too.
struct PortfolioActions {
    var addHolding: (UUID) -> Void = { _ in }
    var batchImport: (UUID) -> Void = { _ in }
    var rename: (UUID, String) -> Void = { _, _ in }
    var notifications: (UUID, String) -> Void = { _, _ in }
    var export: (Portfolio) -> Void = { _ in }
    var delete: (UUID) -> Void = { _ in }
}

private struct PortfolioActionsKey: EnvironmentKey {
    static let defaultValue = PortfolioActions()
}

extension EnvironmentValues {
    var showSymbolDetail: ShowSymbolDetailAction {
        get { self[ShowSymbolDetailActionKey.self] }
        set { self[ShowSymbolDetailActionKey.self] = newValue }
    }
    var addHoldingAction: AddHoldingAction {
        get { self[AddHoldingActionKey.self] }
        set { self[AddHoldingActionKey.self] = newValue }
    }
    var editHoldingAction: EditHoldingAction {
        get { self[EditHoldingActionKey.self] }
        set { self[EditHoldingActionKey.self] = newValue }
    }
    var openWindowAction: () -> Void {
        get { self[OpenWindowActionKey.self] }
        set { self[OpenWindowActionKey.self] = newValue }
    }
    var portfolioActions: PortfolioActions {
        get { self[PortfolioActionsKey.self] }
        set { self[PortfolioActionsKey.self] = newValue }
    }
}

struct ContentView: View {
    @EnvironmentObject var stockService: StockService
    @EnvironmentObject var storageService: StorageService
    @Environment(\.openWindowAction) private var openWindowAction
    @Namespace private var tabAnimation
    @State private var selectedTab: Tab = .watchlist
    @State private var showSearch = false
    @State private var addHoldingPortfolioId: UUID?
    @State private var selectedDetailSymbol: String?

    var body: some View {
        Group {
            if let symbol = selectedDetailSymbol {
                SymbolDetailView(
                    symbol: symbol,
                    onAddToPortfolio: { portfolioId in
                        addHoldingPortfolioId = portfolioId
                    },
                    onDismiss: {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            selectedDetailSymbol = nil
                        }
                    }
                )
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .trailing).combined(with: .opacity)
                ))
            } else if let portfolioId = addHoldingPortfolioId {
                AddHoldingView(portfolioId: portfolioId, isPresented: $addHoldingPortfolioId)
            } else {
                mainContent
            }
        }
        .environment(\.showSymbolDetail, ShowSymbolDetailAction { symbol in
            withAnimation(.easeInOut(duration: 0.18)) {
                selectedDetailSymbol = symbol
            }
        })
        .frame(width: 462, height: 520)
        .preferredColorScheme(storageService.appearanceMode.colorScheme)
        .onAppear {
            selectedTab = Tab.resolve(stored: storageService.lastSelectedTab)
        }
        .onChange(of: selectedTab) { _, newValue in
            storageService.lastSelectedTab = newValue.rawValue
        }
    }

    /// Marketing version (CFBundleShortVersionString) prefixed with "v", e.g. "v1.0".
    private var appVersion: String {
        let v = BundleInfo.versionString
        return "v\(v)"
    }

    private var mainContent: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                HStack(spacing: 7) {
                    BrandMark(size: 22)
                    Text("StockDeck")
                        .font(.inter(13, weight: .bold, relativeTo: .headline))
                        .foregroundStyle(DS.ink)
                    Text(appVersion)
                        .font(.inter(10, weight: .medium, relativeTo: .caption2))
                        .foregroundColor(.secondary)
                    // Dev builds ship without a Sparkle feed URL — flag them so a dev
                    // window is never mistaken for the released app.
                    if BundleInfo.isDevBuild {
                        Text("DEV")
                            .font(.inter(8, weight: .bold, relativeTo: .caption2))
                            .foregroundColor(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(RoundedRectangle(cornerRadius: 3).fill(DS.gold))
                    }
                }

                Button(action: {
                    Task {
                        await stockService.refreshAll(storageService: storageService)
                        if selectedTab == .home {
                            await stockService.refreshNews(storageService: storageService, force: true)
                        }
                    }
                }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.inter(12, relativeTo: .callout))
                        .foregroundStyle(DS.inkSecondary)
                }
                .buttonStyle(.plain)
                .disabled(stockService.isLoading)
                .pointingHandCursor()
                .help("Refresh quotes")

                // The clear way into the full desktop app.
                Button(action: {
                    NSLog("[StockDeck] Open button tapped in popover")
                    openWindowAction()
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "macwindow")
                        Text("Open")
                    }
                    .font(.inter(11, weight: .semibold, relativeTo: .caption))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(Capsule().fill(DS.brand))
                    .contentShape(Capsule())
                    .pointingHandCursor()
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                .help("Open the full StockDeck window")

                // Settings gear button placed immediately to the right of Open button
                Button(action: { selectedTab = .settings }) {
                    Image(systemName: selectedTab == .settings ? "gearshape.fill" : "gearshape")
                        .font(.inter(12, relativeTo: .callout))
                        .foregroundStyle(selectedTab == .settings ? DS.brand : DS.inkSecondary)
                }
                .buttonStyle(.borderless)
                .pointingHandCursor()
                .help("Settings")

                Button(action: { NSApp.terminate(nil) }) {
                    Image(systemName: "power")
                        .font(.inter(11, relativeTo: .subheadline))
                }
                .buttonStyle(.borderless)
                .pointingHandCursor()
                .help("Quit StockDeck")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            // Tab picker with pointer cursor for tabs
            HStack(spacing: 0) {
                tabButton("Home", tab: .home)
                tabButton("Watchlists", tab: .watchlist)
                tabButton("Portfolios", tab: .portfolios)
            }
            .padding(3)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            )
            .padding(.horizontal, 16)
            .padding(.bottom, 8)

            Divider()

            // Content
            Group {
                switch selectedTab {
                case .home:
                    HomeView()
                case .watchlist:
                    WatchlistView(showSearch: $showSearch)
                case .portfolios:
                    PortfolioListView()
                case .utilities:
                    UtilitiesView()
                case .settings:
                    SettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(DS.ground)
        }
        .tint(DS.brand)
        .environment(\.addHoldingAction, AddHoldingAction { portfolioId in
            addHoldingPortfolioId = portfolioId
        })
        // Issue #7: in-app language override. Reactive because ContentView observes
        // storageService, so changing the language re-applies the locale to all children.
        .environment(\.locale, Locale(identifier: storageService.appLanguage))
    }

    private func tabButton(_ title: String, tab: Tab) -> some View {
        let isSelected = selectedTab == tab
        return Button(action: {
            withAnimation(.easeInOut(duration: 0.2)) {
                selectedTab = tab
            }
        }) {
            Text(LocalizedStringKey(title))
                .font(.inter(11, weight: isSelected ? .semibold : .medium, relativeTo: .caption))
                .foregroundStyle(isSelected ? DS.ink : DS.inkSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(DS.card)
                            .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
                            .matchedGeometryEffect(id: "popoverTabSelection", in: tabAnimation)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
    }
}
