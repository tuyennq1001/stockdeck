import Foundation
import AppKit
import Carbon

private func carbonHotKeyEventHandler(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event = event else { return noErr }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    if status == noErr {
        GlobalHotKeyManager.shared.dispatchAction(for: hotKeyID.id)
    } else {
        GlobalHotKeyManager.shared.dispatchAction(for: 1)
    }
    return noErr
}

public final class GlobalHotKeyManager {
    public static let shared = GlobalHotKeyManager()

    public static let signature: OSType = 0x5354444B // 'STDK'

    private struct RegisteredHotKey {
        let ref: EventHotKeyRef
        let action: () -> Void
    }

    private var registeredHotKeys: [UInt32: RegisteredHotKey] = [:]
    private var eventHandler: EventHandlerRef?

    private init() {
        installHandler()
    }

    deinit {
        unregisterAll()
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

    public func register(id: UInt32, shortcut: MenuBarShortcut, action: @escaping () -> Void) {
        unregister(id: id)

        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.modifiers,
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &ref
        )

        if status != noErr || ref == nil {
            NSLog("[GlobalHotKeyManager] Failed to register Carbon hot key (id: %u, keyCode: %u, mods: %u): %d",
                  id, shortcut.keyCode, shortcut.modifiers, status)
        } else if let ref = ref {
            registeredHotKeys[id] = RegisteredHotKey(ref: ref, action: action)
            NSLog("[GlobalHotKeyManager] Successfully registered shortcut for id %u: %@", id, shortcut.displayString)
        }
    }

    public func unregister(id: UInt32) {
        if let existing = registeredHotKeys.removeValue(forKey: id) {
            UnregisterEventHotKey(existing.ref)
        }
    }

    public func unregisterAll() {
        for (_, entry) in registeredHotKeys {
            UnregisterEventHotKey(entry.ref)
        }
        registeredHotKeys.removeAll()
    }

    // MARK: - Backwards Compatibility
    public func register(shortcut: MenuBarShortcut, action: @escaping () -> Void) {
        register(id: 1, shortcut: shortcut, action: action)
    }

    public func unregister() {
        unregister(id: 1)
    }

    fileprivate func dispatchAction(for id: UInt32) {
        DispatchQueue.main.async { [weak self] in
            self?.registeredHotKeys[id]?.action()
        }
    }
}
