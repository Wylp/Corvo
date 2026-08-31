# Retention rules that switch off independently

Retention today is two rules that always both apply: keep at most N clippings,
and delete anything older than M days. The numbers are the user's — the fields
have been editable since the Settings window existed, bounded by
`Preferences.itemLimits` and `ageLimits`. What no one can do is switch one rule
off.

This makes each rule independently on or off, giving four states:

| Keep at most | Delete after | Behaviour |
| --- | --- | --- |
| on | on | Today's behaviour, unchanged. Whichever rule bites first. |
| on | off | A count ceiling. Hit N and the oldest goes, at any age. |
| off | on | An age limit only. Clippings expire; nothing caps how many. |
| off | off | Nothing is ever deleted. |

## What this is not

**No per-clipping TTL column.** `Retention.prune` already deletes by age from
`item.createdAt` against a cutoff computed at prune time. Storing a TTL per row
would be more code and less correct: it would freeze the setting at capture, so
changing "30 days" to "7" would leave every clipping already in the history on
the old value. The cutoff is derived, and stays derived.

**Not a change to the numbers or their bounds.** `itemLimits` (1…10,000) and
`ageLimits` (1…3,650) stay exactly as they are, and so does clamping on read.

## The policy

`RetentionPolicy` becomes two optionals, where `nil` is a rule that is off:

```swift
struct RetentionPolicy: Equatable {
    var maxItems: Int?
    var maxAge: TimeInterval?

    static let standard = RetentionPolicy(maxItems: 1000, maxAge: 30 * 24 * 3600)
}
```

Optionals rather than sentinels. `maxAge` is already effectively optional —
`Retention.prune` guards the age sweep with `if policy.maxAge.isFinite`, so
`.infinity` means "off" today — but a reader has to know that to see it, and
there is no equivalent trick available for a count. `nil` says it once, for both,
and makes "off" unrepresentable as a number.

`Retention.prune` then guards each sweep on its own optional. The age sweep's
`isFinite` check goes away, replaced by the unwrap. Four call sites in
`RetentionTests` construct policies with `.greatestFiniteMagnitude` to mean "no
age rule"; those become `nil`, which is what they were always saying.

## Storage

Two new booleans, `limitsItems` and `limitsAge`, absent meaning **true**.

```swift
var limitsItems: Bool { get { defaults.object(forKey: "limitsItems") as? Bool ?? true } … }
```

Absent-means-true is what makes the upgrade a no-op: every existing user has
neither key, reads `true` for both, and keeps exactly the retention they have
today. The stored numbers are untouched by switching a rule off, so switching it
back on restores the number the user last chose rather than the default.

`retentionPolicy` composes the four states:

```swift
var retentionPolicy: RetentionPolicy {
    RetentionPolicy(maxItems: limitsItems ? maxItems : nil,
                    maxAge: limitsAge ? Double(maxAgeDays) * 86400 : nil)
}
```

## When the ceiling is enforced

Today prune runs on launch, hourly, and after the user confirms a lower limit.
That is fine for an age rule, whose boundary moves by itself, and wrong for a
count ceiling: a "keep at most 1,000" that sits at 1,047 for the rest of the
hour is not a ceiling.

So the count sweep also runs **after each capture** — and only the count sweep:

| Trigger | What runs |
| --- | --- |
| capture | count sweep only |
| launch | count sweep, age sweep, blob GC |
| hourly | count sweep, age sweep, blob GC |
| limit lowered or rule switched on | count sweep, age sweep, blob GC |

The split is deliberate and the reason is in `AppEnvironment.runPrune`'s own
note: prune does a database write **and a full blob-directory scan** on the main
thread. The scan is the expensive half, and it is the half a capture does not
need — one `DELETE … LIMIT -1 OFFSET n` on an indexed ordering is cheap enough
to sit on the copy path, a directory walk is not.

The cost of that split, stated plainly: a clipping deleted by the capture-time
sweep leaves its blob on disk until the next hourly GC. Blob GC is keyed on the
live paths in the database and is idempotent, so nothing is lost — up to an hour
of orphaned image files is the whole price.

`Retention` therefore grows a second entry point:

```swift
@discardableResult func enforceItemCeiling(policy: RetentionPolicy) throws -> Int
```

Named for what it is for. `prune(policy:now:)` keeps its shape and calls the same
SQL for the count half, so there is one statement, not two that can drift.

The capture path reaches it through a new `PasteboardMonitor.onDidCapture`
closure, wired in `AppEnvironment` beside the existing `onNeedsName`. The monitor
already owns "something was captured"; nothing else has to learn about it.

## Settings

A toggle per row, matching the switch on "Launch at login" directly above:

```
History
  Keep at most        [ 1,000 ] clippings      (•)
  Delete after        [    30 ] days           ( )

  Pinned or tagged clippings never expire, and do not count towards the limit.
```

A switched-off row keeps its number, dimmed and non-editable — `.disabled(…)`
plus `.foregroundStyle(.secondary)`. The number stays visible on purpose: it is
what comes back when the rule does, and a field that empties itself when
switched off loses the user's choice for no reason.

**Both off** shows a caption in place of the usual one:

> Nothing is ever deleted. The history grows until you delete clippings
> yourself.

It is allowed. It is the user's disk, and a clipboard manager that refuses to
keep everything is deciding something that is not its to decide. The line is
there so it is a choice rather than a surprise.

## Confirming what deletes

The window already refuses to cut retention without asking: lowering a number
raises "Delete clippings now?", and the deletion runs while the user is still
looking at the screen that caused it.

**Switching a rule on is a cut**, and a bigger one than lowering a number
usually is — an age rule switched on for the first time can take years of
history in one go. It routes through the same alert and the same
`onRetentionLowered` call. Switching a rule **off** deletes nothing and asks
nothing.

The alert's message has to say which rules will apply, which is now three
sentences rather than one:

| Active rules | Message |
| --- | --- |
| both | Corvo will keep the newest *N clippings* and delete anything older than *M days*. |
| count only | Corvo will keep the newest *N clippings*, whatever their age. |
| age only | Corvo will delete anything older than *M days*, however few are left. |

Each keeps `^[…](inflect: true)` for its numbers and the existing "Pinned and
tagged clippings are never deleted. Corvo has no undo." Both-off never reaches
the alert: nothing is being cut.

`commitRetention` currently compares two drafts against two stored numbers to
decide whether a cut is happening. It grows to compare the toggles as well — a
rule going from off to on counts as a cut whatever its number does — and that
decision moves out of the view into a pure function, `RetentionEdit`, for the
reason `ShortcutEditor` exists: "is this destructive" is the part that must not
break, and a rule inside a SwiftUI body is a rule nothing can ask a question of.

## The bound that disappears

`Preferences.itemLimits` carries this comment, and it is the reason this feature
needs a decision rather than just a toggle:

> The upper bound is a real budget, not a taste. Three things were written
> against a fixed ceiling of 1000 … An unbounded number would freeze the app on
> launch.

Switching "Keep at most" off removes that bound. Each of the three paths, checked
against what it actually does:

**1. `AppEnvironment.runPrune` — main-thread write plus blob scan.** Unaffected in
kind: it already scans the whole blob directory, which is sized by the history
whatever the ceiling says. Unbounded history makes an already-main-thread scan
slower, and the existing ponytail note ("move this to a background queue before
raising that bound") is the fix. Out of scope here, named in the plan.

**2. The panel's search — `LIKE` with no index.** Safe on result size:
`HistoryModel.reload` always passes `limit: 200`. The scan cost grows with the
table, which is the same trade the ponytail note about FTS5 already describes.
Out of scope.

**3. `AutoTagger.items(matching:)` — the real problem.** It passes
`limit: prefs.retentionPolicy.maxItems` and then runs the regex **in Swift**,
from the tag editor's live preview, on every edit to the pattern. With the count
rule off there is no number to pass, and an unbounded fetch-and-scan on each
keystroke is a frozen editor on a large history.

It stops depending on the retention setting and gets its own cap:

```swift
/// The most rows a rule preview will scan, independent of retention.
static let previewScanLimit = 10_000
```

The same 10,000 `itemLimits` already calls roughly a decade of heavy use, but now
stated where the scan happens rather than borrowed from a setting that may be
off.

That cap could make the preview undercount, which the file says is the one thing
this pair may not do — so it is made visible instead of silent. When the scan
fills the cap, the editor says so:

- Preview line: **"Matches 10,000+ clippings in your history"** rather than an
  exact count.
- Apply alert: **"The tag is saved and added to the 10,000 most recent matching
  clippings. Older ones are not tagged. Corvo has no undo."**

`items(matching:)` returns whether it hit the cap alongside the matches, so both
strings are driven by the same fact rather than by a second count.

The invariant survives in the form that matters: the number the user is asked to
confirm is exactly the set that gets tagged.

## Tests

Swift Testing, extending `RetentionTests` and `PreferencesTests`, plus a new file
for the edit decision.

| Test | What it guards |
| --- | --- |
| Count rule off: nothing is deleted for being numerous, however many rows | the new guard |
| Age rule off: nothing is deleted for being old, however old | the guard that replaces `isFinite` |
| Both off: prune deletes nothing at all | the four-state table's last row |
| Both on: unchanged from today | no regression in the case everyone is in |
| Pinned and tagged items stay exempt in every one of the four states | the existing protection is not quietly tied to a rule |
| `enforceItemCeiling` deletes by count and leaves the age rule alone | the capture path does only its half |
| `enforceItemCeiling` does not run blob GC | the deliberate deferral, so it cannot be "fixed" by accident |
| Absent `limitsItems`/`limitsAge` read as `true` | the upgrade is a no-op |
| Switching a rule off leaves its number stored | switching it back on restores the user's choice |
| `retentionPolicy` maps all four states | the composition |
| Switching a rule on is a cut; switching off is not | `RetentionEdit`, the alert's trigger |
| Lowering a number is still a cut | no regression in what already asks |
| `AutoTagger` preview stops at `previewScanLimit` and reports that it did | the invariant that an undercount is never silent |

## Out of scope

- Moving prune off the main thread, and search to FTS5. Both are named in
  existing ponytail notes and both get more attractive with unlimited history,
  but neither is required for these toggles to be correct.
- A SQLite `REGEXP` function, which would let the tag preview be exact and
  unbounded. That is the better long-term answer to the `AutoTagger` problem and
  it is its own piece of work.
- Showing the history's size on disk in Settings.
- Any change to the retention numbers' bounds.

## Branching

From `master`, so this reviews and merges independently of
`feat/configurable-hotkey`. Both branches edit `PreferencesView` — the Shortcut
section sits directly above History — so whichever merges second will conflict in
that file. The conflict is confined to section ordering and the `@State` block,
and is resolved by hand at merge time.
