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

    /// The ids in a ⇧-extended run. Empty means "just the one under the cursor",
    /// which is the state every single-item action already reads through
    /// `selectedItem` — so nothing that acts on one clipping had to learn about
    /// this.
    private(set) var markedIds: Set<Int64> = []

    /// Where the current run started. Kept so that ⇧← after ⇧→ shrinks the run
    /// instead of growing it in the other direction, which is what a cursor with
    /// no anchor would do.
    ///
    /// An id and not an index: the poller reloads the list under the user's
    /// hands, and a clipping copied while a run is open lands at the front and
    /// shifts every index by one. An index anchor would then span the wrong
    /// cards on the next ⇧-press.
    private var anchorId: Int64?

    /// What ⏎ and ⌘C act on: the run in list order, or the cursor's clipping
    /// when there is no run. List order rather than the order the user extended
    /// in, because the order on screen is the one they read.
    var selectedItems: [ClipItem] {
        guard !markedIds.isEmpty else { return [selectedItem].compactMap { $0 } }
        return items.filter { item in item.id.map(markedIds.contains) ?? false }
    }

    func isMarked(_ item: ClipItem) -> Bool {
        item.id.map(markedIds.contains) ?? false
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
        // A run survives the poller, but only for clippings still in the list: a
        // filter change or a deletion leaves marks pointing at nothing, and a
        // mark pointing at nothing is a clipping that would silently fail to
        // paste later.
        markedIds.formIntersection(items.compactMap(\.id))
        if markedIds.isEmpty { anchorId = nil }
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
        select(min(max(selectedIndex + step, 0), items.count - 1))
    }

    /// Moving the cursor on purpose drops the run: the next ⏎ should act on what
    /// the eye is on, not on a set the user has stopped thinking about. This is
    /// the one place that clears it, so a tap and an arrow key behave the same.
    func select(_ index: Int) {
        guard items.indices.contains(index) else { return }
        selectedIndex = index
        markedIds.removeAll()
        anchorId = nil
    }

    /// ⇧-click: the run covers everything between the anchor and the card that
    /// was clicked, which is what ⇧-click does in every list on this platform.
    ///
    /// The anchor is where the run started, so clicking around with ⇧ held keeps
    /// sweeping out from the same card instead of dragging the start along.
    func extendSelection(to index: Int) {
        guard items.indices.contains(index) else { return }
        let anchor = anchorId.flatMap { id in items.firstIndex { $0.id == id } } ?? selectedIndex
        anchorId = items[anchor].id
        selectedIndex = index
        let run = min(anchor, index)...max(anchor, index)
        markedIds = Set(run.compactMap { items[$0].id })
    }

    /// ⌘-click: one card in or out of the run on its own, leaving the rest of it
    /// alone. The other half of ⇧-click, and it is for the selection ⇧ cannot
    /// describe — four clippings scattered through the history rather than four
    /// in a row.
    ///
    /// The first ⌘-click has to bring the cursor's own clipping into the run
    /// before adding the clicked one. `markedIds` empty means "just the cursor",
    /// so writing only the clicked card would quietly *drop* the clipping
    /// already selected instead of adding to it.
    ///
    /// The anchor follows the click, so a ⇧-click afterwards sweeps from the
    /// card last touched rather than from wherever the run began.
    func toggleMark(at index: Int) {
        guard items.indices.contains(index), let id = items[index].id else { return }
        if markedIds.isEmpty, let cursor = selectedItem?.id { markedIds.insert(cursor) }
        if markedIds.contains(id) { markedIds.remove(id) } else { markedIds.insert(id) }
        selectedIndex = index
        anchorId = markedIds.isEmpty ? nil : id
    }

    /// ⇧← and ⇧→: the same run, one card at a time, for hands that never left
    /// the keyboard.
    func extendSelection(_ step: Int) {
        guard !items.isEmpty else { return }
        extendSelection(to: min(max(selectedIndex + step, 0), items.count - 1))
    }

    /// One arrow press. The view reads whether ⇧ was down, the model owns what
    /// each of the two means — rather than two keyboard shortcuts on the same
    /// key, which is what this used to be. SwiftUI does not tell a bare arrow
    /// apart from ⇧+arrow when both are registered: the ⇧ one takes both, and
    /// every plain arrow press started extending a run.
    func arrow(_ step: Int, extending: Bool) {
        extending ? extendSelection(step) : move(step)
    }

    func tags(for item: ClipItem) -> [Tag] {
        guard let id = item.id else { return [] }
        return (try? repo.tags(forItem: id)) ?? []
    }

    func addTag(_ name: String, to item: ClipItem) {
        addTag(name, to: [item])
    }

    /// One tag onto a whole run. ⌘T on a ⇧-extended selection used to reach the
    /// cursor's clipping and say nothing about the other four — the sheet was
    /// the last thing in the panel still reading `selectedItem` after everything
    /// else had learned to read `selectedItems`.
    ///
    /// One `reload()` at the end and not one per clipping: the list is rebuilt
    /// from the database either way, and reloading inside the loop redraws the
    /// panel once per item for no answer the last one does not already give.
    ///
    /// A clipping the write fails on is skipped and the rest still go through.
    /// The alternative is a run where an early failure silently decides that the
    /// other four keep nothing — and `addTag` ignores the conflict, so re-tagging
    /// what did work is harmless.
    func addTag(_ name: String, to items: [ClipItem]) {
        for id in items.compactMap(\.id) {
            Self.attempt("addTag") { try repo.addTag(named: name, to: id) }
        }
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
