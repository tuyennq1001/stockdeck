import Foundation
import AppKit
import Carbon

private func carbonHotKeyEventHandler(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    GlobalHotKeyManager.shared.dispatchAction()
    return noErr
}

public final class GlobalHotKeyManager {
    public static let shared = GlobalHotKeyManager()

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var action: (() -> Void)?

    private init() {
        installHandler()
    }

    deinit {
        unregister()
        if let eventHandler = eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
    }

    private func installHandler() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let status = InstallEventHandler(
            GetEventDispatcherTarget(),
            carbonHotKeyEventHandler,
            1,
            &eventType,
            nil,
            &eventHandler
        )

        if status != noErr {
            NSLog("[GlobalHotKeyManager] Failed to install Carbon event handler: %d", status)
        } else {
            NSLog("[GlobalHotKeyManager] Carbon event handler installed on GetEventDispatcherTarget()")
        }
    }

    public func register(shortcut: MenuBarShortcut, action: @escaping () -> Void) {
        unregister()
        self.action = action

        // Unique signature 'STDK' (0x5354444B), id 1
        let hotKeyID = EventHotKeyID(signature: OSType(0x5354444B), id: 1)
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.modifiers,
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &hotKeyRef
        )

        if status != noErr {
            NSLog("[GlobalHotKeyManager] Failed to register Carbon hot key (keyCode: %u, mods: %u): %d",
                  shortcut.keyCode, shortcut.modifiers, status)
        } else {
            NSLog("[GlobalHotKeyManager] Successfully registered shortcut: %@", shortcut.displayString)
        }
    }

    public func unregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            self.hotKeyRef = nil
        }
        self.action = nil
    }

    fileprivate func dispatchAction() {
        DispatchQueue.main.async { [weak self] in
            self?.action?()
        }
    }
}
