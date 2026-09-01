# Changelog

## 0.2.0

Forty-eight commits over twenty-two pull requests. The panel gained multi-select,
a hover preview, tags you can reach and walk, and shortcuts for the first nine
clippings. Settings gained a shortcut you choose, retention rules that switch on
and off independently, and a sidebar. Three critical security findings from
v0.1.0 are closed, one of which means **v0.1.0 should not go on being used**.

### Security

Three findings, all present in v0.1.0.

- **The Release bundle carried the debug entitlement.**
  `com.apple.security.get-task-allow` authorises `task_for_pid()`: any process
  running as the same user could attach a debugger and read Corvo's memory —
  every clipping just captured, in the clear — with no prompt and no password.
  It is also the exact protection `ENABLE_HARDENED_RUNTIME` is bought for, so
  v0.1.0 shipped an app that only looked hardened. Entitlement injection is off
  for Release now, Debug keeps the debugger, and `make release` fails rather
  than package a bundle carrying it again.
- **A user-typed pattern could hang the app.** Tag rules ran an
  `NSRegularExpression` against third-party text on the main thread every 0.3s
  with no time limit; a pattern with a repeat inside a repeat took 46 seconds on
  thirty characters and did not return on forty. Matching now runs under a
  cooperative 0.05s budget, with a per-pattern circuit breaker so a bad pattern
  is paid for once rather than once per clipping, and the editor says a pattern
  is too slow while you are still looking at it.
- **A large image could exhaust memory.** Pasteboard images were decoded with no
  ceiling: a 4.67 MB TIFF decoded to 998 MB and held the main thread for 1.4s,
  and the result was stored, so it came back on every redraw. Dimensions are now
  read from the header before any allocation, and anything past 40 MPx is
  discarded with a log rather than half-stored.

### Added

- **Take several clippings at once.** ⇧-click or ⇧+arrows for a run, ⌘-click to
  pick them out one by one. Pasting a run joins them; images have no text to
  join and are reported rather than dropped in silence.
- **Preview a clipping by hovering it**, in an overlay beside the card rather
  than a bigger card. It opens only when it has something to add.
- **Choose the shortcut that opens the panel.** ⌘⇧V is now a default, not a
  fixture. A shortcut another app already holds is refused and says so, and the
  one you have bound stays bound.
- **Retention rules switch on and off independently.** Count and age are two
  rules now, either can be off, and lowering one asks before it deletes. The
  number stays on screen while its rule is off rather than being thrown away.
- **Tags across the top of the panel**, out of the sidebar column they used to
  share with the apps — thirteen apps was enough to push them off the bottom
  entirely. ⌘←/⌘→ walk them; ⌘↑/⌘↓ walk the apps.
- **Reach a tag you already have** instead of retyping its name. Typing at a tag
  one capital off used to file the clipping under a second tag beside it.
- **Paste the first nine clippings by number**, ⌘1 through ⌘9.
- **Switch the menu bar icon off**, with the ways back named in the confirmation
  rather than left to be discovered.
- **Reach Settings from the panel** — a gear in the search field and ⌘, — which
  is the route that exists when the menu bar icon is off.
- **Name a clipping** with ⌘R, shown on the card and searchable.
- **Search finds words apart**, not just as one run of characters.

### Changed

- **Settings is a sidebar of five panes** instead of one 520pt scroll. Every
  pane fits without scrolling, and whether Accessibility is granted no longer
  sits below the retention limits.
- **The tag sheet is two columns**: find an existing tag on the left, define a
  new one on the right. Making a tag from this sheet used to produce a tag with
  nothing but a name — a colour, a rule or a source app meant leaving, opening
  the manager and filling it in there.
- **Every tag parameter says whether it is required.** The form had five fields
  and one of them was load-bearing, and nothing said which.
- **Tags attached to a clipping are drawn as the app's own chip**, the same
  capsule the cards and the tag strip use, rather than a third representation
  invented for the one screen where a tag is handled rather than read.
- The panel's rail names the number keys, and the tag manager's rail names its
  own.

### Fixed

- **The hotkey needed two presses** to open the panel.
- **A click took about half a second to show as selected.** The card registered
  a double-tap gesture beside a single-tap one, and SwiftUI cannot know a single
  tap is single until the double-click window has passed — 422–445ms against
  78–85ms without it, and that window is a system setting, so it was worse on a
  machine tuned for a slower double click.
- **The tag sheet drew over itself.** Seven tags on one clipping overflowed a
  fixed-height box with no scroller, painting across the name field and both
  buttons.
- **A paste that never happened was reported as a paste.** A clipping whose file
  had been moved away closed the panel and did nothing, which is
  indistinguishable from the app ignoring the key. It says what happened now.
- **The permission alert names the case you actually hit**: an ad-hoc signed
  build changes identity on every rebuild, so macOS goes on showing Corvo
  switched on in Accessibility while the grant no longer applies. The remedy is
  to remove the entry and add it again, and the alert now says so.
- **The menu bar switch drew what was stored**, not what the last body pass
  happened to read — it could show off over a setting that was on, and stay
  wrong across a close and reopen.
- **A pathological pattern is remembered in something that cannot forget.** The
  set of patterns that blew the match budget lived in an `NSCache`, which is
  allowed to evict whenever it likes; evicted, a retroactive apply over a
  thousand clippings paid the budget a thousand times.
- **The tag preview says when it could not see the whole history** rather than
  reporting a count that looks exact.
- **A refused shortcut says so.** Two failures were discarded, so a shortcut
  that did not come back came back silent.
- **The hide-the-icon confirmation names the shortcut that is actually bound**
  instead of printing ⌘⇧V after you have rebound it.
- Strings added by several changes reached the String Catalog, where they had
  been missing — see below for why nothing caught it.

### Performance

Measured on a 20,000-clipping history unless noted.

- **The list is ordered by an index instead of by sorting the history.** SQLite
  was sorting every row to return 200, on every panel opening and every capture:
  15.3ms at 20k, now 1.2ms and flat from 1k to 20k. Typing went 6.19ms to
  1.56ms. The honest trade: a search matching nothing gets slower, 3.15 to
  4.74ms, because the index is walked looking for rows that are not there.
- **The carousel builds the cards it is showing.** Two hundred tag queries per
  arrow press became four.
- **One tag query for the list**, not one per card.
- **Cards decode a thumbnail**, not the whole image.
- **A filter change reloads the list**, not the sidebars with it.

### Internal

- **The CI String Catalog gate had been green for weeks without reading a
  file.** It parsed `.stringsdata` — which is JSON — with `plistlib`, swallowed
  every exception, ended with an empty key set and took the "nothing to compare,
  skipping" path. It is the reason several changes shipped strings that never
  reached the catalog. Fixed, and an empty result now fails instead of passing
  quietly.
- The suite runs on every pull request.
- Builds go to one path regardless of git worktree, and `make run` replaces the
  running copy. It used to glob across every worktree's derived data and launch
  all of them — six menu bar icons, six pollers racing for the same clipboard.

### Known issues

- **`^[…](inflect: true)` does not work.** Seven strings use it for plural
  agreement and none of them inflect: `Text` strips the markup and leaves the
  singular, so two confirmations read "2 clipping will lose this tag".
  Cosmetic, and not yet fixed.
- **`commandCommaReachesSettingsFromThePanel` is about 50% flaky.** It posts a
  real key event and depends on the search field holding focus, so it reddens
  runs at random.
- Corvo is still not notarized. macOS refuses the first launch; open it through
  System Settings › Privacy & Security.

## 0.1.0

First release.
