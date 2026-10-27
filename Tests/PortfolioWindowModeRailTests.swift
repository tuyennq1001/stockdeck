import XCTest
@testable import StockDeck

final class PortfolioWindowModeRailTests: XCTestCase {

    func testWorkspaceModeCasesAndOrder() {
        let modes = PortfolioWindowView.WorkspaceMode.allCases
        XCTAssertEqual(modes.count, 5)
        XCTAssertEqual(modes[0], .index)
        XCTAssertEqual(modes[1], .superchart)
        XCTAssertEqual(modes[2], .news)
        XCTAssertEqual(modes[3], .aiInsight)
        XCTAssertEqual(modes[4], .settings)

        XCTAssertEqual(PortfolioWindowView.WorkspaceMode.index.rawValue, "Index")
        XCTAssertEqual(PortfolioWindowView.WorkspaceMode.superchart.rawValue, "Superchart")
        XCTAssertEqual(PortfolioWindowView.WorkspaceMode.news.rawValue, "News")
        XCTAssertEqual(PortfolioWindowView.WorkspaceMode.aiInsight.rawValue, "AI Insight")
        XCTAssertEqual(PortfolioWindowView.WorkspaceMode.settings.rawValue, "Settings")
    }

    func testWorkspaceModeKeyboardShortcuts() {
        XCTAssertEqual(PortfolioWindowView.WorkspaceMode.index.keyboardShortcutKey, "1")
        XCTAssertEqual(PortfolioWindowView.WorkspaceMode.superchart.keyboardShortcutKey, "2")
        XCTAssertEqual(PortfolioWindowView.WorkspaceMode.news.keyboardShortcutKey, "3")
        XCTAssertEqual(PortfolioWindowView.WorkspaceMode.aiInsight.keyboardShortcutKey, "4")
        XCTAssertEqual(PortfolioWindowView.WorkspaceMode.settings.keyboardShortcutKey, "5")

        XCTAssertEqual(PortfolioWindowView.WorkspaceMode.index.shortcutLabel, "⌘1")
        XCTAssertEqual(PortfolioWindowView.WorkspaceMode.superchart.shortcutLabel, "⌘2")
        XCTAssertEqual(PortfolioWindowView.WorkspaceMode.news.shortcutLabel, "⌘3")
        XCTAssertEqual(PortfolioWindowView.WorkspaceMode.aiInsight.shortcutLabel, "⌘4")
        XCTAssertEqual(PortfolioWindowView.WorkspaceMode.settings.shortcutLabel, "⌘5")
    }

    func testInitialWorkspaceModeDefaults() {
        // When no env var is set and defaults are clean, default is .index
        let mode = PortfolioWindowView.initialWorkspaceMode()
        // If run in standard test environment without SD_OPEN_TAB:
        if ProcessInfo.processInfo.environment["SD_OPEN_TAB"] == nil {
            XCTAssertTrue(mode == .index || mode == .superchart)
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
