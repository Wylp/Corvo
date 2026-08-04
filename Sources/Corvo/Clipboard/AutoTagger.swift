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
    /// a caller would prompt about. Nothing here notifies anyone, and no caller
    /// consumes the list yet — the toggle that sets `promptsForName` exists, the
    /// prompt it implies does not.
    ///
    /// ponytail: reads every tag and matches in a loop, one write per hit.
    /// Tags are user-made, so this is tens of rows against one item. If tags
    /// ever run to thousands, filter the rule-carrying ones in SQL and batch
    /// the writes into a single transaction.
    @discardableResult
    func apply(toItem id: Int64, kind: ClipKind, text: String?,
               sourceBundleId: String?) throws -> [Tag] {
        var promptable: [Tag] = []
        let haystack = Self.matchable(kind: kind, text: text)
        for tag in try repo.allTags() where tag.rule.isActive {
            guard tag.rule.matches(text: haystack, sourceBundleId: sourceBundleId) else { continue }
            // Looking the tag up by name is what `addTag` already does, and the
            // name is unique — no second write path needed for rule tags.
            try repo.addTag(named: tag.name, to: id)
            if tag.promptsForName { promptable.append(tag) }
        }
        return promptable
    }

    /// What a pattern is allowed to be matched against, by kind.
    ///
    /// Every capture carries text, but an image's is `"Image"` — the row's
    /// internal display name, not content. Handed to a rule unfiltered, patterns
    /// like `Image`, `age` or `.` would claim every screenshot the user copies.
    /// A file's text is its own name, which is what makes `\.pem$` a legitimate
    /// rule. `nil` leaves an image matchable only by a source-only rule.
    ///
    /// The single place this decision is made: the live poller and the
    /// retroactive apply below both come through here.
    static func matchable(kind: ClipKind, text: String?) -> String? {
        kind == .image ? nil : text
    }

    /// The items already in the history that `rule` would claim. Drives both the
    /// editor's live preview and the retroactive apply, so the count the user is
    /// asked to confirm is exactly the set that gets tagged.
    ///
    /// ponytail: reads the history and matches in Swift, because the pattern is
    /// a regex and SQLite carries no `REGEXP` of its own. Retention caps the
    /// table at `maxItems`, so this is a scan of a thousand short rows. Upgrade:
    /// register a compiled `REGEXP` function on the connection if the cap lifts.
    func items(matching rule: TagRule) throws -> [ClipItem] {
        guard rule.isActive else { return [] }
        return try repo.search(text: "", sourceBundleId: nil, tagId: nil,
                               limit: RetentionPolicy.standard.maxItems)
            .filter { rule.matches(text: Self.matchable(kind: $0.kind, text: $0.text),
                                   sourceBundleId: $0.sourceBundleId) }
    }

    /// Attaches `tag` to every item its rule already matches, and answers how
    /// many. Never called from `poll`: tagging a thousand rows has no undo in
    /// this app, so it stays something the user asks for by name.
    @discardableResult
    func applyToExistingItems(_ tag: Tag) throws -> Int {
        let matches = try items(matching: tag.rule)
        for item in matches {
            guard let id = item.id else { continue }
            try repo.addTag(named: tag.name, to: id)
        }
        return matches.count
    }
}
