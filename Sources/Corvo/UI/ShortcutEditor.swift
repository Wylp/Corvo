/// What the shortcut row is showing.
///
/// Separate from the view, and holding hotkeys rather than the sentences about
/// them, for the reason `Blocklist` is separate from the field that edits it:
/// the rule about what a refused shortcut may change is the part that must not
/// break, and a rule inside a SwiftUI body is a rule nothing can ask a question
/// of. The wording stays in `PreferencesView`, which is the only place that
/// needs to be localized.
struct ShortcutState: Equatable {
    /// The shortcut on screen. Moved only by a change the system accepted.
    var hotkey: Hotkey?
    /// Why the last attempt did not take, if it did not.
    var refusal: ShortcutRefusal?

    init(hotkey: Hotkey?, refusal: ShortcutRefusal? = nil) {
        self.hotkey = hotkey
        self.refusal = refusal
    }
}

/// Both cases name the combination they are about, because by the time one is on
/// screen the recorder has gone back to showing the shortcut that is still
/// bound — so the sentence is the only place left that says what was refused.
enum ShortcutRefusal: Equatable {
    /// Typed without `⌘`, `⌥` or `⌃`. Never reaches the system.
    case needsModifier(Hotkey)
    /// The system refused it. `current` is what is still bound, `nil` when the
    /// user had already cleared the shortcut.
    case inUse(Hotkey, current: Hotkey?)
}

/// The one place that decides what a turn at the recorder does to the row.
enum ShortcutEditor {
    /// - Parameter register: asks the system to bind it, and answers `false`
    ///   when the system refused. Called at most once, and not at all for a
    ///   shortcut `HotkeyRule` has already ruled out — there is no point asking
    ///   the system about a combination Corvo would not keep.
    /// - Returns: the row's new state. Unchanged when nothing was accepted.
    static func apply(_ recording: HotkeyRecording,
                      to state: ShortcutState,
                      register: (Hotkey?) -> Bool) -> ShortcutState {
        switch recording {
        case .cancelled:
            // Not even the refusal is cleared: the user pressed Escape, which
            // says "leave it alone", and the sentence explaining why the last
            // thing they typed did not take is part of what they are leaving.
            return state

        case .cleared:
            _ = register(nil)
            return ShortcutState(hotkey: nil)

        case .recorded(let hotkey):
            guard HotkeyRule.isAcceptable(hotkey) else {
                return ShortcutState(hotkey: state.hotkey, refusal: .needsModifier(hotkey))
            }
            // Asking before anything moves is the whole failure policy: on
            // `false` the previous shortcut is still registered and still
            // stored, and the only thing that changes is the sentence.
            guard register(hotkey) else {
                return ShortcutState(hotkey: state.hotkey,
                                     refusal: .inUse(hotkey, current: state.hotkey))
            }
            return ShortcutState(hotkey: hotkey)
        }
    }
}
