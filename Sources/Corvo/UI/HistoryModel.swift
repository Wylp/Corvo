import Foundation
import GRDB
import Observation

@Observable
@MainActor
final class HistoryModel {
    private let repo: ItemRepository
    private let tagger: AutoTagger
    private var observationCancellable: AnyDatabaseCancellable?

    var query: String = "" { didSet { reload() } }
    var selectedSource: String? { didSet { reload() } }
    var selectedTag: Int64? { didSet { reload() } }
    /// The one sheet the panel can have up, or `nil` for none. Lives on the
    /// model rather than in a view so that the sidebar's button and the panel's
    /// ⌘⇧T open the same thing — and so that hiding the panel can clear it.
    ///
    /// One optional rather than two booleans because SwiftUI gets one `.sheet`:
    /// two of them on nested views is how this screen used to do it, and a
    /// presentation nested inside another is how the dimming overlay gets stuck
    /// on screen with nothing behind it left to dismiss it.
    var sheet: PanelSheet?

    /// `Identifiable` for `.sheet(item:)`, which is the modifier that takes the
    /// whole state in one binding instead of one boolean per sheet.
    enum PanelSheet: Identifiable {
        /// The tag manager: names, colours and rules.
        case tags
        /// Naming a new tag for the selected clipping.
        case naming
        /// Naming the selected clipping itself — ⌘R. A different thing from
        /// `.naming`: a tag is a label shared across clippings, a name belongs
        /// to exactly one.
        case rename

        var id: Self { self }
    }

    private(set) var items: [ClipItem] = []
    private(set) var sources: [SourceSummary] = []
    private(set) var tags: [Tag] = []
    var selectedIndex: Int = 0

    var selectedItem: ClipItem? {
        items.indices.contains(selectedIndex) ? items[selectedIndex] : nil
    }

    init(repo: ItemRepository, prefs: Preferences) {
        self.repo = repo
        self.tagger = AutoTagger(repo: repo, prefs: prefs)
        reload()
    }

    func reload() {
        items = (try? repo.search(text: query, sourceBundleId: selectedSource,
                                  tagId: selectedTag, limit: 200)) ?? []
        sources = (try? repo.sources()) ?? []
        tags = (try? repo.allTags()) ?? []
        selectedIndex = min(selectedIndex, max(items.count - 1, 0))
        if items.isEmpty { selectedIndex = 0 }
    }

    /// Makes the list react to the poller with no manual refresh.
    func observeDatabase() {
        observationCancellable = ValueObservation
            .tracking { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM item") ?? 0 }
            .start(in: repo.dbQueue, scheduling: .async(onQueue: .main),
                   onError: { _ in },
                   onChange: { [weak self] _ in
                       // `.async(onQueue: .main)` guarantees the main thread; the
                       // compiler cannot know that on its own.
                       MainActor.assumeIsolated { self?.reload() }
                   })
    }

    func move(_ step: Int) {
        guard !items.isEmpty else { return }
        selectedIndex = min(max(selectedIndex + step, 0), items.count - 1)
    }

    func tags(for item: ClipItem) -> [Tag] {
        guard let id = item.id else { return [] }
        return (try? repo.tags(forItem: id)) ?? []
    }

    func addTag(_ name: String, to item: ClipItem) {
        guard let id = item.id else { return }
        Self.attempt("addTag") { try repo.addTag(named: name, to: id) }
        reload()
    }

    /// Names the clipping, or clears the name when `name` is blank.
    ///
    /// Takes an id rather than a `ClipItem` because the other caller is the
    /// notification, which comes back with an id and nothing else — and by then
    /// the item may not be on screen, or in `items` at all.
    func setLabel(_ name: String, forItemId id: Int64) {
        Self.attempt("setLabel") { try repo.setLabel(name, for: id) }
        reload()
    }

    // MARK: - Tag management

    /// Every write on this screen goes through here, for the reason
    /// `PasteboardMonitor.start` and `AppEnvironment.runPrune` already do it:
    /// a bare `try?` throws the failure away, and a tag screen that answers a
    /// failed save by doing nothing at all is indistinguishable from one that
    /// worked. `nil` is the caller's cue to say so.
    private static func attempt<T>(_ what: String, _ write: () throws -> T) -> T? {
        do {
            return try write()
        } catch {
            NSLog("Corvo: \(what) failed: \(error)")
            return nil
        }
    }

    /// `nil` when the write failed — the editor shows that next to Save. The
    /// caller also uses the answer to keep the row selected, since a create only
    /// learns its id here.
    @discardableResult
    func saveTag(_ tag: Tag) -> Tag? {
        let saved = Self.attempt("saveTag") { try repo.saveTag(tag) }
        reload()
        return saved
    }

    func deleteTag(_ tag: Tag) {
        guard let id = tag.id else { return }
        Self.attempt("deleteTag") { try repo.deleteTag(id) }
        // The sidebar may be filtering by the tag that just stopped existing.
        // Assigning triggers `reload()` on its own.
        guard selectedTag != id else { return selectedTag = nil }
        reload()
    }

    func itemCount(forTag tag: Tag) -> Int {
        guard let id = tag.id else { return 0 }
        return Self.attempt("itemCount") { try repo.itemCount(forTag: id) } ?? 0
    }

    /// What the rule would claim right now. The editor's preview and the count
    /// the retroactive apply asks the user to confirm come from this one call,
    /// so the number shown is the set that gets tagged.
    func items(matching rule: TagRule) -> AutoTagger.Matches {
        Self.attempt("items(matching:)") { try tagger.items(matching: rule) } ?? .none
    }

    @discardableResult
    func applyRuleToExistingItems(_ tag: Tag) -> Int {
        let tagged = Self.attempt("applyToExistingItems") {
            try tagger.applyToExistingItems(tag)
        } ?? 0
        reload()
        return tagged
    }

    func togglePinned(_ item: ClipItem) {
        guard let id = item.id else { return }
        try? repo.setPinned(id, !item.pinned)
        reload()
    }

    func delete(_ item: ClipItem) {
        guard let id = item.id else { return }
        try? repo.delete(id)
        reload()
    }

    func markUsed(_ item: ClipItem) {
        guard let id = item.id else { return }
        try? repo.touch(id, now: Date())
    }
}
