import SwiftUI

@main
struct CorvoApp: App {
    var body: some Scene {
        MenuBarExtra("Corvo", systemImage: "bird") {
            Button("Sair") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
    }
}
