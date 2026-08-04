import SwiftUI

@main
struct CorvoApp: App {
    var body: some Scene {
        MenuBarExtra("Corvo", systemImage: "bird") {
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
    }
}
