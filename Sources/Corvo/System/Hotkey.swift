import AppKit
import Carbon.HIToolbox
import SwiftUI

/// One global shortcut: a physical key and the modifiers held with it.
///
/// The modifiers are Carbon masks (`cmdKey`, `shiftKey`, …) rather than
/// `NSEvent.ModifierFlags`, because `RegisterEventHotKey` is what consumes them.
/// That puts the one translation on the path that *records* a shortcut, which
/// happens when a person clicks the recorder, instead of on the path that
/// registers one, which happens on every launch.
struct Hotkey: Equatable, Sendable {
    /// A `kVK_*` code. Physical: it names a position on the keyboard, not the
    /// letter printed on it, so a binding survives a layout change.
    let keyCode: UInt32
    /// `cmdKey | shiftKey | optionKey | controlKey`, in any combination.
    let modifiers: UInt32

    static let `default` = Hotkey(keyCode: UInt32(kVK_ANSI_V),
                                  modifiers: UInt32(cmdKey | shiftKey))

    /// The shortcut a key press describes, whatever it is. Whether Corvo will
    /// accept it is `HotkeyRule`'s question, not this initializer's — a rejected
    /// combination still has to be named on screen to say why it was rejected.
    init(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        self.init(keyCode: UInt32(event.keyCode), modifiers: carbon)
    }

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
}

// MARK: - Reading it back

extension Hotkey {
    /// The shortcut as macOS writes shortcuts: modifier glyphs in the order
    /// `⌃⌥⇧⌘`, then the key.
    ///
    /// The order is not cosmetic. Every menu in the system prints modifiers this
    /// way, so a recorder that answered "⇧⌘V" would be the one place in the app
    /// disagreeing with every other place the user has read a shortcut.
    var display: String {
        var out = ""
        if modifiers & UInt32(controlKey) != 0 { out += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { out += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { out += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { out += "⌘" }
        return out + Self.keyLabel(for: keyCode)
    }

    /// The label for a key, derived from the keyboard layout in use *now* rather
    /// than stored alongside the binding.
    ///
    /// Storing the character the recorder saw would be less code and would be
    /// wrong in a way that only shows up later: `keyCode` is physical, so the
    /// shortcut follows the key's position when the user switches to another
    /// layout, while a stored label would keep describing the layout that
    /// recorded it. A label that can disagree with what the shortcut does is
    /// worse than the extra `UCKeyTranslate` call.
    static func keyLabel(for keyCode: UInt32) -> String {
        if let named = namedKeys[Int(keyCode)] { return named }
        if let character = character(for: keyCode), !character.isEmpty {
            return character.uppercased()
        }
        // A key the layout has no character for and that is not in the table
        // above. Naming it by its code is not friendly, but it is true, and it
        // leaves the user something to recognise the row by.
        return "#\(keyCode)"
    }

    /// The character a key produces with no modifiers applied, on the current
    /// input source. `nil` for keys that produce none.
    static func character(for keyCode: UInt32) -> String? {
        // The ASCII-capable source is the fallback because
        // `TISCopyCurrentKeyboardLayoutInputSource` answers nil while a
        // non-roman input method is active — a Pinyin or Kana source has no
        // `uchr` layout data of its own — and a shortcut row that goes blank
        // when the user switches input method is a bug they cannot explain.
        let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue()
            ?? TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue()
        guard let source,
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }

        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else { return nil }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)

        var deadKeyState: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)
        let status = UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0,
                                   UInt32(LMGetKbdType()),
                                   OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                   &deadKeyState, characters.count, &length, &characters)
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: characters, count: length)
    }

    /// The same shortcut as SwiftUI states it, for the menu bar item.
    ///
    /// `nil` for a key with no single-`Character` equivalent — the F-keys and the
    /// arrows. Carbon registers those perfectly well; SwiftUI just has no way to
    /// print them next to a menu item, and printing a different key there would
    /// be worse than printing none.
    /// `SwiftUI.EventModifiers` spelled out: Carbon declares an `EventModifiers`
    /// of its own, and this file imports both.
    var menuShortcut: (key: KeyEquivalent, modifiers: SwiftUI.EventModifiers)? {
        guard let character = Self.character(for: keyCode)?.lowercased(),
              character.count == 1, let scalar = character.first
        else { return nil }

        var flags: SwiftUI.EventModifiers = []
        if modifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        if modifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        if modifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        if modifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
        return (KeyEquivalent(scalar), flags)
    }

    /// The keys `UCKeyTranslate` cannot label: they either produce no character
    /// or produce one nobody would recognise as the key they pressed.
    private static let namedKeys: [Int: String] = [
        kVK_Return: "↩", kVK_ANSI_KeypadEnter: "⌤", kVK_Tab: "⇥", kVK_Space: "␣",
        kVK_Delete: "⌫", kVK_ForwardDelete: "⌦", kVK_Escape: "⎋", kVK_Help: "?⃝",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5",
        kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10",
        kVK_F11: "F11", kVK_F12: "F12", kVK_F13: "F13", kVK_F14: "F14",
        kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18",
        kVK_F19: "F19", kVK_F20: "F20",
    ]
}

// MARK: - What Corvo will register

/// Whether a recorded shortcut can be a global shortcut at all.
///
/// Pure and separate from the recorder for the same reason `Blocklist` is
/// separate from the field that edits it: this is the rule, and it has to be
/// asked on the way in from the recorder *and* on the way in from
/// `UserDefaults`, which the recorder never touches.
enum HotkeyRule {
    enum Rejection: Equatable {
        /// No `⌘`, `⌥` or `⌃`.
        case needsModifier
    }

    /// One of these has to be held. `⇧` is deliberately not among them.
    static let requiredModifiers = UInt32(cmdKey | optionKey | controlKey)

    static func rejection(for hotkey: Hotkey) -> Rejection? {
        // `⇧V` is how a person types a capital V. Registered globally it would
        // swallow the key in every application, and the user who did it would
        // have no working keyboard left to undo it with — so a shortcut needs a
        // modifier that is not shift, and a bare key needs one even more.
        hotkey.modifiers & requiredModifiers == 0 ? .needsModifier : nil
    }

    static func isAcceptable(_ hotkey: Hotkey) -> Bool { rejection(for: hotkey) == nil }
}
