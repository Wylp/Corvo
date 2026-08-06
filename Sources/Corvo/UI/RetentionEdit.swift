/// The four numbers and switches the History section edits, as one value.
struct RetentionSettings: Equatable {
    var maxItems: Int
    var maxAgeDays: Int
    var limitsItems: Bool
    var limitsAge: Bool
}

/// Whether a change to the History section is about to delete clippings.
///
/// Pure, and outside the view, because this is the question the confirmation
/// alert asks and the alert is the only thing between an accidental edit and an
/// irreversible delete. A rule inside a SwiftUI body is a rule nothing can ask a
/// question of — the same reason `Blocklist` is not inside the field that edits
/// it.
enum RetentionEdit {
    /// True when moving from `from` to `to` narrows what the history is allowed to
    /// keep, in any of the ways it can be narrowed.
    ///
    /// Three kinds of narrowing, and the third is the one this feature adds:
    ///
    /// - A number goes down while its rule is on.
    /// - A rule that was off is switched on. Its number need not change at all —
    ///   an age rule switched on for the first time can take years of history in
    ///   one go, which is the largest cut this screen can make.
    /// - Both at once.
    ///
    /// Switching a rule **off** widens what is kept and deletes nothing, so it is
    /// never a cut. Neither is raising a number, and neither is changing the
    /// number of a rule that is off — that value is not being enforced.
    static func isCut(from before: RetentionSettings, to after: RetentionSettings) -> Bool {
        cutsItems(from: before, to: after) || cutsAge(from: before, to: after)
    }

    private static func cutsItems(from before: RetentionSettings,
                                  to after: RetentionSettings) -> Bool {
        guard after.limitsItems else { return false }
        guard before.limitsItems else { return true }
        return after.maxItems < before.maxItems
    }

    private static func cutsAge(from before: RetentionSettings,
                                to after: RetentionSettings) -> Bool {
        guard after.limitsAge else { return false }
        guard before.limitsAge else { return true }
        return after.maxAgeDays < before.maxAgeDays
    }
}
