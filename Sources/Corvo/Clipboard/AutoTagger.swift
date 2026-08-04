import Foundation

/// Applies every rule-carrying tag to a freshly captured item.
///
/// It runs *after* the insert, never before: the privacy guards in
/// `PasteboardMonitor.poll` decide what is allowed to become a row at all, and
/// content they reject must never reach a rule.
@MainActor
struct AutoTagger {
    private let repo: ItemRepository

    init(repo: ItemRepository) {
        self.repo = repo
    }

    /// Applies every active rule to the item that was just inserted.
    ///
    /// Returns the tags that matched **and** ask for a name, which is the list
    /// a caller would prompt about. Task 12c builds that prompting; nothing
    /// here notifies anyone.
    ///
    /// ponytail: reads every tag and matches in a loop, one write per hit.
    /// Tags are user-made, so this is tens of rows against one item. If tags
    /// ever run to thousands, filter the rule-carrying ones in SQL and batch
    /// the writes into a single transaction.
    @discardableResult
    func apply(toItem id: Int64, text: String?, sourceBundleId: String?) throws -> [Tag] {
        var promptable: [Tag] = []
        for tag in try repo.allTags() where tag.rule.isActive {
            guard tag.rule.matches(text: text, sourceBundleId: sourceBundleId) else { continue }
            // Looking the tag up by name is what `addTag` already does, and the
            // name is unique — no second write path needed for rule tags.
            try repo.addTag(named: tag.name, to: id)
            if tag.promptsForName { promptable.append(tag) }
        }
        return promptable
    }
}
