import Carbon.HIToolbox
import Foundation
import Observation

// ponytail: a global dictionary because the Carbon callback is a C function
// pointer and captures no context. Carbon only calls it on the main thread,
// hence the `nonisolated(unsafe)`.
nonisolated(unsafe) private var hotkeyHandlers: [UInt32: () -> Void] = [:]
nonisolated(unsafe) private var nextHotkeyId: UInt32 = 1
nonisolated(unsafe) private var isHandlerInstalled = false

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

/// Registers the global shortcut, and can be told to register a different one.
///
/// Separate from `HotkeyBinder` so the binder — which decides what happens when
/// the system says no — can be tested against something that says no on demand,
/// rather than against whether some other application happens to hold a
/// shortcut on the machine running the tests.
protocol HotkeyRegistering: AnyObject {
    /// `nil` unregisters. Returns whether the shortcut is now registered, which
    /// is `false` only when the system refused it: another application, or macOS
    /// itself, already has it.
    func rebind(to hotkey: Hotkey?) -> Bool
}

/// A Carbon global shortcut whose combination can change. The registration lives
/// as long as the instance does.
final class GlobalHotkey: HotkeyRegistering {
    private var ref: EventHotKeyRef?
    private let id: UInt32
    private let handler: () -> Void

    init(handler: @escaping () -> Void) {
        self.id = nextHotkeyId
        self.handler = handler
        nextHotkeyId += 1
    }

    func rebind(to hotkey: Hotkey?) -> Bool {
        unregister()
        guard let hotkey else { return true }

        Self.installHandlerIfNeeded()
        let hotKeyID = EventHotKeyID(signature: OSType(0x43525630), id: id) // 'CRV0'
        let status = RegisterEventHotKey(hotkey.keyCode, hotkey.modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, ref != nil else {
            // Carbon can hand back a non-nil ref with a failing status. Clearing
            // it is what keeps `unregister()` from later passing a ref that was
            // never registered to `UnregisterEventHotKey`.
            ref = nil
            return false
        }
        hotkeyHandlers[id] = handler
        return true
    }

    private func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        hotkeyHandlers[id] = nil
    }

    /// Once per process, not once per registration.
    ///
    /// This used to sit in `init`, which was survivable while the shortcut was
    /// fixed and exactly one instance was ever built. With rebinding it would
    /// install another handler on every change the user makes — a leak they grow
    /// by using the feature, and one that calls the dispatcher N times for a
    /// single key press.
    private static func installHandlerIfNeeded() {
        guard !isHandlerInstalled else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), handleHotkeyEvent, 1,
                            &eventType, nil, nil)
        isHandlerInstalled = true
    }

    deinit { unregister() }
}

/// Owns the shortcut that is live, and the rule that a refused shortcut changes
/// nothing.
///
/// `@Observable` because the menu bar item prints the shortcut next to "Show
/// History": left as a stored constant it would advertise `⌘⇧V` after a rebind,
/// in the one place a user goes to find out what the shortcut is.
@MainActor
@Observable
final class HotkeyBinder {
    /// What Corvo intends to be registered. `nil` when the user cleared it.
    private(set) var current: Hotkey?

    @ObservationIgnored private let prefs: Preferences
    @ObservationIgnored private let registrar: HotkeyRegistering

    /// Whether a global shortcut is registered *right now*.
    ///
    /// One meaning, kept true on every path: false when the system refused the
    /// binding, false when the user cleared it, and false while the recorder has
    /// it suspended. It used to answer `true` for a cleared shortcut, because
    /// unregistering succeeds, and to stay `true` through a suspend — so the one
    /// value offered to the UI was wrong in the two states a screen would most
    /// want to show.
    private(set) var isRegistered: Bool

    init(prefs: Preferences, registrar: HotkeyRegistering) {
        self.prefs = prefs
        self.registrar = registrar
        let stored = prefs.hotkey
        self.current = stored
        self.isRegistered = registrar.rebind(to: stored) && stored != nil
    }

    /// Registers first, stores second.
    ///
    /// That order is the whole failure policy: a shortcut the system refuses is
    /// never written, the previous one is put back, and the user is left with a
    /// working shortcut and a sentence about the one they wanted. The opposite
    /// order leaves a stored shortcut that does nothing, in a settings window
    /// that says it is the shortcut.
    ///
    /// - Returns: `false` when the system refused, and nothing changed.
    func apply(_ hotkey: Hotkey?) -> Bool {
        guard registrar.rebind(to: hotkey) else {
            // The refused rebind already unregistered the old shortcut before
            // it failed, so at this point nothing is bound and putting the
            // previous one back can itself be refused — another app can have
            // taken it in the meantime. Dropping that answer is what let the
            // row go on saying "Still using ⌃⌥C" over a shortcut that was no
            // longer registered, which is the exact sentence this policy exists
            // to keep true.
            isRegistered = registrar.rebind(to: current) && current != nil
            return false
        }
        prefs.hotkey = hotkey
        current = hotkey
        isRegistered = hotkey != nil
        return true
    }

    /// Unregisters while the recorder is armed.
    ///
    /// A Carbon global shortcut is dispatched ahead of the application's own key
    /// handling, so without this the one combination the user cannot record is
    /// the one currently bound: pressing it would open the panel over the
    /// settings window instead of landing in the recorder.
    func suspend() {
        _ = registrar.rebind(to: nil)
        isRegistered = false
    }

    /// Puts the live shortcut back when recording ends, however it ended.
    ///
    /// The answer is kept rather than dropped: the shortcut was down for as long
    /// as the recorder was armed, which is long enough for another application
    /// to have claimed it. Reporting success then would leave `isRegistered`
    /// describing a shortcut nothing is listening for.
    func resume() { isRegistered = registrar.rebind(to: current) && current != nil }
}
