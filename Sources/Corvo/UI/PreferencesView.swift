import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// The Settings window.
///
/// Deliberately the platform's shape rather than the panel's: a sidebar of
/// panes over grouped `Form`s, system controls, real window chrome, and no
/// keycap rail. The panel is a HUD you hold a shortcut down for and it is
/// chromeless, which is exactly why it had to grow a rail to say how to leave;
/// this is a window you open twice a year and close with ⌘W, and inventing a
/// second way out of it would be the panel cosplaying as itself.
///
/// The sidebar replaced one 520pt scroll holding all five sections. That shape
/// asked the reader to scroll past retention to find out whether Accessibility
/// was granted, and it had no way to say what any section *was* beyond a line
/// of grey text. Split up, every pane fits without scrolling and the tinted
/// glyphs carry the category — which is the arrangement System Settings itself
/// uses, so it is what the user already knows how to read.
///
/// What carries over from the panel is narrower and true. A bundle id is set in
/// mono here for the same reason a clipping is set in mono there — the shape of
/// `com.apple.Terminal` is half of recognising it — and every colour is a
/// semantic system colour or a system tint, so light and dark both come out
/// right without a second code path.
struct PreferencesView: View {
    let prefs: Preferences

    /// Registers the shortcut and reports what the system said. `false` means it
    /// was refused and nothing changed — this is the only setting in the window
    /// that can be turned down by something outside the app.
    let onHotkeyChange: @MainActor (Hotkey?) -> Bool

    /// Called when the recorder arms and disarms, so the live shortcut can come
    /// down while it is armed. Without it the one combination the user cannot
    /// record is the one already bound: a Carbon global shortcut is dispatched
    /// ahead of the app's own key handling, so pressing it would open the panel
    /// over this window instead of landing in the recorder.
    let onRecordingArmed: @MainActor (Bool) -> Void

    /// Runs the prune. Called once the user has confirmed a lower limit, so the
    /// deletion they were warned about happens while they are still looking at
    /// the screen that caused it. Deferring it to the hourly timer would not
    /// save a single clipping — it would only make them disappear later, with
    /// nothing on screen connecting the loss to the number that caused it.
    let onRetentionLowered: @MainActor () -> Void

    /// Drafts, not the stored values. A number is typed one digit at a time, and
    /// "5" on the way to "500" is a retention limit that deletes almost
    /// everything. Nothing reaches `prefs` until the field is submitted or left.
    @State private var maxItems: Int
    @State private var maxAgeDays: Int
    /// The two switches, drafts like the numbers beside them. A rule switched on is
    /// a cut and has to reach the confirmation before it reaches `prefs`.
    @State private var limitsItems: Bool
    @State private var limitsAge: Bool
    /// See `setPastesOnConfirm`.
    @State private var pastesDraft: Bool
    @State private var blocklistText: String
    @State private var loginError: String?
    @State private var isConfirmingCut = false
    /// The menu bar row, out of the body so it can be asked questions — and so it
    /// hears the writes this screen did not make. `@StateObject` because the
    /// window outlives any one body pass and the model owns the observation.
    @StateObject private var menuBarIcon: MenuBarIconModel
    /// Re-read when the app comes back to the front, because the user grants
    /// this in another application. Recomputing the body also re-reads
    /// `LoginItem`, which the user can change in the same trip.
    @State private var hasAccessibility = Paster.hasPermission
    /// The shortcut row: what it shows, and why the last attempt did not take.
    /// Seeded from `prefs` and moved only by `ShortcutEditor`, which is where the
    /// rule about refused shortcuts lives and where it is tested.
    @State private var shortcutState: ShortcutState
    @FocusState private var focus: Field?
    /// Which pane the sidebar is showing. Not persisted: the window itself is
    /// kept between openings, so the selection already survives a close — and
    /// storing it would mean a user who once opened Ignored apps lands there
    /// forever, past the pane that says whether Corvo can paste at all.
    @State private var pane: Pane = .general
    /// Shared, like the panel's gear reads it. See `UpdateModel`.
    private var updateModel: UpdateModel { .shared }

    private enum Field { case items, days }

    /// The sidebar. Each case owns its title, glyph and tint so there is one
    /// place to read the list off, rather than three lists to keep in step.
    ///
    /// The tints are system colours rather than a palette of our own: they are
    /// the ones macOS already adjusts for dark mode, for increased contrast and
    /// for the accessibility colour filters, and none of that is worth
    /// reimplementing to get a slightly different orange.
    private enum Pane: CaseIterable, Identifiable {
        case general, shortcut, history, ignored, permissions

        var id: Self { self }

        var title: LocalizedStringKey {
            switch self {
            case .general: "General"
            case .shortcut: "Shortcut"
            case .history: "History"
            case .ignored: "Ignored apps"
            case .permissions: "Permissions"
            }
        }

        var symbol: String {
            switch self {
            case .general: "gearshape.fill"
            case .shortcut: "keyboard.fill"
            case .history: "clock.arrow.circlepath"
            case .ignored: "hand.raised.fill"
            case .permissions: "lock.shield.fill"
            }
        }

        var tint: Color {
            switch self {
            case .general: .gray
            case .shortcut: .indigo
            case .history: .orange
            case .ignored: .pink
            case .permissions: .blue
            }
        }
    }

    init(prefs: Preferences,
         onHotkeyChange: @escaping @MainActor (Hotkey?) -> Bool = { _ in true },
         onRecordingArmed: @escaping @MainActor (Bool) -> Void = { _ in },
         onRetentionLowered: @escaping @MainActor () -> Void = {}) {
        self.prefs = prefs
        self.onHotkeyChange = onHotkeyChange
        self.onRecordingArmed = onRecordingArmed
        self.onRetentionLowered = onRetentionLowered
        _maxItems = State(initialValue: prefs.maxItems)
        _maxAgeDays = State(initialValue: prefs.maxAgeDays)
        _limitsItems = State(initialValue: prefs.limitsItems)
        _limitsAge = State(initialValue: prefs.limitsAge)
        _pastesDraft = State(initialValue: prefs.pastesOnConfirm)
        _blocklistText = State(initialValue: prefs.blocklist.joined(separator: "\n"))
        _menuBarIcon = StateObject(wrappedValue: MenuBarIconModel(prefs: prefs))
        _shortcutState = State(initialValue: ShortcutState(hotkey: prefs.hotkey))
    }

    var body: some View {
        NavigationSplitView {
            List(Pane.allCases, selection: $pane) { pane in
                row(pane)
            }
            .navigationSplitViewColumnWidth(190)
            // There is nothing to collapse to. Hiding the sidebar in a window
            // whose entire navigation *is* the sidebar leaves a pane with no way
            // back, and macOS puts the button there by default.
            .toolbar(removing: .sidebarToggle)
        } detail: {
            detail
                // The window title follows the pane, which is what System
                // Settings does and what makes the title bar say something
                // other than the app's own name twice.
                .navigationTitle(Text(pane.title))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // The size lives here and `SettingsWindow` reads it back off the hosting
        // view, so the window and the content cannot disagree — which they did,
        // as 460 against 420.
        //
        // The height is the tallest pane's, measured rather than picked: Ignored
        // apps comes to about 240pt with the editor, the button and both notes
        // showing. Every pane shares one window, so the rest have space under
        // them — that is what a sidebar costs, and 460 spent it twice over.
        // A pane that does outgrow this scrolls; `Form` already does that.
        .frame(width: 640, height: 380)
        // Both retention fields format *and parse* through this, and the
        // confirmation's `^[…](inflect: true)` agrees its grammar against it.
        // Left alone on a pt-BR machine the field reads "1.000" and the alert
        // inflects in Portuguese, inside a window whose every word is English.
        .environment(\.locale, .app)
        .onChange(of: focus) { _, now in
            guard now == nil else { return }
            commitRetention()
        }
        .onDisappear { commitOnClose() }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            hasAccessibility = Paster.hasPermission
        }
        .alert("Delete clippings now?", isPresented: $isConfirmingCut) {
            // The alert is reached by pressing Return in the number field
            // (`onSubmit`), so Return has to land on the safe button here too —
            // otherwise two Returns in a row confirm an irreversible deletion
            // the user never read. `.cancel` already gets Escape; `.defaultAction`
            // is what claims Return.
            Button("Cancel", role: .cancel) { revertRetention() }
                .keyboardShortcut(.defaultAction)
            Button("Delete", role: .destructive) { applyCut() }
        } message: {
            cutMessage
        }
        .alert("Hide the menu bar icon?", isPresented: $menuBarIcon.isConfirmingHide) {
            // No `role: .destructive` and no `.defaultAction` on Cancel: nothing
            // is deleted here and nothing is lost, so the confirmation exists to
            // hand over the two routes back, not to talk anyone out of it. Hide
            // is the default button because it is what the user just asked for.
            Button("Cancel", role: .cancel) {}
            Button("Hide") { menuBarIcon.confirmHide() }
        } message: {
            // Both routes, because either one alone leaves a hole: the shortcut
            // opens the history but never Settings, and the reopen never shows
            // the history. Named as the things the user does, not as the
            // mechanisms — "open Corvo again" is a Finder double-click, a
            // Spotlight hit or a Dock alias, and all three land in the same
            // place.
            //
            // Settings is the only destination named. Bringing the icon back is
            // something you do *in* Settings, so saying both made one trip sound
            // like two.
            hideMessage
        }
    }

    // MARK: - Sidebar

    /// One sidebar row: a tinted glyph tile and the pane's name.
    ///
    /// The tile is a `Label` icon rather than a hand-placed `HStack` so the row
    /// keeps the sidebar's own spacing, selection highlight and hit area — and
    /// so VoiceOver reads it as one thing with the title, not as an image
    /// followed by a word.
    private func row(_ pane: Pane) -> some View {
        Label {
            Text(pane.title)
        } icon: {
            Image(systemName: pane.symbol)
                // Fixed size rather than a text style: these sit inside a tile
                // that does not grow, and a glyph scaled up by the system text
                // size would clip out of it.
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(pane.tint.gradient, in: RoundedRectangle(cornerRadius: 5))
        }
        .padding(.vertical, 1)
    }

    // MARK: - Panes

    /// Each pane is its own `Form`, so a section keeps the grouped inset look it
    /// had when all five shared one.
    @ViewBuilder private var detail: some View {
        switch pane {
        case .general: Form { startup }.formStyle(.grouped)
        case .shortcut: Form { shortcut }.formStyle(.grouped)
        case .history: Form { history }.formStyle(.grouped)
        case .ignored: Form { ignoredApps }.formStyle(.grouped)
        case .permissions: Form { permissions }.formStyle(.grouped)
        }
    }

    /// The routes back, named as the ones that actually exist right now.
    ///
    /// The shortcut is read from `shortcutState` rather than written out,
    /// because it is the user's to change: a sentence saying ⌘⇧V is a sentence
    /// that goes stale the moment they rebind, in the place they were sent to
    /// find out how to get back. And it can be cleared entirely — with no icon
    /// and no shortcut there is one route left, not two, and promising a key
    /// press that does nothing is worse than saying so.
    @ViewBuilder private var hideMessage: some View {
        if let shortcut = shortcutState.hotkey {
            Text("""
                Corvo keeps running and \(shortcut.display) still opens the history. \
                To get Settings back open Corvo again from the Applications folder.
                """)
        } else {
            Text("""
                Corvo keeps running, but with no icon and no shortcut there is \
                nothing left that opens the history. Open Corvo again from the \
                Applications folder to get Settings back, and set a shortcut there.
                """)
        }
    }

    /// Names the rules that will actually apply, which is now three sentences
    /// rather than one.
    ///
    /// The old message named both rules unconditionally. With a rule switched off
    /// that would describe a deletion that is not going to happen — and the number
    /// it quoted would be one the user can see is dimmed on the screen behind the
    /// alert.
    ///
    /// Both-off never gets here: nothing is being cut, so `commitRetention` writes
    /// it without asking.
    @ViewBuilder private var cutMessage: some View {
        if limitsItems, limitsAge {
            Text("""
                Corvo will keep the newest ^[\(maxItems) clipping](inflect: true) \
                and delete anything older than ^[\(maxAgeDays) day](inflect: true). \
                Pinned and tagged clippings are never deleted. Corvo has no undo.
                """)
        } else if limitsItems {
            Text("""
                Corvo will keep the newest ^[\(maxItems) clipping](inflect: true), \
                whatever their age. Pinned and tagged clippings are never deleted. \
                Corvo has no undo.
                """)
        } else {
            Text("""
                Corvo will delete anything older than \
                ^[\(maxAgeDays) day](inflect: true), however few are left. Pinned \
                and tagged clippings are never deleted. Corvo has no undo.
                """)
        }
    }

    // MARK: - Startup

    private var startup: some View {
        Section {
            Toggle("Launch at login", isOn: launchAtLogin)
            if LoginItem.needsApproval {
                notice("exclamationmark.triangle.fill", .orange,
                       Text("Registered, but switched off in System Settings."))
                Button("Open Login Items") { LoginItem.openSystemSettings() }
                    .controlSize(.small)
            }
            if let loginError {
                notice("exclamationmark.triangle.fill", .red,
                       Text("macOS refused the change: \(loginError)"))
            }
            Toggle("Paste into the app you came from", isOn: pastesOnConfirm)
            if pastesDraft, !hasAccessibility {
                // The one setting in this window whose promise another screen
                // can break. Saying so here is cheaper than the user finding out
                // by pressing ⏎ and watching nothing arrive.
                notice("exclamationmark.triangle.fill", .orange,
                       Text("Needs Accessibility permission, which is not granted yet."))
            }
            caption(pastesDraft
                    ? "⏎ and a double-click press ⌘V for you in the app you were last in."
                    : "⏎ and a double-click put the clipping on your clipboard, and you paste it. ⌘C does the same.")
            Toggle("Show icon in menu bar", isOn: showsMenuBarIcon)
            if !menuBarIcon.isShown {
                // Not a warning: the user asked for this and Corvo is working
                // exactly as told. It is on screen because the alert that said it
                // is gone, and this is the one screen that can still say it —
                // reached, by then, the way the sentence describes.
                if let shortcut = shortcutState.hotkey {
                    caption("Corvo is running with no icon. \(shortcut.display) opens the history; opening Corvo again opens Settings.")
                } else {
                    caption("Corvo is running with no icon and no shortcut. Opening Corvo again opens Settings.")
                }
            }
            updates
        }
    }

    // MARK: - Updates

    /// The one place in the app that turns a network connection on and off, so
    /// the caption says what is sent rather than leaving the user to wonder.
    @ViewBuilder private var updates: some View {
        Toggle("Check for updates", isOn: checksForUpdates)
        LabeledContent {
            updateAction
        } label: {
            updateStatus
        }
        caption("Asks GitHub once a day whether a newer release exists. No clipping and nothing that identifies you is sent.")
        if case .available = updateModel.state {
            // Said before it happens, not after. Corvo has to quit for its own
            // bundle to be replaced, and an app that vanishes with no warning
            // reads as a crash.
            caption("Updating quits Corvo and opens it again. macOS may ask for Accessibility permission afterwards: the new build is a different binary as far as it is concerned.")
        }
    }

    /// Written out rather than passed as a method reference, for the reason
    /// given on `launchAtLogin`: Swift 6.1's IRGen crashes building the
    /// isolation thunk for a `@MainActor` method handed to `Binding`'s
    /// non-isolated `set`.
    private var checksForUpdates: Binding<Bool> {
        Binding(get: { prefs.checksForUpdates }, set: { setChecksForUpdates($0) })
    }

    private func setChecksForUpdates(_ enabled: Bool) {
        prefs.checksForUpdates = enabled
        updateModel.checkIfEnabled(prefs: prefs)
    }

    @ViewBuilder private var updateStatus: some View {
        switch updateModel.state {
        case .available(let release):
            notice("arrow.down.circle.fill", .blue,
                   Text("Corvo \(release.version) is available. You have \(AppVersion.current)."))
        case .checking:
            caption("Checking…")
        case .upToDate:
            notice("checkmark.circle.fill", .green,
                   Text("Corvo \(AppVersion.current) is the newest release."))
        case .failed:
            // Not a warning glyph. Nothing is wrong with Corvo, and there is
            // nothing for the user to fix — the check simply did not complete.
            caption("Could not reach GitHub. Corvo \(AppVersion.current).")
        case .idle:
            caption("Corvo \(AppVersion.current).")
        }
    }

    /// The same action the panel's Update button runs, so the two cannot come to
    /// mean different things by the same word. What it does depends on the
    /// install — see `UpdateModel.install()`.
    @ViewBuilder private var updateAction: some View {
        switch updateModel.state {
        case .available:
            Button("Update") { updateModel.install() }
                .controlSize(.small)
        default:
            Button("Check now") { updateModel.check() }
                .controlSize(.small)
                .disabled(!prefs.checksForUpdates)
        }
    }

    /// Reads and writes `MenuBarIconModel`, which is where both the decision and
    /// the stored value live — see that type for why the row cannot simply read
    /// `prefs` the way `launchAtLogin` reads `LoginItem`.
    ///
    /// Written out rather than passed as a method reference for the reason given
    /// on `launchAtLogin`: Swift 6.1's IRGen crashes building the isolation thunk
    /// for a `@MainActor` method handed to `Binding`'s non-isolated `set`.
    /// Written out rather than passed as a method reference, for the reason
    /// given on `launchAtLogin`: Swift 6.1's IRGen crashes building the
    /// isolation thunk for a `@MainActor` method handed to `Binding`'s
    /// non-isolated `set`.
    private var pastesOnConfirm: Binding<Bool> {
        Binding(get: { pastesDraft }, set: { setPastesOnConfirm($0) })
    }

    /// Mirrored into `@State` and written through, rather than read from `prefs`
    /// in the body. `Preferences` is a typed view onto `UserDefaults` and
    /// announces nothing, so a body reading it directly would draw the caption
    /// for the setting that was there a moment ago — the exact failure
    /// `MenuBarIconModel` was built to stop for the row two lines down.
    private func setPastesOnConfirm(_ enabled: Bool) {
        pastesDraft = enabled
        prefs.pastesOnConfirm = enabled
    }

    private var showsMenuBarIcon: Binding<Bool> {
        Binding(get: { menuBarIcon.isShown }, set: { menuBarIcon.request($0) })
    }

    /// Reads the system on every pass instead of mirroring it into `@State`.
    ///
    /// That mirror is the bug this avoids: when `register()` throws, a mirrored
    /// toggle is left on while the system is off, and the fix — writing the real
    /// state back inside the change handler — re-enters the same handler and can
    /// sit there flipping. With no copy there is nothing to drift. A failure
    /// sets `loginError`, the body recomputes, and the switch shows what the
    /// system actually did.
    /// Both closures are written out rather than passed as method references:
    /// Swift 6.1's IRGen crashes building the isolation thunk for a `@MainActor`
    /// method handed to `Binding`'s non-isolated `set`.
    private var launchAtLogin: Binding<Bool> {
        Binding(get: { LoginItem.isEnabled }, set: { setLaunchAtLogin($0) })
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try LoginItem.setEnabled(enabled)
            loginError = nil
        } catch {
            loginError = error.localizedDescription
        }
    }

    // MARK: - Shortcut

    /// Placed second, ahead of retention: it is the setting people come here to
    /// change, and the two retention numbers are set once.
    private var shortcut: some View {
        Section {
            LabeledContent("Open panel") {
                HotkeyRecorder(hotkey: shortcutState.hotkey,
                               onArmedChange: onRecordingArmed,
                               onRecording: record)
            }
            if let refusal = shortcutState.refusal {
                notice("exclamationmark.triangle.fill", .orange, refusalText(refusal))
            }
            if shortcutState.hotkey != Hotkey.default {
                // The way back for someone who recorded something they cannot
                // reach. Without it that is a `defaults delete`, which is not a
                // thing to ask of anyone.
                HStack(spacing: 0) {
                    Button("Reset to ⌘⇧V") { record(.recorded(.default)) }
                        .controlSize(.small)
                    Spacer(minLength: 0)
                }
            }
            caption("Opens Corvo from any app. Needs ⌘, ⌥ or ⌃.")
        }
    }

    /// Written the moment it is typed, unlike the retention numbers below.
    ///
    /// They defer because "5" on the way to "500" is a limit that would delete
    /// almost everything. A shortcut has no such half-state: `⌘⇧` on the way to
    /// `⌘⇧V` is not something `HotkeyRule` would let through, and the recorder
    /// only reports a whole key press.
    private func record(_ recording: HotkeyRecording) {
        shortcutState = ShortcutEditor.apply(recording, to: shortcutState,
                                             register: onHotkeyChange)
    }

    /// The only part of the refusal that belongs to the screen: its wording.
    private func refusalText(_ refusal: ShortcutRefusal) -> Text {
        switch refusal {
        case .needsModifier(let hotkey):
            Text("\(hotkey.display) needs ⌘, ⌥ or ⌃ — otherwise it would be swallowed everywhere.")
        case .inUse(let hotkey, let current):
            if let current {
                Text("\(hotkey.display) is in use by another app. Still using \(current.display).")
            } else {
                Text("\(hotkey.display) is in use by another app. Still no shortcut.")
            }
        }
    }

    // MARK: - History

    private var history: some View {
        Section {
            rule("Keep at most", isOn: $limitsItems, value: $maxItems,
                 field: .items, unit: "clippings")
            rule("Delete after", isOn: $limitsAge, value: $maxAgeDays,
                 field: .days, unit: "days")

            if limitsItems || limitsAge {
                caption("Pinned or tagged clippings never expire, and do not count towards the limit.")
            } else {
                // Not a warning glyph: nothing is wrong. It is a consequence, and
                // the user chose it — they are entitled to a clipboard that keeps
                // everything, and entitled to know that is what they now have.
                caption("Nothing is ever deleted. The history grows until you delete clippings yourself.")
            }
        }
    }

    /// One retention rule: a switch, a number, and the unit the number is in.
    ///
    /// The number stays on screen when the rule is off, dimmed and not editable.
    /// Emptying the field instead would throw away the value the user picked, and
    /// it is exactly the value that comes back when they switch the rule on again.
    private func rule(_ label: LocalizedStringKey, isOn: Binding<Bool>,
                      value: Binding<Int>, field: Field,
                      unit: LocalizedStringKey) -> some View {
        LabeledContent {
            HStack(spacing: 6) {
                numberField(label, value: value, field: field)
                    .disabled(!isOn.wrappedValue)
                Text(unit)
                    .foregroundStyle(.secondary)
                Toggle(label, isOn: isOn)
                    .labelsHidden()
                    // A `Toggle` in a `LabeledContent`'s trailing content loses
                    // the switch style a `Form` row normally gives it and comes
                    // out as a checkbox — beside the two real switches one pane
                    // over, that read as a different kind of setting.
                    .toggleStyle(.switch)
                    // Committed the moment it moves, unlike the number beside it: a
                    // switch has no half-typed state to protect, and leaving it
                    // uncommitted would mean the confirmation for switching a rule
                    // on could arrive long after the click that asked for it.
                    .onChange(of: isOn.wrappedValue) { _, _ in commitRetention() }
            }
        } label: {
            Text(label).foregroundStyle(isOn.wrappedValue ? .primary : .secondary)
        }
    }

    private func numberField(_ label: LocalizedStringKey, value: Binding<Int>,
                             field: Field) -> some View {
        // `.locale(.app)` as well as the environment locale on the `Form`, and
        // both are load-bearing: a `TextField`'s parseable style keeps the
        // locale it was built with, while `Text` re-resolves against the
        // environment. Either one alone leaves half the window in the wrong
        // language — the field showed "1.000" with only the environment set.
        TextField(label, value: value, format: .number.locale(.app))
            .labelsHidden()
            .multilineTextAlignment(.trailing)
            .monospacedDigit()
            .frame(width: 64)
            .focused($focus, equals: field)
            .onSubmit { commitRetention() }
    }

    // MARK: - Ignored apps

    private var ignoredApps: some View {
        Section {
            TextEditor(text: $blocklistText)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .frame(height: 84)
                .padding(.horizontal, 5)
                .padding(.vertical, 4)
                .background(Color(nsColor: .textBackgroundColor),
                            in: RoundedRectangle(cornerRadius: 6))
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.primary.opacity(0.12))
                }
                // Committed on every keystroke, unlike the numbers above, and
                // for the opposite reason: a half-typed bundle id blocks nothing
                // and destroys nothing, while a bundle id lost because the field
                // still had focus when the window closed is an app the user
                // believes is blocked and is not.
                .onChange(of: blocklistText) { _, text in
                    prefs.blocklist = Blocklist.entries(text)
                }
                .accessibilityLabel("Ignored apps, one bundle ID per line")

            HStack(spacing: 0) {
                Button("Add app…") { addApp() }
                    .controlSize(.small)
                Spacer(minLength: 0)
            }

            if !rejected.isEmpty {
                // Quoted, not bare: one of the ways to get this wrong is to put
                // two ids on one line, and a comma-joined list of lines that may
                // themselves contain commas cannot be read back.
                //
                // Not "ignored", either — in a section called "Ignored apps"
                // that word already means blocked, and this line means the
                // opposite.
                notice("exclamationmark.triangle.fill", .orange,
                       Text("Blocks nothing — not a bundle ID: \(quoted(rejected))"))
            }
            caption("One bundle ID per line. Nothing copied in these apps is kept.")
        }
    }

    private var rejected: [String] { Blocklist.parse(blocklistText).rejected }

    private func quoted(_ lines: [String]) -> String {
        lines.map { "“\($0)”" }.joined(separator: ", ")
    }

    /// Picking the app is the point. A bundle id is not something anyone knows
    /// by heart, and a privacy control that most people fill in wrong is not a
    /// control — so the id comes out of the chosen bundle rather than out of the
    /// user's memory. Typing one by hand still works; this is the path that
    /// cannot be typo'd.
    private func addApp() {
        let picker = NSOpenPanel()
        picker.allowedContentTypes = [.applicationBundle]
        picker.allowsMultipleSelection = true
        picker.directoryURL = URL(fileURLWithPath: "/Applications")
        picker.prompt = String(localized: "Ignore")
        // Corvo is an accessory app (`LSUIElement`), so it is not necessarily
        // the active application even with its own window in front. Without
        // this the picker can open behind everything.
        NSApp.activate()
        guard picker.runModal() == .OK else { return }

        let existing = Set(Blocklist.parse(blocklistText).accepted)
        let added = picker.urls
            .compactMap(AppChooser.bundleId(forApplicationAt:))
            .filter { !existing.contains($0) }
        guard !added.isEmpty else { return }

        let lines = blocklistText.isEmpty ? added : [blocklistText] + added
        blocklistText = lines.joined(separator: "\n")
    }

    // MARK: - Permissions

    private var permissions: some View {
        Section {
            LabeledContent {
                Button("Open Settings") { Paster.openAccessibilitySettings() }
                    .controlSize(.small)
            } label: {
                notice(hasAccessibility ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                       hasAccessibility ? .green : .orange,
                       Text(hasAccessibility ? "Accessibility granted" : "Accessibility pending"))
            }
            caption("Without it, Corvo copies but does not paste for you.")
        }
    }

    // MARK: - Committing the limits

    /// Both numbers are written together, because retention enforces both
    /// together: the alert names both, so committing only the field the user
    /// last touched would enforce a pair they were never shown.
    private func commitRetention() {
        maxItems = Preferences.clamped(maxItems, to: Preferences.itemLimits)
        maxAgeDays = Preferences.clamped(maxAgeDays, to: Preferences.ageLimits)
        guard RetentionEdit.isCut(from: storedRetention, to: draftRetention) else {
            writeRetention()
            return
        }
        isConfirmingCut = true
    }

    /// What is being enforced right now.
    private var storedRetention: RetentionSettings {
        RetentionSettings(maxItems: prefs.maxItems, maxAgeDays: prefs.maxAgeDays,
                          limitsItems: prefs.limitsItems, limitsAge: prefs.limitsAge)
    }

    /// What the screen is showing, which is not the same thing until it is
    /// committed.
    private var draftRetention: RetentionSettings {
        RetentionSettings(maxItems: maxItems, maxAgeDays: maxAgeDays,
                          limitsItems: limitsItems, limitsAge: limitsAge)
    }

    private func writeRetention() {
        prefs.maxItems = maxItems
        prefs.maxAgeDays = maxAgeDays
        prefs.limitsItems = limitsItems
        prefs.limitsAge = limitsAge
    }

    private func applyCut() {
        writeRetention()
        onRetentionLowered()
    }

    private func revertRetention() {
        maxItems = prefs.maxItems
        maxAgeDays = prefs.maxAgeDays
        limitsItems = prefs.limitsItems
        limitsAge = prefs.limitsAge
    }

    /// A window can be closed with a field still focused and the edit never
    /// submitted. Raising a limit is safe to keep without asking; a cut is not,
    /// and an alert cannot follow a window that is already going away. Dropping
    /// the unconfirmed cut is the failure mode that deletes nothing — including,
    /// in a mixed edit, a raise sitting in the other field. That is the safe
    /// direction and is left as is; it just means "writes the raise" is not an
    /// accurate description of the mixed case.
    private func commitOnClose() {
        // `isConfirmingCut` outlives this call otherwise: a `Settings` scene
        // keeps its `@State` across close/open, so a flag left `true` here
        // would present an unasked-for "Delete clippings now?" the next time
        // the window opens.
        isConfirmingCut = false
        // The same question `commitRetention` asks, so a rule switched on and left
        // unconfirmed is dropped exactly like a lowered number is.
        guard !RetentionEdit.isCut(from: storedRetention, to: draftRetention) else {
            revertRetention()
            return
        }
        // Only write when a draft actually differs from what is stored —
        // otherwise opening and closing the window with nothing touched turns
        // "unset, falls back to `RetentionPolicy.standard`" into a pinned
        // `1000`/`30` that a future change to the standard policy can never
        // reach.
        guard draftRetention != storedRetention else { return }
        writeRetention()
    }

    // MARK: - Pieces

    /// The one shape a status line takes in this window. Colour is never the
    /// carrier on its own — every one of these has a glyph and a sentence.
    private func notice(_ icon: String, _ tint: Color, _ text: Text) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: icon).foregroundStyle(tint)
            text.frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.caption)
        .accessibilityElement(children: .combine)
    }

    private func caption(_ key: LocalizedStringKey) -> some View {
        Text(key)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
