import Foundation

/// Applies every rule-carrying tag to a freshly captured item.
///
/// It runs *after* the insert, never before: the privacy guards in
/// `PasteboardMonitor.poll` decide what is allowed to become a row at all, and
/// content they reject must never reach a rule.
@MainActor
struct AutoTagger {
    private let repo: ItemRepository
    /// Only for the item ceiling `items(matching:)` scans up to. It has to be
    /// the ceiling retention actually enforces, not the default one.
    private let prefs: Preferences

    init(repo: ItemRepository, prefs: Preferences) {
        self.repo = repo
        self.prefs = prefs
    }

    /// Applies every active rule to the item that was just inserted.
    ///
    /// Returns the tags that matched **and** ask for a name. Nothing here
    /// notifies anyone: `PasteboardMonitor.poll` takes the list and hands the
    /// first of them to `NamePrompt`, so that the rule engine stays a pure
    /// question of what matched and the answer about whom to bother lives one
    /// layer up.
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
    /// The limit is `prefs.retentionPolicy.maxItems` — the same number
    /// `AppEnvironment.runPrune` enforces — and not `RetentionPolicy.standard`.
    /// The user can raise the preference; a limit stuck at the default would
    /// make the preview undercount and the retroactive apply skip the tail of
    /// the history in silence, which is the one thing this pair may not do.
    ///
    /// ponytail: reads the history and matches in Swift, because the pattern is
    /// a regex and SQLite carries no `REGEXP` of its own. A scan of `maxItems`
    /// short rows — a thousand by default, and capped by `Preferences.itemLimits`
    /// now that the user sets it. Only ever runs from the editor's preview and
    /// the retroactive apply, never from `poll`. Upgrade: register a compiled
    /// `REGEXP` function on the connection before that cap is raised.
    func items(matching rule: TagRule) throws -> [ClipItem] {
        guard rule.isActive else { return [] }
        return try repo.search(text: "", sourceBundleId: nil, tagId: nil,
                               limit: prefs.retentionPolicy.maxItems)
            .filter { rule.matches(text: Self.matchable(kind: $0.kind, text: $0.text),
                                   sourceBundleId: $0.sourceBundleId) }
    }

    /// Attaches `tag` to every item its rule already matches, and answers how
    /// many links that actually created. Items that already carried the tag are
    /// not counted: the number goes into "added to N clippings", and running the
    /// same apply twice changed nothing the second time.
    ///
    /// Never called from `poll`: tagging a thousand rows has no undo in this
    /// app, so it stays something the user asks for by name.
    @discardableResult
    func applyToExistingItems(_ tag: Tag) throws -> Int {
        var added = 0
        for item in try items(matching: tag.rule) {
            guard let id = item.id else { continue }
            if try repo.addTag(named: tag.name, to: id) { added += 1 }
        }
        return added
    }
}
