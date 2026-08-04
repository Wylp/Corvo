import AppKit

/// Figures out which app the copied content came from.
///
/// Two sources, in this order: the `org.nspasteboard.source` convention
/// (handled in PasteboardMonitor, authoritative when present) and, failing
/// that, the app focused at capture time.
///
/// The poll runs every 0.3s, so between the ⌘C and the read the user may have
/// switched apps. We keep the previous activation with a timestamp: if the
/// switch happened inside the window, the credit goes to the earlier app.
@MainActor
final class SourceTracker {
    private struct Activation {
        let source: ItemSource
        let when: Date
    }

    private let switchWindow: TimeInterval
    private var current: Activation?
    private var previous: Activation?

    /// The app that was focused before Corvo's panel appeared. It is the one
    /// Paster gives focus back to when pasting.
    private(set) var focusedApp: NSRunningApplication?

    init(switchWindow: TimeInterval = 0.3) {
        self.switchWindow = switchWindow
    }

    func recordActivation(_ source: ItemSource, at when: Date) {
        previous = current
        current = Activation(source: source, when: when)
    }

    func captureSource(at when: Date) -> ItemSource? {
        guard let current else { return nil }
        guard when.timeIntervalSince(current.when) < switchWindow,
              let previous else { return current.source }
        return previous.source
    }

    func startObservingSystem() {
        let ws = NSWorkspace.shared
        if let app = Self.seedApp(ws), let source = Self.source(of: app) {
            focusedApp = app
            recordActivation(source, at: Date())
        }
        ws.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                if app.bundleIdentifier != Bundle.main.bundleIdentifier {
                    self.focusedApp = app
                }
                guard let source = Self.source(of: app) else { return }
                self.recordActivation(source, at: Date())
            }
        }
    }

    private static func source(of app: NSRunningApplication) -> ItemSource? {
        guard let bundleId = app.bundleIdentifier,
              bundleId != Bundle.main.bundleIdentifier else { return nil }
        return ItemSource(bundleId: bundleId, name: app.localizedName ?? bundleId)
    }

    private nonisolated static let loginWindowBundleId = "com.apple.loginwindow"

    /// `frontmostApplication` reports `loginwindow` while the screen is locked — a
    /// normal state for a login-item agent that starts before the user unlocks.
    /// `menuBarOwningApplication` still names the app the user was really in.
    private static func seedApp(_ ws: NSWorkspace) -> NSRunningApplication? {
        if let front = ws.frontmostApplication, isUsableSeed(front.bundleIdentifier) {
            return front
        }
        // The fallback gets the same check: during the first moments after login,
        // before any app owns the menu bar, this one can report loginwindow too.
        guard let menuBar = ws.menuBarOwningApplication,
              isUsableSeed(menuBar.bundleIdentifier) else { return nil }
        return menuBar
    }

    nonisolated static func isUsableSeed(_ bundleId: String?) -> Bool {
        guard let bundleId else { return false }
        return bundleId != loginWindowBundleId
    }
}
