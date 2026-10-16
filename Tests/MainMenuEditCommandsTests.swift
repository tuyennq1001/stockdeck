import XCTest
import AppKit
@testable import StockDeck

final class MainMenuEditCommandsTests: XCTestCase {

    @MainActor
    func testMainMenuHasEditMenuWithStandardAndCtrlShortcuts() {
        let mainMenu = AppDelegate.buildMainMenu()
        
        let editItem = mainMenu.items.first { $0.submenu?.title == "Edit" }
        XCTAssertNotNil(editItem, "Main menu should contain an Edit menu")
        guard let editMenu = editItem?.submenu else { return }

        // Test standard Cmd+A Select All
        let selectAllCmd = editMenu.items.first {
            $0.action == #selector(NSText.selectAll(_:)) &&
            $0.keyEquivalent == "a" &&
            $0.keyEquivalentModifierMask == .command
        }
        XCTAssertNotNil(selectAllCmd, "Edit menu must have Cmd+A for Select All")

        // Test fallback Ctrl+A Select All (for PC keyboards or muscle memory)
        let selectAllCtrl = editMenu.items.first {
            $0.action == #selector(NSText.selectAll(_:)) &&
            $0.keyEquivalent == "a" &&
            $0.keyEquivalentModifierMask == [.control]
        }
        XCTAssertNotNil(selectAllCtrl, "Edit menu must have Ctrl+A fallback for Select All")

        // Test Copy, Cut, Paste, Undo
        let copyCmd = editMenu.items.first {
            $0.action == #selector(NSText.copy(_:)) &&
            $0.keyEquivalent == "c" &&
            $0.keyEquivalentModifierMask == .command
        }
        XCTAssertNotNil(copyCmd, "Edit menu must have Cmd+C for Copy")

        let pasteCmd = editMenu.items.first {
            $0.action == #selector(NSText.paste(_:)) &&
            $0.keyEquivalent == "v" &&
            $0.keyEquivalentModifierMask == .command
        }
        XCTAssertNotNil(pasteCmd, "Edit menu must have Cmd+V for Paste")

        let cutCmd = editMenu.items.first {
            $0.action == #selector(NSText.cut(_:)) &&
            $0.keyEquivalent == "x" &&
            $0.keyEquivalentModifierMask == .command
        }
        XCTAssertNotNil(cutCmd, "Edit menu must have Cmd+X for Cut")
    }
}
