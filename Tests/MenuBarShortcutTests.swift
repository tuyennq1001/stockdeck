import XCTest
@testable import StockDeck

final class MenuBarShortcutTests: XCTestCase {

    func testShortcutDisplayString() {
        let optionSpace = MenuBarShortcut.presetOptionSpace
        XCTAssertEqual(optionSpace.displayString, "⌥ Space")

        let optionS = MenuBarShortcut.presetOptionS
        XCTAssertEqual(optionS.displayString, "⌥ S")

        let cmdShiftS = MenuBarShortcut.presetCmdShiftS
        XCTAssertEqual(cmdShiftS.displayString, "⇧ ⌘ S")

        let ctrlOptionS = MenuBarShortcut.presetControlOptionS
        XCTAssertEqual(ctrlOptionS.displayString, "⌃ ⌥ S")

        let f1Shortcut = MenuBarShortcut(keyCode: 122, modifiers: 0)
        XCTAssertEqual(f1Shortcut.displayString, "F1")

        let arrowUp = MenuBarShortcut(keyCode: 126, modifiers: 2048) // Option + Up
        XCTAssertEqual(arrowUp.displayString, "⌥ ↑")
    }

    func testShortcutCodableRoundtrip() throws {
        let original = MenuBarShortcut(keyCode: 49, modifiers: 2048)
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MenuBarShortcut.self, from: encoded)
        XCTAssertEqual(original, decoded)
    }

    @MainActor
    func testStorageServicePersistence() throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_shortcut_\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let storage = StorageService(fileURL: tempURL)
        XCTAssertNil(storage.menuBarShortcut)

        let shortcut = MenuBarShortcut(keyCode: 1, modifiers: 2048)
        storage.menuBarShortcut = shortcut
        storage.saveNow()

        let storageReloaded = StorageService(fileURL: tempURL)
        XCTAssertEqual(storageReloaded.menuBarShortcut, shortcut)

        storageReloaded.resetToDefaults()
        XCTAssertNil(storageReloaded.menuBarShortcut)
    }
}
