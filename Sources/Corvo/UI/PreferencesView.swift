import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// The Settings window.
///
/// Deliberately the platform's shape rather than the panel's: a grouped `Form`
/// in the `Settings` scene, system controls, real window chrome, and no keycap
/// rail. The panel is a HUD you hold a shortcut down for and it is chromeless,
/// which is exactly why it had to grow a rail to say how to leave; this is a
/// window you open twice a year and close with ⌘W, and inventing a second way
/// out of it would be the panel cosplaying as itself.
///
/// What does carry over is narrower and true. A bundle id is set in mono here
/// for the same reason a clipping is set in mono there — the shape of
/// `com.apple.Terminal` is half of recognising it — and every colour is a
/// semantic system colour, so light and dark both come out right without a
/// second code path.
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
    @State private var blocklistText: String
    @State private var loginError: String?
    @State private var isConfirmingCut = false
    /// Re-read when the app comes back to the front, because the user grants
    /// this in another application. Recomputing the body also re-reads
    /// `LoginItem`, which the user can change in the same trip.
    @State private var hasAccessibility = Paster.hasPermission
    /// Why the last shortcut the user typed was not taken. Cleared by the next
    /// one that is.
    @State private var shortcutRefusal: ShortcutRefusal?
    /// The shortcut on screen. Seeded from `prefs` and moved only by a change the
    /// system accepted, which is what keeps a refused one from ever appearing
    /// here as though it had been taken.
    @State private var hotkey: Hotkey?
    @FocusState private var focus: Field?

    private enum Field { case items, days }

    /// Both cases name the combination they are about, because by the time this
    /// is on screen the recorder has gone back to showing the shortcut that is
    /// still bound — so the sentence is the only place left that says what was
    /// refused.
    private enum ShortcutRefusal: Equatable {
        case needsModifier(String)
        case inUse(String, current: String)
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
        _blocklistText = State(initialValue: prefs.blocklist.joined(separator: "\n"))
        _hotkey = State(initialValue: prefs.hotkey)
    }

    var body: some View {
        Form {
            startup
            shortcut
            history
            ignoredApps
            permissions
        }
        .formStyle(.grouped)
        .frame(width: 420)
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
            Text("""
                Corvo will keep the newest ^[\(maxItems) clipping](inflect: true) \
                and delete anything older than ^[\(maxAgeDays) day](inflect: true). \
                Pinned and tagged clippings are never deleted. Corvo has no undo.
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
        }
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
        Section("Shortcut") {
            LabeledContent("Open panel") {
                HotkeyRecorder(hotkey: hotkey,
                               onArmedChange: onRecordingArmed,
                               onRecording: record)
            }
            if let shortcutRefusal {
                notice("exclamationmark.triangle.fill", .orange, refusalText(shortcutRefusal))
            }
            if hotkey != Hotkey.default {
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
        switch recording {
        case .cancelled:
            break
        case .cleared:
            _ = onHotkeyChange(nil)
            hotkey = nil
            shortcutRefusal = nil
        case .recorded(let recorded):
            guard HotkeyRule.rejection(for: recorded) == nil else {
                shortcutRefusal = .needsModifier(recorded.display)
                return
            }
            // Asking the system before anything on screen moves is what makes
            // the refusal harmless: on `false` the previous shortcut is still
            // registered and still stored, and only this sentence changes.
            guard onHotkeyChange(recorded) else {
                shortcutRefusal = .inUse(recorded.display,
                                         current: hotkey?.display
                                             ?? String(localized: "no shortcut"))
                return
            }
            hotkey = recorded
            shortcutRefusal = nil
        }
    }

    private func refusalText(_ refusal: ShortcutRefusal) -> Text {
        switch refusal {
        case .needsModifier(let combo):
            Text("\(combo) needs ⌘, ⌥ or ⌃ — otherwise it would be swallowed everywhere.")
        case .inUse(let combo, let current):
            Text("\(combo) is in use by another app. Still using \(current).")
        }
    }

    // MARK: - History

    private var history: some View {
        Section("History") {
            LabeledContent("Keep at most") {
                numberField("Keep at most", value: $maxItems, field: .items)
                Text("clippings").foregroundStyle(.secondary)
            }
            LabeledContent("Delete after") {
                numberField("Delete after", value: $maxAgeDays, field: .days)
                Text("days").foregroundStyle(.secondary)
            }
            caption("Pinned or tagged clippings never expire, and do not count towards the limit.")
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
        Section("Ignored apps") {
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
        Section("Permissions") {
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
        guard maxItems < prefs.maxItems || maxAgeDays < prefs.maxAgeDays else {
            writeRetention()
            return
        }
        isConfirmingCut = true
    }

    private func writeRetention() {
        prefs.maxItems = maxItems
        prefs.maxAgeDays = maxAgeDays
    }

    private func applyCut() {
        writeRetention()
        onRetentionLowered()
    }

    private func revertRetention() {
        maxItems = prefs.maxItems
        maxAgeDays = prefs.maxAgeDays
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
        guard maxItems >= prefs.maxItems, maxAgeDays >= prefs.maxAgeDays else {
            revertRetention()
            return
        }
        // Only write when a draft actually differs from what is stored —
        // otherwise opening and closing the window with nothing touched turns
        // "unset, falls back to `RetentionPolicy.standard`" into a pinned
        // `1000`/`30` that a future change to the standard policy can never
        // reach.
        guard maxItems != prefs.maxItems || maxAgeDays != prefs.maxAgeDays else { return }
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
