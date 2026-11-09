import XCTest
import SwiftUI
@testable import StockDeck

/// Issue #11: the 1.9.0 redesign hard-forced the light appearance and dropped the
/// dark-mode toggle. These pin down the mapping that restores user control:
/// System follows the OS (nil scheme), Light/Dark force their scheme, and any
/// unknown persisted value falls back to System.
final class AppearanceModeTests: XCTestCase {

    func testSystemFollowsOS() {
        XCTAssertNil(AppearanceMode.system.colorScheme)
    }

    func testLightForcesLight() {
        XCTAssertEqual(AppearanceMode.light.colorScheme, .light)
    }

    func testDarkForcesDark() {
        XCTAssertEqual(AppearanceMode.dark.colorScheme, .dark)
    }

    func testUnknownRawValueFallsBackToSystem() {
        XCTAssertEqual(AppearanceMode(rawValue: "chartreuse") ?? .system, .system)
        XCTAssertNil((AppearanceMode(rawValue: "chartreuse") ?? .system).colorScheme)
    }

    func testDefaultIsDark() {
        // Obsidian Slate Financial Terminal is the default theme
        XCTAssertEqual(AppearanceMode.default, .dark)
    }

    func testLabels() {
        XCTAssertEqual(AppearanceMode.dark.label, "Obsidian Slate (Terminal)")
        XCTAssertEqual(AppearanceMode.light.label, "Private Banking (Classic)")
        XCTAssertEqual(AppearanceMode.system.label, "System")
    }
}
