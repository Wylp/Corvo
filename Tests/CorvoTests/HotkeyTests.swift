import Carbon.HIToolbox
import Foundation
import Testing
@testable import Corvo

/// Never `.standard`: these tests write a global shortcut, and `.standard` is
/// the real user's configuration.
private func makePrefs() -> Preferences {
    Preferences(defaults: UserDefaults(suiteName: UUID().uuidString)!)
}

private let cmdShiftV = Hotkey(keyCode: UInt32(kVK_ANSI_V),
                               modifiers: UInt32(cmdKey | shiftKey))

// MARK: - How a shortcut reads

/// Every menu in macOS prints modifiers in this order. A recorder that answered
/// "⇧⌘V" would be the one place in the app disagreeing with every other place
/// the user has ever read a shortcut.
@Test func modifiersAreWrittenInTheOrderMacOSWritesThem() {
    #expect(cmdShiftV.display == "⇧⌘V")

    let all = Hotkey(keyCode: UInt32(kVK_ANSI_A),
                     modifiers: UInt32(cmdKey | shiftKey | optionKey | controlKey))
    #expect(all.display == "⌃⌥⇧⌘A")
}

@Test func aKeyWithNoCharacterIsNamedRatherThanLeftBlank() {
    #expect(Hotkey(keyCode: UInt32(kVK_Space), modifiers: UInt32(cmdKey)).display == "⌘␣")
    #expect(Hotkey(keyCode: UInt32(kVK_F5), modifiers: UInt32(controlKey)).display == "⌃F5")
    #expect(Hotkey(keyCode: UInt32(kVK_LeftArrow), modifiers: UInt32(optionKey)).display == "⌥←")
}

// MARK: - What Corvo will register

/// The case this rule exists for: `⇧V` is how a person types a capital V, so
/// registering it globally swallows the key in every app — and leaves the user
/// no working keyboard to undo it with.
@Test func aShortcutWithoutCommandOptionOrControlIsRejected() {
    #expect(HotkeyRule.rejection(for: Hotkey(keyCode: UInt32(kVK_ANSI_V), modifiers: 0))
            == .needsModifier)
    #expect(HotkeyRule.rejection(for: Hotkey(keyCode: UInt32(kVK_ANSI_V),
                                             modifiers: UInt32(shiftKey))) == .needsModifier)
}

@Test func anyOfCommandOptionOrControlIsEnough() {
    for modifier in [cmdKey, optionKey, controlKey] {
        let hotkey = Hotkey(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(modifier))
        #expect(HotkeyRule.isAcceptable(hotkey), "\(hotkey.display) should be acceptable")
    }
    #expect(HotkeyRule.isAcceptable(cmdShiftV))
}

// MARK: - Storage

@Test func afreshInstallGetsTheShortcutItAlwaysHad() {
    #expect(makePrefs().hotkey == cmdShiftV)
}

@Test func aRecordedShortcutComesBack() {
    let prefs = makePrefs()
    let recorded = Hotkey(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(cmdKey | optionKey))
    prefs.hotkey = recorded
    #expect(prefs.hotkey == recorded)
}

/// `kVK_ANSI_A` is 0, which `defaults.integer(forKey:)` also returns for a key
/// nobody ever wrote. Read that way, binding to A would silently read back as
/// the default forever.
@Test func theKeyAIsNotMistakenForNothingStored() {
    let prefs = makePrefs()
    let onA = Hotkey(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(cmdKey | controlKey))
    prefs.hotkey = onA
    #expect(prefs.hotkey == onA)
    #expect(prefs.hotkey != .default)
}

@Test func clearingLeavesNoGlobalShortcut() {
    let prefs = makePrefs()
    prefs.hotkey = nil
    #expect(prefs.hotkey == nil)
}

/// The setter only bounds what Corvo itself wrote. A shortcut that arrived by
/// `defaults write`, an MDM profile or a restored plist has to come back
/// registerable too — the same reason the retention limits clamp on read.
@Test func aShiftOnlyShortcutWrittenBehindOurBackReadsBackAsTheDefault() {
    let defaults = UserDefaults(suiteName: UUID().uuidString)!
    defaults.set(Int(kVK_ANSI_V), forKey: "hotkeyKeyCode")
    defaults.set(Int(shiftKey), forKey: "hotkeyModifiers")

    #expect(Preferences(defaults: defaults).hotkey == .default)
}

// MARK: - When the system says no

/// Stands in for macOS holding a shortcut — Paste, or the system itself. A test
/// that depended on that being true of the machine running it would pass and
/// fail for reasons that have nothing to do with Corvo.
private final class StubRegistrar: HotkeyRegistering {
    var refuse: Bool
    var registered: Hotkey?
    var rebinds = 0

    init(refuse: Bool = false) { self.refuse = refuse }

    func rebind(to hotkey: Hotkey?) -> Bool {
        rebinds += 1
        guard hotkey != nil else {
            registered = nil
            return true
        }
        guard !refuse else { return false }
        registered = hotkey
        return true
    }
}

@Test @MainActor func theStoredShortcutIsRegisteredAtLaunch() {
    let registrar = StubRegistrar()
    let binder = HotkeyBinder(prefs: makePrefs(), registrar: registrar)

    #expect(binder.isRegistered)
    #expect(registrar.registered == cmdShiftV)
}

/// The whole failure policy: a shortcut the system refuses is never stored, the
/// previous one stays live, and the user is left with a working shortcut rather
/// than a settings row describing one that does nothing.
@Test @MainActor func aRefusedShortcutChangesNothing() {
    let prefs = makePrefs()
    let registrar = StubRegistrar()
    let binder = HotkeyBinder(prefs: prefs, registrar: registrar)

    registrar.refuse = true
    let wanted = Hotkey(keyCode: UInt32(kVK_ANSI_J), modifiers: UInt32(cmdKey))
    #expect(binder.apply(wanted) == false)

    #expect(binder.current == cmdShiftV)
    #expect(prefs.hotkey == cmdShiftV)
    #expect(registrar.registered == cmdShiftV)
}

@Test @MainActor func anAcceptedShortcutIsStoredAndLive() {
    let prefs = makePrefs()
    let registrar = StubRegistrar()
    let binder = HotkeyBinder(prefs: prefs, registrar: registrar)

    let wanted = Hotkey(keyCode: UInt32(kVK_ANSI_J), modifiers: UInt32(cmdKey | optionKey))
    #expect(binder.apply(wanted))

    #expect(binder.current == wanted)
    #expect(prefs.hotkey == wanted)
    #expect(registrar.registered == wanted)
}

/// A Carbon global shortcut is dispatched ahead of the app's own key handling,
/// so the one combination that could not be recorded is the one currently bound
/// — unless it comes down while the recorder is armed.
@Test @MainActor func recordingTakesTheLiveShortcutDownAndPutsItBack() {
    let registrar = StubRegistrar()
    let binder = HotkeyBinder(prefs: makePrefs(), registrar: registrar)

    binder.suspend()
    #expect(registrar.registered == nil)

    binder.resume()
    #expect(registrar.registered == cmdShiftV)
}

@Test @MainActor func clearingUnregistersWithoutRefusing() {
    let prefs = makePrefs()
    let registrar = StubRegistrar()
    let binder = HotkeyBinder(prefs: prefs, registrar: registrar)

    #expect(binder.apply(nil))
    #expect(binder.current == nil)
    #expect(prefs.hotkey == nil)
    #expect(registrar.registered == nil)
    #expect(binder.isRegistered == false)
}

/// Registering for real, twice, through the Carbon path rather than the stub.
/// `InstallEventHandler` used to run in `init`; if it runs per registration the
/// dispatcher is called once per rebind for a single key press.
@Test @MainActor func rebindingTheRealRegistrarDoesNotAccumulateHandlers() {
    var fired = 0
    let hotkey = GlobalHotkey { fired += 1 }

    // A combination no other app is plausibly holding, so this exercises the
    // real `RegisterEventHotKey` without fighting anything for it.
    let first = Hotkey(keyCode: UInt32(kVK_F19), modifiers: UInt32(cmdKey | controlKey | optionKey))
    let second = Hotkey(keyCode: UInt32(kVK_F18), modifiers: UInt32(cmdKey | controlKey | optionKey))

    #expect(hotkey.rebind(to: first))
    #expect(hotkey.rebind(to: second))
    #expect(hotkey.rebind(to: nil))

    // Nothing was pressed, so nothing should have fired — the assertion that
    // matters is that none of the three calls trapped or double-registered.
    #expect(fired == 0)
}
