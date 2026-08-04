import Foundation
import GRDB
import Observation

@Observable
@MainActor
final class HistoryModel {
    private let repo: ItemRepository
    private var observationCancellable: AnyDatabaseCancellable?

    var query: String = "" { didSet { reload() } }
    var selectedSource: String? { didSet { reload() } }
    var selectedTag: Int64? { didSet { reload() } }

    private(set) var items: [ClipItem] = []
    private(set) var sources: [SourceSummary] = []
    private(set) var tags: [Tag] = []
    var selectedIndex: Int = 0

    var selectedItem: ClipItem? {
        items.indices.contains(selectedIndex) ? items[selectedIndex] : nil
    }

    init(repo: ItemRepository) {
        self.repo = repo
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
        try? repo.addTag(named: name, to: id)
        reload()
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
