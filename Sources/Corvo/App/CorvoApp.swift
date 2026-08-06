import AppKit
import SwiftUI

@main
struct CorvoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // A template image, not the colour artwork: macOS paints the status item
        // itself — dark on a light menu bar, light on a dark one, inverted while
        // the menu is open. Colour art there is stuck in one shade and vanishes
        // against half the menu bars it will sit on.
        MenuBarExtra("Corvo", image: "MenuBarIcon") {
            Button("Show History") { delegate.panel?.show() }
                .keyboardShortcut("v", modifiers: [.command, .shift])
            Button("Settings…") { delegate.showSettings() }
                .keyboardShortcut(",")
            Divider()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }

    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var env: AppEnvironment?
    private(set) var panel: PanelController?
    private(set) var model: HistoryModel?
    private var hotkey: GlobalHotkey?
    private lazy var settings = SettingsWindow { [weak self] in
        guard let env = self?.env else { return nil }
        // The prune is handed over rather than left to the hourly timer: the
        // user who just confirmed a lower limit should see the history shrink
        // now, not at some unannounced point within the next hour.
        return AnyView(PreferencesView(prefs: env.prefs, onRetentionLowered: env.runPrune))
    }

    func showSettings() { settings.show() }

    /// True when this process was launched by `xcodebuild test` as the unit
    /// tests' host application, rather than by a person.
    private static var isTestHost: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || ProcessInfo.processInfo.environment["XCTestSessionIdentifier"] != nil
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The test bundle is hosted by this app, so every `xcodebuild test`
        // launches Corvo for real. Left to start normally it polls the live
        // pasteboard, writes the user's clippings into their real database and
        // claims ⌘⇧V — and the host process outlives the test run, so it keeps
        // doing all three for as long as it is left alone. Tests need the bundle
        // to exist, not the app to run.
        guard !Self.isTestHost else { return }

        do {
            let env = try AppEnvironment()
            env.start()
            self.env = env
            let model = HistoryModel(repo: env.repo, prefs: env.prefs)
            model.observeDatabase()
            self.model = model
            panel = PanelController(
                content: HistoryView(
                    model: model,
                    blobs: env.blobs,
                    onPaste: { [weak self] items in self?.paste(items) },
                    onCopy: { [weak self] items in self?.copy(items) }
                ),
                // The panel is hidden, not destroyed, so nothing else would ever
                // put the sheet away: it would be back on top the next time the
                // panel opens, over a window that can no longer dismiss it.
                clearTransientState: { [weak model] in model?.sheet = nil })

            // The answer typed into the notification comes back here. It goes
            // through the model rather than the repository so the panel redraws
            // with the new name if it happens to be open.
            env.namePrompt.onName = { [weak model] itemId, name in
                model?.setLabel(name, forItemId: itemId)
            }
            // The banner was clicked instead of answered. The clipping that
            // raised it is the newest one, so it is the first card, and it says
            // "Name this" until it has a name.
            env.namePrompt.onOpen = { [weak self] in self?.panel?.show() }
        } catch {
            NSAlert(error: error).runModal()
            NSApp.terminate(nil)
            return
        }

        hotkey = GlobalHotkey(keyCode: HotkeyCodes.v,
                              modifiers: HotkeyCodes.cmdShift) { [weak self] in
            MainActor.assumeIsolated { self?.panel?.toggle() }
        }
        if hotkey == nil {
            NSLog("Corvo: could not register ⌘⇧V — shortcut already taken?")
        }
    }

    /// Order matters: the panel has to be out of the way before the previous app
    /// is reactivated, or the ⌘V is delivered to the window that is going away.
    private func paste(_ items: [ClipItem]) {
        guard let env, !items.isEmpty else { return }
        panel?.hide()
        let outcome = Paster.paste(items, blobs: env.blobs, into: env.tracker.focusedApp)
        env.monitor.ignoreCurrentContents()
        // Stamped after the call and not before it. `lastUsedAt` is meant to
        // record a clipping the user actually got, and a paste refused for want
        // of Accessibility would otherwise mark the whole run as used — the
        // ordering was survivable with one clipping and stops being so with
        // five.
        if outcome != .nothingToWrite { items.forEach { model?.markUsed($0) } }
        switch outcome {
        case .pasted: return
        case .noPermission: warnMissingPermission()
        case .nothingToWrite: warnNothingToWrite()
        case .partial(let pasted, let total): warnPartial(pasted: pasted, of: total)
        }
    }

    /// ⌘C: the clipping goes to the clipboard and nowhere else — no app is
    /// reactivated and no ⌘V is posted, so the user places it themselves.
    ///
    /// `ignoreCurrentContents()` is not optional here, for the same reason it is
    /// not optional in `paste(_:)`: without it the next poll captures our own
    /// write. Text would merely dedupe, but an image goes back out as TIFF and
    /// re-encodes to a PNG whose bytes differ from the stored blob — a fresh
    /// hash, a new row and a new blob on every copy.
    private func copy(_ items: [ClipItem]) {
        guard let env, !items.isEmpty else { return }
        let written = Paster.writeToClipboard(items, blobs: env.blobs)
        panel?.hide()
        if written > 0 { items.forEach { model?.markUsed($0) } }
        env.monitor.ignoreCurrentContents()
        // ⌘C loses clippings the same way ⏎ does, and saying so on one path only
        // would leave the quieter half of the pair silent.
        if written == 0 { return warnNothingToWrite() }
        if written < items.count { warnPartial(pasted: written, of: items.count) }
    }

    /// The clipping had nothing left to put on the clipboard — a copied file
    /// that has since been moved or deleted. It used to report success and close
    /// the panel, which looked exactly like the app ignoring the keypress.
    private func warnNothingToWrite() {
        let alert = NSAlert()
        alert.messageText = String(localized: "Nothing left to paste")
        alert.informativeText = String(localized: """
            The file this clipping points at has been moved or deleted. Corvo \
            keeps a reference to files rather than a copy of them, so there is \
            nothing left to put on the clipboard.
            """)
        alert.addButton(withTitle: String(localized: "OK"))
        alert.runModal()
    }

    /// Said out loud because the alternative is losing a clipping in silence.
    /// The panel is already down by the time this is known, so an inline note
    /// has nowhere to appear — and this is the same class of thing the two
    /// warnings above exist for: what the user asked for is not what happened.
    private func warnPartial(pasted: Int, of total: Int) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Pasted \(pasted) of \(total)")
        alert.informativeText = String(localized: """
            The clipboard holds one thing at a time, so several clippings go \
            over joined into one. Images have no text to join, so they are left \
            out — paste them one at a time.
            """)
        alert.addButton(withTitle: String(localized: "OK"))
        alert.runModal()
    }

    /// `NSAlert` takes plain strings, not `LocalizedStringKey`, so these have to
    /// go through `String(localized:)` to reach the String Catalog at all.
    private func warnMissingPermission() {
        let alert = NSAlert()
        alert.messageText = String(localized: "Copied, but not pasted")
        alert.informativeText = String(localized: """
            Corvo needs Accessibility permission to paste straight into the app \
            you were using. The content is already on your clipboard — paste it \
            with ⌘V.

            If Corvo is already switched on in that list, macOS is holding a \
            permission for an older copy of the app: select Corvo, remove it \
            with the − button, then add it again.
            """)
        alert.addButton(withTitle: String(localized: "Open Settings"))
        alert.addButton(withTitle: String(localized: "Not now"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        // Ask before opening the panel, and not only for the system prompt: this
        // is also the call that enrols Corvo in the Accessibility list. Without
        // it the user arrives at a list the app is not on, and has to know to add
        // it by hand with "+".
        Paster.requestPermission()
        Paster.openAccessibilitySettings()
    }
}
