<div align="center">

# 🐦‍⬛ Corvo

**A clipboard history for macOS that remembers where things came from.**

Press `⌘⇧V`, pick a clipping, press `⏎`, and it is on your clipboard. Switch on
one setting and `⏎` puts it straight back into whatever you were typing in
instead.

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black)
![Swift 6](https://img.shields.io/badge/Swift-6-orange)
![AGPL-3.0](https://img.shields.io/badge/license-AGPL--3.0-blue)

</div>

---

A corvo is a raven: a bird that hoards small bright things and remembers where
it put them. The app does the same with your clipboard. It lives in the menu
bar, has no Dock icon, and the only thing it ever sends over the network is a
daily question to GitHub about whether a newer release exists — which you can
switch off.

## What it does

| | |
| --- | --- |
| **Keeps everything you copy** | Text, images and files, captured in the background |
| **Remembers the source app** | Every clipping carries the app it came from, with its icon and brand colour |
| **Colours code like an editor** | `curl`, JSON and C-family snippets are syntax-highlighted in the card |
| **Tags that apply themselves** | A tag can carry a regex and/or a source app, and catches matching clippings on its own |
| **Asks what to call things** | A rule tag can ask you to name what it catches, in a notification you type into |
| **Pastes straight back** | Switch it on and `⏎` returns the clipping to the app you were in, no manual `⌘V` |
| **Drops secrets on the floor** | Content marked concealed by password managers is never recorded |

## Install

```sh
brew tap Wylp/corvo https://github.com/Wylp/Corvo
brew install --cask corvo
```

The cask lives in this repository, which is why `brew tap` comes first — Corvo
is not in homebrew/cask.

### The build is not notarized, and the cask opens it anyway

Corvo is ad-hoc signed: not signed with a Developer ID and not notarized by
Apple. Nobody has vouched for the binary, and macOS has a way of telling you
so — Homebrew flags what it downloads with `com.apple.quarantine`, and
Gatekeeper reads that flag to refuse the first launch of anything it cannot
verify.

**The cask removes that flag after installing.** So the app opens, with no trip
through System Settings, and the warning that would have told you the binary is
unverified does not appear. That is the trade, and it is made for you at install
time, which is why it is written here rather than left to be discovered.

If you would rather keep the check, build from source — [the build is
below](#build-from-source), and the result is the same app. Or install it by
hand from the [release zip](https://github.com/Wylp/Corvo/releases/latest),
which keeps the quarantine flag and the "Open Anyway" step with it.

The real fix is notarization, which would make the flag harmless instead of
something to strip. It needs an Apple Developer Program membership, and it is
also what would stop each upgrade from resetting the Accessibility permission —
see below.

### Accessibility permission

**Only needed if you switch pasting on.** By default `⏎` puts the clipping on
your clipboard and you place it yourself, which needs no permission at all —
see [Keyboard](#keyboard) below.

With pasting on, the first time you press `⏎` Corvo tells you the permission is
missing and offers to open **System Settings → Privacy & Security →
Accessibility**. Switch Corvo on there and press it again.

It needs the permission to press `⌘V` for you in the app you came from; there is
no other way for one app to type into another. Without it Corvo still works, it
just stops one step short: the clipping goes onto your clipboard and Corvo tells
you so, and you paste it yourself. Capture, search, tags and pinning need no
permission at all.

**An upgrade can quietly take it away.** An ad-hoc signed app has no stable
identity, so replacing the bundle — `brew upgrade`, or a new copy dragged in —
produces a binary macOS treats as a different app. The Accessibility list goes
on showing Corvo switched on while the permission no longer applies to what is
actually running, and pasting stops working with nothing on screen explaining
why. Corvo says so when it happens; the remedy is to select Corvo in that list,
remove it with the **−** button, then add it again.

This is the second thing notarization would fix: a Developer ID gives the app a
stable team identifier, and the permission survives the upgrade.

### Hiding the menu bar icon

**Settings → Show icon in menu bar** takes Corvo's icon out of the menu bar.
⌘-dragging the icon out of the menu bar does the same thing, and is remembered
the same way.

Corvo keeps running with the icon gone, and your shortcut still opens the panel
— but the menu is where Settings and Quit live, so with no icon there is one way
back:

**Open Corvo again** — from the Applications folder, Spotlight, anywhere. The
copy already running answers by opening Settings, where the switch is. Launching
it twice never gives you two Corvos.

## Keyboard

The panel is a keyboard tool. Every shortcut is printed along its bottom edge,
so you never have to remember this table.

| Key | Does |
| --- | --- |
| `⌘⇧V` | Open the panel, from anywhere — the default, changeable in Settings |
| `←` `→` | Move through the carousel |
| `⇧`-click | Select every clipping between this one and the last |
| `⇧←` `⇧→` | The same, one clipping at a time |
| `⏎` | Copy the clipping — or paste it into the app you came from, if that is switched on |
| `⌘C` | Copy to the clipboard, whichever `⏎` is set to do |
| `⌘R` | Name the selected clipping (empty the field to remove the name) |
| `⌘T` | Tag the selected clipping |
| `⌘⇧T` | Open the tag manager |
| `⌘P` | Pin / unpin |
| `⌘⌫` | Delete the clipping |
| `⌘,` | Settings — the gear in the search row does the same |
| `Esc` | Close the panel |

Hold `⇧` and click to take several clippings at once, from the last one you
touched to the one you click. `⏎` or `⌘C` then act on all of them: text arrives
joined by newlines in list order, and a run of files arrives as several files.
`⇧←` and `⇧→` do the same from the keyboard, and any plain click or bare arrow
drops the run again.

Typing goes straight to the search box, which matches the clipping's content
**and** the name of the app it came from — so `slack` finds everything you
copied out of Slack without touching the sidebar.

### Changing the shortcut

`⌘⇧V` is the default and the one thing another clipboard manager is likely to
already hold. **Settings → Shortcut** rebinds it: click the shortcut, type the
one you want, and it takes effect immediately. `⌫` clears it, which leaves the
menu bar item as the only way to open the panel.

It needs `⌘`, `⌥` or `⌃` — `⇧` alone is how you type a capital letter, and a
global shortcut on `⇧V` would swallow the key in every app you use.

If another app already holds the combination you typed, macOS refuses it. Corvo
keeps the shortcut you had, and says so under the row.

## Tags that apply themselves

A tag is not just a label. It can carry a **rule**, and a tag with a rule tags
matching clippings on its own, as they are captured.

A rule is a regular expression, a source app, or both together. With both, they
must both match.

Tagged clippings are also **exempt from retention**: they never expire and do
not count towards the history limit. So are clippings you have named with `⌘R`.
Tagging or naming is how you say "keep this".

### Worked example: naming your Claude Code sessions

Resuming a Claude Code session means copying a command with a UUID in it:

```
claude --resume 550e8400-e29b-41d4-a716-446655440000
```

The UUID tells you nothing. A week later you have eleven of them and no idea
which one was the auth refactor. This is the case Corvo's rule tags were built
for.

Open the panel with `⌘⇧V`, press `⌘⇧T` for the tag manager, then `⌘N` for a new
tag:

| Field | Value |
| --- | --- |
| **Name** | `claude` |
| **Pattern** | `claude --resume` |
| **From app** | *Any app* — or your terminal, if you only ever copy it there |
| **Ask me to name what it catches** | on |
| **Colour** | whichever you like — it tints the tag in the sidebar |

As you type the pattern, the editor tells you whether it compiles and **how many
clippings you already have that it would catch**, with a sample. That number is
the fastest way to know a regex does what you meant, before it is ever saved.

From then on, every resume command you copy arrives already tagged, and Corvo
asks you what to call it — "auth refactor", "the migration one". The name is
searchable, so `⌘⇧V` and typing `auth` brings back the command that resumes it.

The question arrives as a **notification with a text field in it**: type the name
into the banner and press Save. No window opens and nothing takes your focus, so
you can answer it or ignore it. Ignoring it costs nothing — the clipping is
already saved and already tagged, and its card says **Name this (⌘R)** until you
give it one. Copy ten matching things in a row and you get one notification for
the most recent, not ten stacked up.

Corvo asks for notification permission the first time a rule actually catches
something it wants named, not at launch. Say no, or never see the banner, and
naming still works: open the panel and press `⌘R` on the card.

Because tagged clippings never expire, those sessions stay findable no matter
how much you copy over them.

If you want the rule applied to the history you already have, use **Apply to
existing…** — it tells you how many clippings will be tagged and asks first,
because Corvo has no undo.

### A few more rules worth stealing

| Goal | Pattern | From app |
| --- | --- | --- |
| Everything copied out of Figma, images included | *(none)* | Figma |
| Private keys and certs you copy as files | `\.(pem\|key\|crt)$` | *Any app* |
| `TODO` and `FIXME` you lift out of code | `\b(TODO\|FIXME)\b` | *Any app* |
| Git SHAs | `\b[0-9a-f]{7,40}\b` | *Any app* |

A source-only rule ignores text entirely, so it catches images and files from
that app too. A pattern rule sees the text of a text clipping and the *filename*
of a file clipping; it never sees an image, so a loose pattern will not swallow
every screenshot you take.

## Privacy

**The history is not encrypted.** It is a plain SQLite database at
`~/Library/Application Support/Corvo/corvo.sqlite`, with copied images stored as
files beside it in `blobs/`. Anything with read access to your home directory —
another app you run, a backup, someone at your unlocked machine — can read every
clipping. Decide with that in mind.

Copied *files* are kept by reference: Corvo stores the path, never a copy of the
contents.

Two things keep secrets out:

- **Concealed and transient content is discarded.** Password managers mark what
  they put on the clipboard with `org.nspasteboard.ConcealedType`, and Corvo
  drops those copies without recording them. `TransientType` is dropped the same
  way. This depends on the source app doing the marking — an app that does not
  is not covered.
- **A blocklist of apps.** In Settings, list the bundle identifiers whose
  clippings are never recorded at all.

Because tagged clippings never expire, think twice before writing a rule that
tags credentials: it would keep them forever, in a database that is not
encrypted.

**One connection leaves your machine, and you can switch it off.** Once a day
Corvo asks GitHub's release API whether a newer version exists. It is a plain
GET at a fixed URL that carries no clipping, no identifier and no account — the
only thing it says about you is the version you are running, in the `User-Agent`
header the API requires. **Settings → General → Check for updates** turns it
off, and with it off Corvo opens no network connection at all.

Corvo never installs anything **on its own**. When a release exists, an
**Update** button appears beside the gear in the panel — only then — and
pressing it runs the upgrade. Nothing happens until you press it.

What it runs depends on how Corvo got here. Installed through Homebrew, it
quits Corvo, runs `brew upgrade --cask corvo` and opens it again; the app has
to be gone for its own bundle to be replaced, so it disappears for a few
seconds on purpose. Installed by hand from the zip, there is no package manager
to ask, and the button opens the release page instead.

Expect macOS to want Accessibility permission again afterwards. An ad-hoc
signed app has no stable identity, so the upgraded binary is a different app as
far as the permission system is concerned — see
[above](#accessibility-permission).

There is no account and no sync.

By default the history keeps **1000 clippings for 30 days**. Both numbers are
adjustable in Settings, and each rule has its own switch, so you can keep a count
ceiling with no expiry, an expiry with no ceiling, both, or neither:

| Keep at most | Delete after | What you get |
| --- | --- | --- |
| on | on | whichever rule bites first — the default |
| on | off | a fixed-size history, at any age |
| off | on | clippings expire, however many there are |
| off | off | nothing is ever deleted |

The count ceiling is enforced as you copy, not on a timer: hit the limit and the
oldest clipping goes immediately. Switching a rule off keeps its number, so
switching it back on restores what you chose — and because turning a rule on can
delete a lot at once, Corvo asks first. With both off nothing is ever deleted and
the history grows until you delete clippings yourself.

Pinned, tagged and named clippings are exempt from all of it.

## Not yet

Honest list of what the tag editor exposes or what people ask for, and what is
not built:

- **Sync between machines**, OCR on images, a snippet editor, encryption of the
  history at rest.

## Build from source

`Corvo.xcodeproj` is generated by XcodeGen and is not committed, so you need
XcodeGen to build:

```sh
brew install xcodegen
make build     # Debug build
make test      # the test suite
make run       # build and launch, replacing any running copy
make release   # build/Corvo.zip, the release artifact
```

Everything lands under `build/`, including the Debug build. Xcode would
otherwise derive that location from the project's path, which gives every git
worktree its own — and `make run` would launch every copy it could find.

The only runtime dependency is [GRDB.swift](https://github.com/groue/GRDB.swift),
resolved by Swift Package Manager.

To publish a release, tag it and push — `.github/workflows/release.yml` builds
the zip and attaches it to the GitHub release. The cask's `sha256` then comes
from:

```sh
curl -sL https://github.com/Wylp/Corvo/releases/download/v0.1.0/Corvo.zip | shasum -a 256
```

Paste that digest into `Casks/corvo.rb` and bump `version`.

## Translations

Corvo is written in English. Translations are welcome via
`Sources/Corvo/Resources/Localizable.xcstrings` — open it in Xcode's String
Catalog editor. Brazilian Portuguese is registered and currently empty, so a
pt-BR machine shows English until someone fills it in.

## License

[GNU AGPL-3.0](LICENSE). If you run a modified Corvo as a network service, the
AGPL requires you to offer your users its source.
