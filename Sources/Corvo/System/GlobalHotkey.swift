import Carbon.HIToolbox
import Foundation

enum HotkeyCodes {
    static let v = UInt32(kVK_ANSI_V)
    static let cmdShift = UInt32(cmdKey | shiftKey)
}

// ponytail: a global dictionary because the Carbon callback is a C function
// pointer and captures no context. Carbon only calls it on the main thread,
// hence the `nonisolated(unsafe)`. If we ever need a configurable shortcut,
// replace this whole file with the KeyboardShortcuts package, which already
// ships the recorder.
nonisolated(unsafe) private var hotkeyHandlers: [UInt32: () -> Void] = [:]
nonisolated(unsafe) private var nextHotkeyId: UInt32 = 1

private func handleHotkeyEvent(_ next: EventHandlerCallRef?, _ event: EventRef?,
                               _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    var id = EventHotKeyID()
    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                   EventParamType(typeEventHotKeyID), nil,
                                   MemoryLayout<EventHotKeyID>.size, nil, &id)
    guard status == noErr else { return status }
    hotkeyHandlers[id.id]?()
    return noErr
}

/// Registers a global shortcut. The shortcut lives as long as the instance does.
final class GlobalHotkey {
    private var ref: EventHotKeyRef?
    private let id: UInt32

    init?(keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) {
        id = nextHotkeyId
        nextHotkeyId += 1

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), handleHotkeyEvent, 1,
                            &eventType, nil, nil)

        let hotKeyID = EventHotKeyID(signature: OSType(0x43525630), id: id) // 'CRV0'
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr else { return nil }
        hotkeyHandlers[id] = handler
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        hotkeyHandlers[id] = nil
    }
}
