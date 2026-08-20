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
    /// Read only by `tagChoices`, refreshed with everything else so the order
    /// the sheet offers keeps up with the tagging done through it.
    private var tagUsage: [Int64: Int] = [:]
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
        // Through `attempt` like every other write on this screen, and not a
        // bare `try?`. The fallback is not a crash, which is exactly what makes
        // it worth reporting: an empty map silently reorders the list this
        // change exists to provide, alphabetically instead of by use, with
        // nothing anywhere saying why.
        tagUsage = Self.attempt("tagUsage") { try repo.tagUsage() } ?? [:]
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

    /// One arrow press. The view reads which modifiers were down, the model owns
    /// what each combination means — rather than one keyboard shortcut per
    /// combination, which is what this used to be. SwiftUI does not tell a bare
    /// arrow apart from ⇧+arrow when both are registered: the ⇧ one takes both,
    /// and every plain arrow press started extending a run. Registering ⌘+arrow
    /// separately would have walked into the same trap on the other side.
    ///
    /// ⌘ wins over ⇧, so ⌘⇧← is a filter step and not an extension. The
    /// combination has to mean one thing, and "extend the run into the tags" is
    /// not a thing.
    /// `acrossTags` defaults to false so that every caller written before the
    /// tag strip existed still says what it meant.
    func arrow(_ step: Int, extending: Bool, acrossTags: Bool = false) {
        if acrossTags { return moveTagFilter(step) }
        extending ? extendSelection(step) : move(step)
    }

    /// Puts the panel back on the whole history, which is the view it is worth
    /// opening on: the next thing to paste is far more often the thing just
    /// copied than the one behind a filter set for a job already done.
    ///
    /// It has to be said out loud because the panel is hidden and not destroyed,
    /// so a search and a sidebar row outlive the task they were typed for and
    /// narrow the list the next time ⌘⇧V opens it. Clearing them by hand is
    /// three separate places — the field, the source row and the tag row, each
    /// of which only clears itself — and none of them announces that it is what
    /// is hiding the clipping being looked for.
    ///
    /// Assigns only what is actually set: each of the three reloads in `didSet`,
    /// and writing a value one of them already holds rebuilds the list for an
    /// answer it just gave.
    ///
    /// The cursor goes back to the newest clipping, and a ⇧-extended run does
    /// not outlive the panel either: a run restored under a cursor the user has
    /// not put there is a paste of five clippings where one was meant.
    ///
    /// Written out rather than delegated to `select`, which is guarded on the
    /// list having a row to land on and so does nothing at all on an empty
    /// history — leaving exactly the run this is here to drop. `reload` happens
    /// to clear it as well, and a reset that is only correct because of what
    /// another method does on its way past is a reset that breaks the day that
    /// method stops doing it.
    func resetView() {
        if !query.isEmpty { query = "" }
        if selectedSource != nil { selectedSource = nil }
        if selectedTag != nil { selectedTag = nil }
        selectedIndex = 0
        markedIds.removeAll()
        anchorId = nil
    }

    // MARK: - Reaching a card by number

    /// How far the number keys reach. Nine because that is how many digits sit
    /// under one hand without a modifier of their own, and because ⌘0 is not the
    /// tenth of anything on this platform — it is "reset" nearly everywhere it
    /// is bound, which is the wrong promise on a key that pastes.
    nonisolated static let numberedCards = 9

    /// The clipping ⌘<number> means, or `nil` when the list is shorter than that.
    ///
    /// A position and not an identity: the number on a card says where it is
    /// sitting right now, so it follows the search and the filter rather than
    /// naming one clipping forever. That is the version that can be read off the
    /// screen — the alternative is a number that is correct only for a list the
    /// user is no longer looking at.
    ///
    /// Lives here rather than in the view because "which clipping is the third
    /// one" is a question with a wrong answer, and an off-by-one that pastes the
    /// neighbour is the kind that gets noticed after it has been pasted.
    func item(atNumber number: Int) -> ClipItem? {
        // Bounded by the reach and not only by the list. Checking the list alone
        // answers for a number no card is wearing and no key can send — which is
        // fine right up until something else learns to ask, and then it is a
        // paste of a clipping the user was never shown.
        guard let index = Self.number(forIndex: number - 1).map({ $0 - 1 }),
              items.indices.contains(index) else { return nil }
        return items[index]
    }

    /// The number to print on the card at `index`, or `nil` past the reach. The
    /// inverse of `item(atNumber:)`, and it is spelled out rather than left to
    /// each caller so the badge on the card and the key that fires can never
    /// disagree about which is which.
    nonisolated static func number(forIndex index: Int) -> Int? {
        index < numberedCards ? index + 1 : nil
    }

    func tags(for item: ClipItem) -> [Tag] {
        guard let id = item.id else { return [] }
        return (try? repo.tags(forItem: id)) ?? []
    }

    // MARK: - Walking the filters

    /// The step both pairs take, over the values themselves rather than over
    /// `Filter`: the head of each list is `nil`, which is that axis switched
    /// off, so walking back to it clears the filter instead of landing on a
    /// case that has to guess which axis it belongs to.
    ///
    /// It clamps rather than wrapping, for the reason the tag sheet's highlight
    /// does: an arrow held down should come to rest at the end of a list, not
    /// reappear at the other end of it.
    private static func stepping<T: Equatable>(_ list: [T?], by step: Int, from here: T?) -> T? {
        let index = list.firstIndex(of: here) ?? 0
        return list[min(max(index + step, 0), list.count - 1)]
    }

    /// ⌘↑ / ⌘↓ down the sidebar, ⌘← / ⌘→ along the tag strip. One pair per
    /// direction, each pointing the way its own list is drawn — which is the
    /// only mapping a person does not have to be told.
    ///
    /// ⌘ and not ⌥⌘: the bare arrows already walk the carousel, so ⌘ is the one
    /// modifier this panel spends on "the list behind the cards", and it now
    /// spends it in both directions. The cost is that ⌘← stops meaning "start
    /// of the line" to the search field, which is a thing nobody does to a
    /// one-line search box.
    ///
    /// Two walkers and not one, so each touches only its own axis: ⌘↓ onto an
    /// app leaves the tag alone and vice versa. Combining an app and a tag used
    /// to be something only the mouse could ask for, because two positions
    /// cannot be walked with one pair of keys. With two pairs they can, and the
    /// panel stops having a filter the keyboard cannot reach.
    func moveFilter(_ step: Int) {
        selectedSource = Self.stepping([nil] + sources.map { $0.bundleId },
                                       by: step, from: selectedSource)
    }

    func moveTagFilter(_ step: Int) {
        selectedTag = Self.stepping([nil] + tags.compactMap(\.id),
                                    by: step, from: selectedTag)
    }

    /// The tags `item` could still be given, narrowed by what has been typed so
    /// far.
    ///
    /// Lives here rather than in the sheet because it is the decision the sheet
    /// exists to make, and a `View` is the one place it could not be tested.
    /// Matching is case-insensitive and anywhere in the name: the field is being
    /// used to *find* a tag, and the person typing it does not know how the tag
    /// was capitalised when it was made.
    ///
    /// Ordered by how many clippings already carry the tag, because the tag
    /// filed under most is the one most likely to be wanted again, and a list
    /// sorted by name puts that answer wherever the alphabet happens to leave
    /// it. Name breaks the tie, so equally used tags do not swap places between
    /// two openings of the same sheet.
    func tagChoices(for item: ClipItem?, matching query: String) -> [Tag] {
        tagChoices(for: [item].compactMap { $0 }, matching: query)
    }

    /// The same question for a ⇧-extended run.
    ///
    /// A tag is dropped from the list only when *every* clipping in the run
    /// already carries it. Hiding one that some of them carry would be hiding
    /// the very row that finishes the job: the reason to tag a run at once is to
    /// make it uniform, and a tag on four of five is exactly the case that needs
    /// the fifth.
    func tagChoices(for items: [ClipItem], matching query: String) -> [Tag] {
        let taken = tagsOnAll(items)
        let typed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return tags.filter { tag in
            !taken.contains(tag.name)
                && (typed.isEmpty || tag.name.localizedCaseInsensitiveContains(typed))
        }
        .sorted { a, b in
            let (ua, ub) = (usage(a), usage(b))
            return ua == ub ? a.name.localizedStandardCompare(b.name) == .orderedAscending : ua > ub
        }
    }

    private func usage(_ tag: Tag) -> Int { tag.id.flatMap { tagUsage[$0] } ?? 0 }

    /// The tag names every one of `items` carries. Empty for an empty selection.
    ///
    /// The intersection and not the union, so the sheet's two lists are exact
    /// complements: a tag is either on the whole selection, and therefore
    /// removable from it, or it is still offerable to it. A tag on some of the
    /// run would otherwise have to appear in both at once.
    func tagsOnAll(_ items: [ClipItem]) -> Set<String> {
        let carried = items.map { Set(tags(for: $0).map(\.name)) }
        return carried.dropFirst().reduce(carried.first ?? []) { $0.intersection($1) }
    }

    /// Where ↑/↓ lands in the sheet's list of tags, or `nil` for "in the field,
    /// not in the list".
    ///
    /// `nil` is a real position and not an absence: it is what makes ⏎ mean
    /// *make the tag I typed* rather than *take the one that happens to be
    /// first*. So ↑ off the top goes back to it, which is the way back to typing
    /// — and ↓ from it enters the list at the top, ↑ from it at the bottom,
    /// the way a menu opens either way in this platform.
    ///
    /// It clamps and never wraps: an arrow held down should stop at the end of a
    /// list, not reappear at the other end of one the user cannot see all of.
    /// `nonisolated` because it reads nothing: it is arithmetic on the three
    /// numbers it is handed, which is also what lets it be tested without a
    /// model.
    nonisolated static func highlight(_ current: Int?, step: Int, count: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let current else { return step > 0 ? 0 : count - 1 }
        if current == 0 && step < 0 { return nil }
        return min(max(current + step, 0), count - 1)
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

    /// Takes the tag off this one clipping. The tag itself, its colour and its
    /// rule stay — that is `deleteTag`, on the other screen, and the two are
    /// worth keeping far apart: one undoes a filing mistake, the other throws
    /// away a tag and every clipping's link to it at once.
    func removeTag(_ tag: Tag, from item: ClipItem) {
        removeTag(tag, from: [item])
    }

    /// Off a whole run, the mirror of `addTag(_:to:)` and for the same reason:
    /// the sheet acts on the selection, so both of its halves have to.
    func removeTag(_ tag: Tag, from items: [ClipItem]) {
        guard let tagId = tag.id else { return }
        for id in items.compactMap(\.id) {
            Self.attempt("removeTag") { try repo.removeTag(tagId, from: id) }
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
    func items(matching rule: TagRule) -> [ClipItem] {
        Self.attempt("items(matching:)") { try tagger.items(matching: rule) } ?? []
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
