import XCTest
@testable import StockDeck

/// Issue #11: the reporter wants the Home/News tab gone entirely. `Tab.visible`
/// is the single source of truth for which tabs render, so hiding News is just a
/// preference the tab bar honors — no dead code paths.
final class TabVisibilityTests: XCTestCase {

    func testHomeAlwaysVisible() {
        let tabs = Tab.visible
        XCTAssertEqual(tabs.first, .home)
        XCTAssertTrue(tabs.contains(.home))
        XCTAssertTrue(tabs.contains(.watchlist))
        XCTAssertTrue(tabs.contains(.portfolios))
        XCTAssertTrue(tabs.contains(.utilities))
        XCTAssertTrue(tabs.contains(.settings))
        XCTAssertEqual(tabs, [.home, .watchlist, .portfolios, .utilities, .settings])
    }

    func testResolvingStoredTab() {
        XCTAssertEqual(Tab.resolve(stored: "Home"), .home)
        XCTAssertEqual(Tab.resolve(stored: "Watchlist"), .watchlist)
        XCTAssertEqual(Tab.resolve(stored: "Watchlists"), .watchlist)
        XCTAssertEqual(Tab.resolve(stored: "Portfolios"), .portfolios)
        XCTAssertEqual(Tab.resolve(stored: "garbage"), .home)
    }
}
