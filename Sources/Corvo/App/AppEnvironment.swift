import AppKit
import Foundation

/// Builds and wires the dependencies. The only place that knows every layer.
@MainActor
final class AppEnvironment {
    let prefs: Preferences
    let blobs: BlobStore
    let repo: ItemRepository
    let tracker: SourceTracker
    let retention: Retention
    let monitor: PasteboardMonitor
    private var pruneTimer: Timer?

    init() throws {
        prefs = Preferences()
        blobs = BlobStore(directory: AppDatabase.supportDirectory
            .appendingPathComponent("blobs", isDirectory: true))
        repo = ItemRepository(dbQueue: try AppDatabase.make(at: AppDatabase.defaultURL),
                              blobs: blobs)
        tracker = SourceTracker()
        retention = Retention(repo: repo, blobs: blobs)
        monitor = PasteboardMonitor(pasteboard: NSPasteboard.general, repo: repo,
                                    tracker: tracker, prefs: prefs)
    }

    func start() {
        tracker.startObservingSystem()
        monitor.start()
        runPrune()
        let t = Timer(timeInterval: 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.runPrune() }
        }
        RunLoop.main.add(t, forMode: .common)
        pruneTimer = t
    }

    /// Named `runPrune`, not `prune`: `Retention.prune` is the method this one
    /// calls, and two `prune`s one line apart read like a recursion bug.
    ///
    /// ponytail: runs on the main thread (DB write + blob directory scan) on
    /// launch and hourly. Fine up to the 1000-item retention ceiling; move to
    /// a background queue if that ceiling ever grows.
    private func runPrune() {
        do {
            try retention.prune(policy: prefs.retentionPolicy, now: Date())
        } catch {
            NSLog("Corvo: prune failed: \(error)")
        }
    }
}
