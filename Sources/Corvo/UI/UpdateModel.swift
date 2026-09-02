import AppKit
import Foundation
import Observation

/// What the two screens showing update state are reading.
///
/// Shared rather than injected, the way `PreviewPanel.shared` is, and for the
/// same reason: two unrelated views need it — the panel's gear and the Settings
/// window — and threading a dependency through `HistoryView`'s initialiser
/// would touch every test that builds a panel to say nothing about updates.
///
/// The part worth testing is not here. Whether one version is newer than
/// another is `AppVersion.isNewer`, which is a pure function with its own tests;
/// this is the glue that calls it.
@MainActor
@Observable
final class UpdateModel {
    static let shared = UpdateModel()

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(UpdateCheck.Release)
        /// The check did not complete. Deliberately without the error: there is
        /// nothing a user can do about a DNS failure, and a version check that
        /// shouts about being offline is worse than one that stays quiet.
        case failed
    }

    private(set) var state = State.idle

    /// Once a day. A menu bar agent runs for weeks, so checking only at launch
    /// would mean a release could sit unannounced for as long as the machine
    /// stays up.
    static let interval: TimeInterval = 86_400

    private var timer: Timer?

    private init() {}

    /// Starts checking, if the user has left it switched on.
    ///
    /// Reads `prefs` on every tick rather than capturing the answer, so
    /// switching it off in Settings stops the next check instead of the next
    /// launch.
    func start(prefs: Preferences) {
        timer?.invalidate()
        let t = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkIfEnabled(prefs: prefs) }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        checkIfEnabled(prefs: prefs)
    }

    func checkIfEnabled(prefs: Preferences) {
        guard prefs.checksForUpdates else { return clear() }
        check()
    }

    /// The state the app is in when it is not asking and has nothing to report.
    /// Called when the setting goes off, so a badge raised by an earlier check
    /// does not outlive the switch that allowed it.
    func clear() {
        state = .idle
    }

    func check() {
        guard state != .checking else { return }
        state = .checking
        Task { [weak self] in
            do {
                let release = try await UpdateCheck.latest()
                self?.settle(on: release)
            } catch {
                self?.state = .failed
            }
        }
    }

    private func settle(on release: UpdateCheck.Release) {
        guard AppVersion.isNewer(release.version, than: AppVersion.current) else {
            state = .upToDate
            return
        }
        state = .available(release)
    }

    /// What the Update button does, which depends on how Corvo was installed.
    ///
    /// Homebrew is the only install with an upgrade to run. A copy dragged out
    /// of the release zip has no package manager behind it, so the honest
    /// action there is the page it came from — the same button, because to the
    /// user it is the same intent.
    func install() {
        guard case .available(let release) = state else { return }
        guard UpdateInstaller.upgrade() else {
            NSWorkspace.shared.open(release.url)
            return
        }
    }

    /// Whether anything should be drawn on the gear. Only a found release earns
    /// it — not a failure, and not the checking itself, neither of which is
    /// something the user asked to be told about.
    var hasUpdate: Bool {
        guard case .available = state else { return false }
        return true
    }
}
