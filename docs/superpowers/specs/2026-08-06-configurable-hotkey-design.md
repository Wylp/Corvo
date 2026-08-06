# Configurable global shortcut

The global shortcut that opens the panel is fixed at `⌘⇧V`, in code, in one
line of `AppDelegate`. This makes it something the user chooses in Settings.

Both the v1 design (`2026-08-03-corvo-design.md`, "Atalho global") and the
comment at the top of `GlobalHotkey.swift` anticipated this request and both
recommended replacing the file with the `KeyboardShortcuts` package. That
recommendation is declined here, deliberately: the package keeps the shortcut in
its own `UserDefaults` key, which would leave exactly one setting in the app
that does not read through `Preferences`. The recorder is written instead, on
the Carbon registration that already works.

## Scope

Only the global shortcut that opens the panel is configurable.

Every in-panel key stays fixed: `⏎`, `⌘C`, `⌘R`, `⌘T`, `⌘⇧T`, `⌘P`, `⌘⌫`, `Esc`.
They compete only inside Corvo's own window, where nothing else can claim them,
and rebinding them would mean the panel's keycap rail has to render from
preferences instead of stating what it states now. The global shortcut is the
only one that can collide with another application, which is the whole reason
this is being asked for.

## The value type

`Sources/Corvo/System/Hotkey.swift`, new.

```swift
struct Hotkey: Equatable, Sendable {
    let keyCode: UInt32      // physical key, kVK_*
    let modifiers: UInt32    // Carbon masks: cmdKey | shiftKey | optionKey | controlKey
}
```

Carbon modifier masks rather than `NSEvent.ModifierFlags`, because
`RegisterEventHotKey` takes Carbon. Storing Carbon means no translation on the
path that registers, and one translation — `init?(event: NSEvent)` — on the path
that records.

`static let `default`` is `⌘⇧V`, so the shipped behaviour is unchanged for
anyone who never opens the section.

### Display

`var display: String` renders `"⌘⇧V"`: modifier glyphs in the canonical macOS
order `⌃⌥⇧⌘`, then the key label.

The key label is derived **at display time** from `keyCode`, through
`UCKeyTranslate` against the current input source, with a small table for the
keys that have no character — arrows, `F1`–`F20`, Return, Space, Tab, `⌫`, Esc.
It is not stored.

The cheaper alternative is to persist `charactersIgnoringModifiers` from the
recorder and use it as the label forever. It is rejected for the reason the
locale and CRLF bugs in this codebase were fixed rather than tolerated: a
`keyCode` is *physical*, so the binding follows the key's position across a
layout change while a stored label keeps describing the layout that recorded it.
A label that can lie about what a shortcut does is worse than no label.

### The guardrail

Pure and testable, in the shape `Blocklist` already establishes — a decision
function with no UI attached:

```swift
enum HotkeyRule {
    enum Rejection { case needsModifier }
    static func rejection(for hotkey: Hotkey) -> Rejection?
}
```

A binding must carry at least one of `cmdKey`, `optionKey`, `controlKey`. Any
combination of extras alongside is accepted.

`⇧` alone is not enough, and this is the case worth naming: `⇧V` is how a person
types a capital V. Registered globally it would swallow the key in every
application, and the user who did it would have no working keyboard to undo it
with.

System-reserved combos (`⌘Tab`, `⌘Space`, `⌘⇧3`) are **not** blocked by a
hardcoded list. macOS already wins them, which means `RegisterEventHotKey` fails
and the refusal path below handles it with a message that is only slightly less
specific than a curated list would give.

## Storage

`Preferences.hotkey: Hotkey?` — `nil` means cleared, no global shortcut at all.
Two keys, `hotkeyKeyCode` and `hotkeyModifiers`.

Two traps, both handled explicitly:

- **`kVK_ANSI_A == 0`.** `defaults.integer(forKey:)` returns `0` both for the
  key A and for a key that was never set, so absence is read with
  `object(forKey:) as? Int`. Absent means `.default`, not key A.
- **`modifiers == 0` is the cleared sentinel.** The guardrail makes a
  zero-modifier binding unrepresentable as a valid shortcut, so zero cannot
  mean anything else. No third key is needed to distinguish "cleared" from
  "unset".

Validation runs on **read** as well as write, for the same reason `maxItems`
clamps on read: the setter only bounds what Corvo itself wrote, and a value that
arrived by `defaults write`, an MDM profile or a restored plist has to come back
sane too. A stored shift-only binding reads back as `.default` rather than
registering something that eats a letter.

## Registration

`GlobalHotkey` changes in two ways.

1. **`rebind(to: Hotkey?) -> Bool`** replaces registration-at-init. It returns
   whether `RegisterEventHotKey` succeeded; `nil` unregisters and succeeds.
2. **`InstallEventHandler` moves out of `init`** into a one-time global. Every
   instance installs another handler today. That is a latent leak while the
   shortcut is fixed and one instance is ever built; with rebinding it becomes a
   leak the user grows by using the feature.

Both sit behind a `HotkeyRegistering` protocol — the seam `PasteboardReading`
already establishes for `PasteboardMonitor` — so the refusal path can be tested
against a fake that fails on demand, rather than against whether some other app
happens to hold `⌘⇧V` on the machine running the tests.

`@Observable final class HotkeyBinder` owns the live binding and the registrar.
`AppDelegate` holds it.

## Refusing a combo that is taken

The clipboard case that motivated this feature is also its first conflict: Paste
ships with `⌘⇧V` as its default, and whichever app registers second fails.
Today that failure is one `NSLog` line no user will ever read.

On refusal the **previous shortcut stays live and nothing is stored**. The
recorder row shows the reason inline, and says what is still bound:

```
Open panel                      [ ⌘⇧V ]
⚠ ⌘⇧V is in use by another app. Still using ⌘⇧C.
```

Order is load-bearing: registration is attempted *before* `prefs.hotkey` is
written, so a refusal leaves nothing behind to reconcile. The user is never left
holding a shortcut that does nothing — the same principle as the blocklist
showing a rejected line by name instead of swallowing it.

`PreferencesView` receives two more injected closures, matching the existing
`onRetentionLowered`, so the view never imports Carbon:

```swift
let onHotkeyChange: @MainActor (Hotkey?) -> Bool   // false = registration refused
let onRecordingArmed: @MainActor (Bool) -> Void    // take the live shortcut down
```

The second is what the suspend-while-recording rule below needs; it is separate
from the first because arming is not a change to the shortcut and must not be
able to store one.

The shortcut on screen is the view's own `@State`, seeded from `prefs.hotkey` and
moved only after `onHotkeyChange` returns `true`. A refused combination therefore
never appears in the row as though it had been taken.

### Recording while a shortcut is registered

A Carbon global hotkey is dispatched ahead of application key handling. So
while the recorder is armed, pressing the combo that is *currently bound* would
toggle the panel instead of being recorded.

The binder therefore unregisters while recording is armed and re-registers when
recording finishes or is cancelled.

## The recorder view

`Sources/Corvo/UI/HotkeyRecorder.swift`, new. An `NSViewRepresentable` over a
small `NSView` subclass, because SwiftUI has no way to receive a raw key press.

Three overrides carry it:

- **`performKeyEquivalent(with:)` returns `true` while armed.** Without it every
  `⌘` combination is consumed as a key equivalent and never arrives at
  `keyDown` — the recorder would see only modifier-less keys, which are exactly
  the ones the guardrail refuses.
- **`flagsChanged`** renders modifiers as they are held, so the control reads
  `⌃⌥` before the letter lands.
- **`keyDown`** completes the recording.

`Esc` cancels and `⌫` clears the binding. Neither is recordable as a result
anyway, both failing the modifier guardrail.

States: **idle** — the current combo, or "None"; **armed** — "Type a shortcut…";
**rejected** — the old value, plus the reason.

## Settings

A new section, placed second: after "Launch at login", before "History". It is
the most-used setting in a window that currently opens on two numbers most
people set once.

```
Shortcut
  Open panel                      [ ⌘⇧V ]
  ⚠ ⌘⇧V is in use by another app. Still using ⌘⇧C.
                                  Reset to ⌘⇧V
  Opens Corvo from any app. Needs ⌘, ⌥ or ⌃.
```

It reuses the window's `notice(icon, tint, Text)` and `caption(_:)` helpers, so
the warning is a glyph and a sentence and never colour on its own — the shape
the rejected-bundle-id line and the Accessibility row already take.

"Reset to ⌘⇧V" restores the default. It is the way back for a user who records
something they cannot reach, and the alternative to that is `defaults delete`.
It goes through the same registration attempt as a recorded combo and can be
refused the same way — on a machine where another app holds `⌘⇧V`, resetting
reports that and keeps the current binding.

The value is written **on record**, not on window close. The retention numbers
defer because "5" on the way to "500" is a destructive intermediate state; a
shortcut has no such state, since `⌘⇧` on the way to `⌘⇧V` is not a binding the
guardrail lets through.

## The menu bar item

`CorvoApp.swift:15` hardcodes `.keyboardShortcut("v", modifiers: [.command, .shift])`
on "Show History". Left alone it advertises `⌘⇧V` after a rebind — a false
statement in the one place a user looks to discover the shortcut.

The `MenuBarExtra` body reads `delegate.binder.current` instead. Observation
tracking re-renders the menu when the binding changes; `@Observable` is
available at the existing macOS 14 deployment target.

Two cases show no shortcut on the item rather than a fabricated one: a cleared
binding, and a binding on a key with no single-`Character` `KeyEquivalent`
(F-keys, arrows). Carbon registration is unaffected in both — only the menu's
decoration drops.

## Tests

Swift Testing, with an isolated `UserDefaults(suiteName: UUID().uuidString)` per
the existing `makePrefs()` convention in `PreferencesTests`.

| Test | What it guards |
| --- | --- |
| Glyph order is `⌃⌥⇧⌘` then key | display never renders `⇧⌘V` |
| Bare key and `⇧`-only rejected; `⌘`, `⌥`, `⌃` accepted | the guardrail |
| Absent defaults read as `⌘⇧V` | fresh install keeps today's behaviour |
| `keyCode` 0 round-trips as the key A | the `integer(forKey:)` trap |
| `modifiers == 0` reads as `nil` | the cleared sentinel |
| Shift-only written straight to defaults reads back as `.default` | validate-on-read |
| A registrar that refuses leaves `prefs.hotkey` unchanged and the old binding live | the refusal path, with no dependency on another app |
| Rebinding twice installs one Carbon handler | the `InstallEventHandler` leak |

## Documentation

The `⌘⇧V` row in the README keyboard table gains "(default, configurable in
Settings)". The line at the top of `GlobalHotkey.swift` recommending the
`KeyboardShortcuts` package is replaced by what the file actually does.

## Prerequisite

`xcodegen` is not installed on this machine and `make build` runs
`xcodegen generate` first. `brew install xcodegen` before implementation.

## Out of scope

- Rebinding in-panel keys.
- A second global shortcut (for example, one that opens the tag manager
  directly).
- Syncing the choice between machines. Corvo has no network and this does not
  add one.
