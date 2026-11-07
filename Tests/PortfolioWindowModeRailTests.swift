import XCTest
@testable import StockDeck

final class PortfolioWindowModeRailTests: XCTestCase {

    func testWorkspaceModeCasesAndOrder() {
        let modes = PortfolioWindowView.WorkspaceMode.allCases
        XCTAssertEqual(modes.count, 6)
        XCTAssertEqual(modes[0], .portfolio)
        XCTAssertEqual(modes[1], .watchlist)
        XCTAssertEqual(modes[2], .utilities)
        XCTAssertEqual(modes[3], .news)
        XCTAssertEqual(modes[4], .aiInsight)
        XCTAssertEqual(modes[5], .settings)

        XCTAssertEqual(PortfolioWindowView.WorkspaceMode.portfolio.rawValue, "Portfolio")
        XCTAssertEqual(PortfolioWindowView.WorkspaceMode.watchlist.rawValue, "Watchlist")
        XCTAssertEqual(PortfolioWindowView.WorkspaceMode.utilities.rawValue, "Utilities")
        XCTAssertEqual(PortfolioWindowView.WorkspaceMode.news.rawValue, "News")
        XCTAssertEqual(PortfolioWindowView.WorkspaceMode.aiInsight.rawValue, "AI Insight")
        XCTAssertEqual(PortfolioWindowView.WorkspaceMode.settings.rawValue, "Settings")
    }

    func testWorkspaceModeKeyboardShortcuts() {
        XCTAssertEqual(PortfolioWindowView.WorkspaceMode.portfolio.keyboardShortcutKey, "1")
        XCTAssertEqual(PortfolioWindowView.WorkspaceMode.watchlist.keyboardShortcutKey, "2")
        XCTAssertEqual(PortfolioWindowView.WorkspaceMode.utilities.keyboardShortcutKey, "3")
        XCTAssertEqual(PortfolioWindowView.WorkspaceMode.news.keyboardShortcutKey, "4")
        XCTAssertEqual(PortfolioWindowView.WorkspaceMode.aiInsight.keyboardShortcutKey, "5")
        XCTAssertEqual(PortfolioWindowView.WorkspaceMode.settings.keyboardShortcutKey, "6")

        XCTAssertEqual(PortfolioWindowView.WorkspaceMode.portfolio.shortcutLabel, "⌘1")
        XCTAssertEqual(PortfolioWindowView.WorkspaceMode.watchlist.shortcutLabel, "⌘2")
        XCTAssertEqual(PortfolioWindowView.WorkspaceMode.utilities.shortcutLabel, "⌘3")
        XCTAssertEqual(PortfolioWindowView.WorkspaceMode.news.shortcutLabel, "⌘4")
        XCTAssertEqual(PortfolioWindowView.WorkspaceMode.aiInsight.shortcutLabel, "⌘5")
        XCTAssertEqual(PortfolioWindowView.WorkspaceMode.settings.shortcutLabel, "⌘6")
    }

    func testInitialWorkspaceModeDefaults() {
        // When no env var is set and defaults are clean, default is .portfolio
        let mode = PortfolioWindowView.initialWorkspaceMode()
        if ProcessInfo.processInfo.environment["SD_OPEN_TAB"] == nil {
            XCTAssertEqual(mode, .portfolio)
        }
    }

    func testInitialSelectionCases() {
        // PortfoliosAll is standard default when not specified
        if ProcessInfo.processInfo.environment["SD_OPEN_TAB"] == nil {
            let selection = PortfolioWindowView.initialSelection()
            XCTAssertEqual(selection, .portfoliosAll)
        }
    }
}
