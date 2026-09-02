import AppKit
import Foundation

/// Runs the upgrade, for the installs where there is one to run.
///
/// Corvo cannot replace its own bundle while it is running. Measured rather
/// than assumed: `brew upgrade` with the app open swaps the binary on disk and
/// leaves the old process alive on the deleted inode, so Homebrew reports
/// success and the user goes on using the version they just replaced with
/// nothing saying so.
///
/// So the work is handed to a detached shell that quits Corvo first, upgrades,
/// and opens it again. The child outlives its parent — that is the point of it
/// being a separate process — and the app being gone for a few seconds is the
/// visible part of an upgrade that is actually taking effect.
enum UpdateInstaller {
    /// Homebrew's own prefixes, Apple Silicon first. A GUI app's `PATH` does not
    /// have either, so the absolute path is the only way to find `brew` from
    /// here — this is not a preference for one install over the other.
    private static let prefixes = ["/opt/homebrew", "/usr/local"]

    /// The `brew` that also has this cask installed.
    ///
    /// Both halves matter. `brew` alone says Homebrew exists, not that it is
    /// what put Corvo in `/Applications` — and running `upgrade --cask` against
    /// an install it does not manage fails, or worse, installs a second copy
    /// beside the one the user actually launched.
    static func brewManagingCorvo(fileSystem: FileManager = .default) -> String? {
        for prefix in prefixes {
            let brew = "\(prefix)/bin/brew"
            guard fileSystem.isExecutableFile(atPath: brew) else { continue }
            guard fileSystem.fileExists(atPath: "\(prefix)/Caskroom/corvo") else { continue }
            return brew
        }
        return nil
    }

    /// The script, built rather than run, so what it does can be read in a test
    /// instead of only in production.
    ///
    /// `osascript` and not `kill`: a quit event lets the app close its database
    /// and put its panel away, where a signal would leave both to the kernel.
    /// The upgrade runs whether or not the quit succeeded — Homebrew's own
    /// `uninstall quit:` covers the case where Corvo is wedged and ignores the
    /// event.
    static func script(brew: String, bundleId: String = "com.wylp.corvo") -> String {
        """
        /usr/bin/osascript -e 'quit app id "\(bundleId)"' || true
        \(brew) upgrade --cask corvo
        /usr/bin/open -b \(bundleId)
        """
    }

    /// Starts the upgrade and reports whether it was started, not whether it
    /// worked — by the time it has worked this process is gone.
    ///
    /// A failure leaves the app at the version it was, with the Settings row
    /// still saying an update is available. That is a quiet way to fail, and it
    /// is the honest one available: there is nothing left running to show an
    /// error in.
    @discardableResult
    static func upgrade() -> Bool {
        guard let brew = brewManagingCorvo() else { return false }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", script(brew: brew)]
        // Detached from this app's session: the script's whole job happens after
        // the process that launched it has quit.
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            return true
        } catch {
            NSLog("Corvo: could not start the upgrade: \(error)")
            return false
        }
    }
}
