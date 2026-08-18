import SwiftUI

enum Tab: String, CaseIterable {
    case home = "Home"
    case watchlist = "Watchlist"
    case portfolios = "Portfolios"
    case settings = "Settings"
}

extension Tab {
    var icon: String {
        switch self {
        case .home: return "newspaper"
        case .watchlist: return "list.bullet"
        case .portfolios: return "briefcase"
        case .settings: return "gear"
        }
    }

    /// Issue #11: the tabs that actually render, in order. The Home/News tab is
    /// opt-out — when hidden, Watchlist leads. Single source of truth so the tab
    /// bar, the content switch and the restored-selection logic never disagree.
    static func visible(showNews: Bool) -> [Tab] {
        let all: [Tab] = [.home, .watchlist, .portfolios, .settings]
        return showNews ? all : all.filter { $0 != .home }
    }

    /// Resolve a persisted tab against the current visibility: a stored selection
    /// that's now hidden (e.g. "Home" after News was turned off) falls back to the
    /// first visible tab so the user is never stranded on a blank tab.
    static func resolve(stored: String, showNews: Bool) -> Tab {
        let tabs = visible(showNews: showNews)
        if let t = Tab(rawValue: stored), tabs.contains(t) { return t }
        return tabs.first ?? .watchlist
    }
}

// Environment keys for navigation from child views
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

    var body: some View {
        Group {
            if showSearch {
                SearchView(mode: .watchlist, isPresented: $showSearch)
            } else if let portfolioId = addHoldingPortfolioId {
                AddHoldingView(portfolioId: portfolioId, isPresented: $addHoldingPortfolioId)
            } else {
                mainContent
            }
        }
        .frame(width: 420, height: 520)
        .preferredColorScheme(storageService.appearanceMode.colorScheme)
        .onAppear {
            selectedTab = Tab.resolve(stored: storageService.lastSelectedTab,
                                      showNews: storageService.showNewsTab)
        }
        .onChange(of: selectedTab) { _, newValue in
            storageService.lastSelectedTab = newValue.rawValue
        }
        // If News is turned off while its tab is selected, move off the now-hidden tab.
        .onChange(of: storageService.showNewsTab) { _, showNews in
            selectedTab = Tab.resolve(stored: selectedTab.rawValue, showNews: showNews)
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
                if storageService.showNewsTab {
                    tabButton("Home", tab: .home)
                }
                tabButton("Watchlist", tab: .watchlist)
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
            Text(title)
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
