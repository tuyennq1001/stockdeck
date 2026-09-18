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

        let optionD = MenuBarShortcut.presetOptionD
        XCTAssertEqual(optionD.displayString, "⌥ D")

        let cmdShiftD = MenuBarShortcut.presetCmdShiftD
        XCTAssertEqual(cmdShiftD.displayString, "⇧ ⌘ D")

        let ctrlOptionD = MenuBarShortcut.presetControlOptionD
        XCTAssertEqual(ctrlOptionD.displayString, "⌃ ⌥ D")

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
        XCTAssertNil(storage.desktopAppShortcut)

        let shortcut = MenuBarShortcut(keyCode: 1, modifiers: 2048)
        let desktopShortcut = MenuBarShortcut(keyCode: 2, modifiers: 2048)
        storage.menuBarShortcut = shortcut
        storage.desktopAppShortcut = desktopShortcut
        storage.saveNow()

        let storageReloaded = StorageService(fileURL: tempURL)
        XCTAssertEqual(storageReloaded.menuBarShortcut, shortcut)
        XCTAssertEqual(storageReloaded.desktopAppShortcut, desktopShortcut)

        storageReloaded.resetToDefaults()
        XCTAssertNil(storageReloaded.menuBarShortcut)
        XCTAssertNil(storageReloaded.desktopAppShortcut)
    }

    func testGlobalHotKeyManagerMultipleIDs() {
        let manager = GlobalHotKeyManager.shared
        let shortcut1 = MenuBarShortcut.presetOptionS
        let shortcut2 = MenuBarShortcut.presetOptionD

        var triggered1 = false
        var triggered2 = false

        manager.register(id: 1, shortcut: shortcut1) {
            triggered1 = true
        }
        manager.register(id: 2, shortcut: shortcut2) {
            triggered2 = true
        }

        manager.unregister(id: 1)
        manager.unregister(id: 2)
        manager.unregisterAll()

        XCTAssertFalse(triggered1)
        XCTAssertFalse(triggered2)
    }
}
