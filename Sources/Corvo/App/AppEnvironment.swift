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
    let namePrompt: NamePrompt
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
        namePrompt = NamePrompt()

        // Built here, asked for nothing here: `NamePrompt.init` registers a
        // delegate and a category, neither of which shows the user anything.
        // The authorization dialog waits for the first clipping that needs a
        // name — see `NamePrompt.authorize()`.
        monitor.onNeedsName = { [namePrompt] itemId, tag, text in
            namePrompt.ask(toName: itemId, tag: tag.name, preview: text)
        }
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
    /// Not private: the Settings window calls it directly after the user
    /// confirms a lower retention limit, so the deletion they agreed to happens
    /// while they are looking at it.
    ///
    /// ponytail: runs on the main thread (DB write + blob directory scan) on
    /// launch, hourly, and on a confirmed limit change. The item ceiling is the
    /// user's to type now, so what keeps this honest is `Preferences.itemLimits`
    /// rather than the old fixed 1000; move this to a background queue before
    /// raising that bound.
    func runPrune() {
        do {
            try retention.prune(policy: prefs.retentionPolicy, now: Date())
        } catch {
            NSLog("Corvo: prune failed: \(error)")
        }
    }
}
