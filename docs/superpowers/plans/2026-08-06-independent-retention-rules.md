# Plan: retention rules that switch off independently

Spec: `docs/superpowers/specs/2026-08-06-independent-retention-rules-design.md`
Branch: `feat/independent-retention-rules`, from `master`.

Seven tasks. Each one is a commit, each one leaves the suite green, and the app
is usable at every step. Tests come before the code they describe.

Baseline: `make test` on this branch passes **131 tests**, measured, before task 1.
(153 is the `feat/configurable-hotkey` figure — that work is not in this tree.)

---

## Task 1 — `RetentionPolicy` says "off" with `nil`

**Why first:** every other task reads this type. Doing it alone keeps the
mechanical change out of the tasks that have judgement in them.

**Tests** (`RetentionTests`):
- Count rule off (`maxItems: nil`), 10 unprotected rows, no age rule → prune
  deletes 0.
- Age rule off (`maxAge: nil`), rows older than any cutoff → prune deletes 0.
- Both `nil` → prune deletes 0 and the blob GC still runs (a blob whose row was
  deleted by hand is still collected).
- Both set → unchanged from the current expectations.
- Pinned and tagged items survive in all four states.

**Code:**
- `RetentionPolicy.maxItems: Int?`, `maxAge: TimeInterval?`. `.standard`
  unchanged.
- `Retention.prune`: guard each sweep with `if let`. Delete the
  `policy.maxAge.isFinite` check — the unwrap replaces it.
- Migrate the four existing `RetentionPolicy(…, maxAge: .greatestFiniteMagnitude)`
  call sites in `RetentionTests` to `maxAge: nil`.
- `Preferences.retentionPolicy` keeps compiling by passing the numbers it already
  passes; the toggles arrive in task 3.

**Verify:** `make test`. The four migrated tests still assert what they asserted.

---

## Task 2 — the count sweep on its own

**Tests:**
- `enforceItemCeiling` with 5 rows and `maxItems: 2` leaves 2.
- `enforceItemCeiling` with rows older than the age rule leaves them alone — it
  is not a prune.
- `enforceItemCeiling` with `maxItems: nil` deletes nothing.
- `enforceItemCeiling` leaves an orphaned blob on disk; the next `prune`
  collects it. This is the deliberate deferral, and a test is what stops someone
  "fixing" it by adding a GC call to the hot path.
- Pinned and tagged rows are exempt here too.

**Code:** `Retention.enforceItemCeiling(policy:)`. The count `DELETE` moves into
one private method that both it and `prune` call, so there is a single statement.

**Verify:** `make test`.

---

## Task 3 — the two switches in `Preferences`

**Tests** (`PreferencesTests`):
- Fresh defaults: `limitsItems` and `limitsAge` are both `true`.
- A plist with neither key but a stored `maxItems` of 500 → still `true`, still
  500. (The upgrade is a no-op — this is the test that says so.)
- Setting `limitsItems = false` leaves `maxItems` stored, and setting it back to
  `true` returns the same number.
- `retentionPolicy` for each of the four states: both, count only, age only,
  neither.

**Code:** `limitsItems` / `limitsAge` on `Preferences`, read through
`object(forKey:) as? Bool ?? true`. `retentionPolicy` composes the optionals.

**Note:** `defaults.bool(forKey:)` returns `false` when absent, which would
switch retention off for every existing user on first launch. `object(forKey:)`
is the reason the upgrade is a no-op — the same trap `hotkeyKeyCode` documents on
the other branch.

**Verify:** `make test`.

---

## Task 4 — enforce the ceiling on capture

**Tests** (`PasteboardMonitorTests`, `IntegrationTests`):
- A capture through `poll` fires `onDidCapture` once.
- A capture that is dropped — blocklisted app, concealed marker, a duplicate that
  dedupes — does not fire it.
- Integration: `maxItems: 3`, capture four times, the history holds 3 without
  waiting for any timer.

**Code:**
- `PasteboardMonitor.onDidCapture: (() -> Void)?`, called after a successful
  insert, beside the existing `onNeedsName`.
- `AppEnvironment` wires it to a new `enforceCeiling()` that calls
  `retention.enforceItemCeiling(policy: prefs.retentionPolicy)` and logs a
  failure the way `runPrune` does.

**Verify:** `make test`, then `make run` — copy repeatedly with the limit set low
and watch the panel hold the ceiling.

---

## Task 5 — "is this a cut?" as a pure function

**Why before the UI:** it is the part with the failure mode. A rule switched from
off to on can delete years of history, and the alert is the only thing between
that and the user.

**Tests** (new `RetentionEditTests`):
- Lowering either number is a cut. (Unchanged behaviour, tested here for the
  first time.)
- Raising a number is not.
- Switching a rule from off to on is a cut, even when its number is unchanged.
- Switching a rule on while raising its number is still a cut.
- Switching a rule off is not a cut.
- Switching both off is not a cut.
- Nothing changed at all is not a cut.

**Code:** `RetentionEdit` — a `RetentionSettings` value (two numbers, two flags)
and `static func isCut(from:to:) -> Bool`. No UI, no `Preferences`.

**Verify:** `make test`.

---

## Task 6 — the toggles in Settings

**Code** (`PreferencesView`):
- Two `Toggle`s bound to draft state, one per row. The number field takes
  `.disabled(!enabled)` and `.foregroundStyle(enabled ? .primary : .secondary)`.
- `commitRetention` asks `RetentionEdit.isCut` over both numbers and both flags.
- The alert message switches on which rules will be active — the three sentences
  in the spec, each keeping its `^[…](inflect: true)`.
- The caption becomes the "Nothing is ever deleted" line when both are off.
- `commitOnClose` treats a toggle the same way it treats a number: an
  unconfirmed cut is dropped, a safe change is written.

**Verify:** `make run` and walk the four states —
1. Both on, lower the count → alert names both rules.
2. Switch the age rule off → no alert, no deletion, the number stays visible and
   dims.
3. Switch it back on → alert names the age rule only if the count rule is off,
   both if not; confirm and watch old clippings go.
4. Both off → the caption changes and nothing is ever deleted.
5. Close the window mid-edit with a rule half-switched → the cut is dropped.

Screenshot the section in light and dark before calling this done: dimmed rows
and semantic colours are the kind of thing that reads wrong in exactly one of
them.

---

## Task 7 — `AutoTagger` stops borrowing the retention limit

**Tests** (`AutoTaggerTests`, `TagManagementTests`):
- With the count rule off and more rows than `previewScanLimit`, the preview
  scans the cap and reports that it hit it.
- Under the cap, the count is exact and `hitLimit` is false — the existing
  expectations, unchanged.
- Retroactive apply tags exactly the set the preview counted, cap or no cap.
  (This is the invariant the file says may not break.)
- A raised `maxItems` no longer changes the preview's limit: the cap is the
  cap. This is a deliberate behaviour change and the test states it.

**Code:**
- `AutoTagger.previewScanLimit = 10_000`.
- `items(matching:)` returns `(items: [ClipItem], hitLimit: Bool)` — one fact,
  two strings.
- `TagEditor`: "Matches 10,000+ clippings in your history" on the preview line;
  the apply alert gains "the 10,000 most recent matching clippings. Older ones
  are not tagged."
- Update the doc comment on `items(matching:)`: it currently explains why the
  limit tracks retention, which stops being true here.

**Verify:** `make test`, then `make run` — switch the count rule off, open the tag
manager, type a pattern that matches nearly everything, confirm the editor stays
responsive and the copy says "10,000+".

---

## Closing out

1. `make test` — everything green.
2. `make release`, install over `/Applications/Corvo.app`, use it for a day with
   the count rule off. The capture-path sweep is the change most likely to be
   felt rather than seen.
3. README: the retention paragraph gains the four states and the both-off
   warning.
4. PR against `master`. Expect a `PreferencesView` conflict with
   `feat/configurable-hotkey` for whichever merges second — section ordering and
   the `@State` block.

## Risks

**The capture path is now a database write.** Copying is the hottest thing this
app does, and the sweep is one `DELETE … LIMIT -1 OFFSET n` on the main thread.
It is cheap on an indexed ordering, and it is still a write where there was none.
If it ever shows, the fix is the one already named in `runPrune`'s ponytail note:
move retention off the main thread.

**Unlimited history makes two known slow paths slower** — the main-thread blob
scan and the unindexed `LIKE` search. Neither breaks; both were already flagged.
This feature makes the case for fixing them, and does not fix them.

**Absent-means-true is the whole upgrade story.** Get it wrong — reach for
`defaults.bool(forKey:)` — and every existing user silently loses retention on
first launch, with no error and no visible symptom until their database is large.
Task 3's second test is the one that must never be deleted.
