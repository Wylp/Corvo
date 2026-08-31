import AppKit
import Carbon.HIToolbox
import SwiftUI

/// What one turn at the recorder produced.
enum HotkeyRecording: Equatable {
    case recorded(Hotkey)
    /// `⌫`: the user wants no global shortcut.
    case cleared
    /// `Esc`, or a second click on the button. Nothing changes.
    case cancelled
}

/// A button that shows the current shortcut and, while armed, captures the next
/// key press.
///
/// SwiftUI has no way to receive a raw key press, so the capture is an
/// `NSView` — but only while armed. Outside that, this is an ordinary
/// `Button`, which is what keeps it looking like every other control in a
/// settings window built out of system controls.
struct HotkeyRecorder: View {
    let hotkey: Hotkey?
    /// Called when arming and disarming. The global shortcut has to come down
    /// while this is armed, or the combination in use cannot be recorded.
    let onArmedChange: (Bool) -> Void
    let onRecording: (HotkeyRecording) -> Void

    @State private var isArmed = false
    /// The modifiers being held right now, so the button reads `⌃⌥` before the
    /// letter lands and the user can see what they are building.
    @State private var held: NSEvent.ModifierFlags = []

    var body: some View {
        Button(label) { setArmed(!isArmed) }
            .buttonStyle(.bordered)
            .frame(minWidth: 96)
            .monospacedDigit()
            .help(isArmed ? Text("Type a shortcut, or press Escape to cancel")
                          : Text("Click, then type the shortcut you want"))
            .accessibilityLabel(Text("Shortcut for opening the panel"))
            .accessibilityValue(Text(hotkey?.display ?? "None"))
            .overlay {
                if isArmed {
                    // Zero-sized: it is a first responder, not a control. All the
                    // visible state is on the button behind it.
                    KeyCatcher(onFlags: { held = $0 }, onResult: finish)
                        .frame(width: 0, height: 0)
                }
            }
            // Arming survives the window closing otherwise: the view keeps its
            // `@State`, and the shortcut would stay unregistered with nothing on
            // screen to put it back.
            .onDisappear { if isArmed { setArmed(false) } }
    }

    private var label: String {
        guard isArmed else { return hotkey?.display ?? String(localized: "None") }
        let partial = Hotkey.glyphs(for: held)
        return partial.isEmpty ? String(localized: "Type a shortcut…") : partial
    }

    private func setArmed(_ armed: Bool) {
        isArmed = armed
        held = []
        onArmedChange(armed)
    }

    private func finish(_ recording: HotkeyRecording) {
        setArmed(false)
        onRecording(recording)
    }
}

// MARK: - The key press

private struct KeyCatcher: NSViewRepresentable {
    let onFlags: (NSEvent.ModifierFlags) -> Void
    let onResult: (HotkeyRecording) -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.onFlags = onFlags
        view.onResult = onResult
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.onFlags = onFlags
        view.onResult = onResult
        // Deferred: on the pass that inserts the view it is not in a window yet,
        // and a first responder request from here would be made of nothing.
        DispatchQueue.main.async { [weak view] in
            guard let view, view.window?.firstResponder !== view else { return }
            view.window?.makeFirstResponder(view)
        }
    }
}

final class CatcherView: NSView {
    var onFlags: ((NSEvent.ModifierFlags) -> Void)?
    var onResult: ((HotkeyRecording) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func flagsChanged(with event: NSEvent) {
        onFlags?(event.modifierFlags.intersection(.deviceIndependentFlagsMask))
    }

    /// Every `⌘` combination arrives here and never reaches `keyDown` — that is
    /// what a key equivalent is. Returning `true` is what stops the window from
    /// looking for a menu item or a button to give it to, and it is the only
    /// reason a recorder can record `⌘`-anything at all.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        handle(event)
        return true
    }

    override func keyDown(with event: NSEvent) { handle(event) }

    private func handle(_ event: NSEvent) {
        switch Int(event.keyCode) {
        case kVK_Escape:
            onResult?(.cancelled)
        case kVK_Delete, kVK_ForwardDelete:
            // Neither could be recorded anyway — both fail the modifier rule —
            // so spending them on "no shortcut" costs nothing and gives the
            // gesture the shape it has everywhere else in macOS.
            onResult?(.cleared)
        default:
            onResult?(.recorded(Hotkey(event: event)))
        }
    }
}

// MARK: - Partial display

extension Hotkey {
    /// The glyphs for modifiers held with no key yet, in the same `⌃⌥⇧⌘` order
    /// `display` uses. Lives here so there is one answer to "how are modifiers
    /// written", not two that can drift apart.
    static func glyphs(for flags: NSEvent.ModifierFlags) -> String {
        var out = ""
        if flags.contains(.control) { out += "⌃" }
        if flags.contains(.option) { out += "⌥" }
        if flags.contains(.shift) { out += "⇧" }
        if flags.contains(.command) { out += "⌘" }
        return out
    }
}
