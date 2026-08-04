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
    private var hotkey: GlobalHotkey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let env = try AppEnvironment()
            env.start()
            self.env = env
            panel = PanelController(content: Text("history goes here")
                .frame(maxWidth: .infinity, maxHeight: .infinity))
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
}
