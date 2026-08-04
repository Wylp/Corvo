import AppKit
import SwiftUI

@main
struct CorvoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra("Corvo", systemImage: "bird") {
            Button("Show History") { delegate.panel?.show() }
                .keyboardShortcut("v", modifiers: [.command, .shift])
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
            let model = HistoryModel(repo: env.repo)
            model.observeDatabase()
            self.model = model
            panel = PanelController(content: HistoryView(
                model: model,
                blobs: env.blobs,
                onPaste: { [weak self] item in self?.paste(item) },
                onCopy: { [weak self] item in self?.copy(item) }
            ))
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
    private func paste(_ item: ClipItem) {
        guard let env else { return }
        panel?.hide()
        model?.markUsed(item)
        let pasted = Paster.paste(item, blobs: env.blobs, into: env.tracker.focusedApp)
        env.monitor.ignoreCurrentContents()
        guard !pasted else { return }
        warnMissingPermission()
    }

    /// ⌘C: the clipping goes to the clipboard and nowhere else — no app is
    /// reactivated and no ⌘V is posted, so the user places it themselves.
    ///
    /// `ignoreCurrentContents()` is not optional here, for the same reason it is
    /// not optional in `paste(_:)`: without it the next poll captures our own
    /// write. Text would merely dedupe, but an image goes back out as TIFF and
    /// re-encodes to a PNG whose bytes differ from the stored blob — a fresh
    /// hash, a new row and a new blob on every copy.
    private func copy(_ item: ClipItem) {
        guard let env else { return }
        Paster.writeToClipboard(item, blobs: env.blobs)
        panel?.hide()
        model?.markUsed(item)
        env.monitor.ignoreCurrentContents()
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
            """)
        alert.addButton(withTitle: String(localized: "Open Settings"))
        alert.addButton(withTitle: String(localized: "Not now"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Paster.openAccessibilitySettings()
    }
}
