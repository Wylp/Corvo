import SwiftUI

/// The colour a tag can carry, stored by name rather than as a hex value.
///
/// Everything in the panel resolves its colour through the system palette so
/// that light and dark both come out right without a second code path — a hex
/// written into the database would only ever be correct in one of them.
enum TagColor: String, CaseIterable, Identifiable {
    case red, orange, yellow, green, mint, blue, purple, pink

    var id: String { rawValue }

    var color: Color {
        switch self {
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .mint: .mint
        case .blue: .blue
        case .purple: .purple
        case .pink: .pink
        }
    }

    /// Colour is never the only carrier, so every swatch says its own name to
    /// VoiceOver.
    var label: LocalizedStringKey {
        switch self {
        case .red: "Red"
        case .orange: "Orange"
        case .yellow: "Yellow"
        case .green: "Green"
        case .mint: "Mint"
        case .blue: "Blue"
        case .purple: "Purple"
        case .pink: "Pink"
        }
    }

    /// `nil` for a tag with no colour, and for a name a later version wrote that
    /// this one does not know.
    static func named(_ name: String?) -> TagColor? {
        name.flatMap(TagColor.init(rawValue:))
    }
}

/// One tag's name, colour and rule.
///
/// The rule is the reason this screen exists, so the pattern field is where the
/// whole design spends itself. It is monospaced — a regex is content of exactly
/// the kind the cards already set in mono — and it answers back on every
/// keystroke: either the error that blocks the save, or how much of the history
/// it would claim, with a sample. Writing a pattern blind and finding out days
/// later that it never matched anything is how this feature dies.
struct TagEditor: View {
    @Bindable var model: HistoryModel
    @Binding var draft: Tag
    /// Called with the stored tag after a write, so the list can keep the row
    /// selected across the reload that follows.
    let onSaved: (Tag) -> Void

    @State private var preview: AutoTagger.Matches = .none
    @State private var isConfirmingApply = false
    /// Set when a write came back `nil`. Without it the screen answers a failed
    /// save by not changing, which is exactly what a successful save looks like.
    @State private var saveFailed = false
    /// Set when the panel came back with an app whose bundle carries no
    /// identifier. Silence would look exactly like a cancelled panel.
    @State private var chooseFailed = false

    /// How many matches the sample shows. Three lines answer "did it match what
    /// I meant" without turning the editor into a second history list.
    private static let sampleCount = 3

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                nameField
                patternField
                sourceField
                Toggle("Ask me to name what it catches", isOn: $draft.promptsForName)
                    .controlSize(.small)
                Spacer(minLength: 0)
                actions
            }
            .padding(16)
        }
        .scrollIndicators(.never)
        // Re-runs on the first appearance and on every edit to either half of
        // the rule, which is exactly when the preview goes stale.
        .task(id: draft.rule) { preview = matches() }
        .alert("Apply this rule to what you already copied?", isPresented: $isConfirmingApply) {
            Button("Cancel", role: .cancel) {}
            Button("Save and apply") { saveAndApply() }
        } message: {
            // The capped wording says which clippings get the tag and which do not.
            // "Added to 10,000 clippings" would be true and would still leave the
            // user believing the whole history was covered.
            if preview.hitLimit {
                Text("""
                    The tag is saved and added to the \
                    ^[\(AutoTagger.previewScanLimit) most recent matching clipping](inflect: true) \
                    already in your history. Older ones are not tagged. Corvo has no undo.
                    """)
            } else {
                Text("""
                    The tag is saved and added to ^[\(preview.items.count) clipping](inflect: true) \
                    already in your history. Corvo has no undo.
                    """)
            }
        }
    }

    // MARK: - Fields

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 4) {
            fieldLabel("Name")
            TextField("Name", text: $draft.name)
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
            if nameIsTaken {
                inline("exclamationmark.triangle.fill", .red,
                       Text("A tag named “\(trimmedName)” already exists."))
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var patternField: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                fieldLabel("Pattern")
                Spacer(minLength: 0)
                swatches
            }
            TextField("Pattern", text: patternText)
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .font(.system(.body, design: .monospaced))
            inline(status.icon, status.tint, Text(status.text))
            if !preview.items.isEmpty { sample }
        }
        .accessibilityElement(children: .contain)
    }

    /// The apps in the history sit at the top because they are the likely
    /// answer, but they are never the whole set: the rule a user most wants is
    /// for an app they have not copied from yet, and that one is reachable only
    /// through the panel. The browse row is *inside* the menu because the menu
    /// is where someone looks when the app they want is not listed.
    private var sourceField: some View {
        VStack(alignment: .leading, spacing: 4) {
            fieldLabel("From app")
            Picker("From app", selection: sourceBinding) {
                Text("Any app").tag(String?.none)
                ForEach(sourceChoices) { source in
                    sourceRow(source).tag(String?.some(source.bundleId))
                }
                Divider()
                Text("Choose an app…").tag(String?.some(AppChooser.browseTag))
            }
            .labelsHidden()
            if chooseFailed {
                inline("exclamationmark.triangle.fill", .red,
                       Text("That app carries no identifier, so no rule can name it. Choose another."))
            }
        }
        .accessibilityElement(children: .contain)
    }

    /// Icon then name, the same pair the sidebar and the cards use. The icon is
    /// what makes a menu of apps scannable; the name is what makes it legible
    /// when the app is gone and there is no icon left to draw.
    private func sourceRow(_ source: SourceSummary) -> some View {
        HStack(spacing: 6) {
            AppIcon.view(forBundleId: source.bundleId)
            Text(source.name)
        }
    }

    /// A row of circles rather than `ColorPicker`: the system colour panel is a
    /// whole second window, and this palette is eight fixed choices that have to
    /// survive round-tripping through a text column anyway.
    private var swatches: some View {
        HStack(spacing: 5) {
            ForEach(TagColor.allCases) { swatch in
                Button { draft.color = draft.color == swatch.rawValue ? nil : swatch.rawValue }
                    label: {
                        Circle()
                            .fill(swatch.color)
                            .frame(width: 11, height: 11)
                            .overlay {
                                Circle().strokeBorder(Color.primary,
                                                      lineWidth: draft.color == swatch.rawValue ? 2 : 0)
                            }
                            // The visible dot is 11pt; the hit area is not.
                            .frame(width: 18, height: 18)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(swatch.label)
                    .accessibilityAddTraits(draft.color == swatch.rawValue ? .isSelected : [])
            }
        }
    }

    // MARK: - The rule's answer

    /// Resolved before any view is built, so the four cases are early returns
    /// instead of a ladder of `if` inside a `ViewBuilder`.
    private struct Status {
        let icon: String
        let tint: Color
        let text: LocalizedStringKey
    }

    private var status: Status {
        switch patternProblem {
        case .malformed:
            return Status(icon: "exclamationmark.triangle.fill", tint: .red,
                          text: "Not a valid pattern. Check the brackets and escapes.")
        // Naming the shape is the whole point of this line: "invalid pattern"
        // tells someone staring at a regex that compiles nothing they can act on.
        case .tooSlow:
            return Status(icon: "exclamationmark.triangle.fill", tint: .red,
                          text: """
                              This pattern can take hours on some clippings. The cause is \
                              almost always a repeat wrapped in another repeat — (a+)+ or \
                              (\\s+)+ — where the inner + or * already covers the outer one. \
                              Remove the outer repeat.
                              """)
        case nil:
            break
        }
        guard draft.rule.isActive else {
            return Status(icon: "hand.tap", tint: .secondary,
                          text: "No rule yet — this tag is only applied by hand.")
        }
        guard !preview.items.isEmpty else {
            return Status(icon: "circle.dashed", tint: .secondary,
                          text: "Nothing you have copied matches yet. New copies still can.")
        }
        // A cap that bit means there may be older matches this never looked at, so
        // the count becomes a floor rather than a number pretending to be exact.
        guard !preview.hitLimit else {
            return Status(icon: "checkmark.circle.fill", tint: .green,
                          text: "Matches \(preview.items.count)+ clippings — only the \(AutoTagger.previewScanLimit) most recent were checked.")
        }
        return Status(icon: "checkmark.circle.fill", tint: .green,
                      text: "Matches ^[\(preview.items.count) clipping](inflect: true) in your history.")
    }

    /// The count says whether the pattern matches; the sample says whether it
    /// matches what the user meant. A regex that quietly claims the wrong things
    /// is the failure the count alone would hide.
    private var sample: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(preview.items.prefix(Self.sampleCount), id: \.id) { item in
                Text(item.text ?? "")
                    .font(.system(.caption2, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Sample of matching clippings")
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Button("Apply to existing…") { isConfirmingApply = true }
                    .disabled(!canSave || preview.items.isEmpty)
                    .help("Add this tag to the clippings already in your history that match")
                Spacer(minLength: 0)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
            if saveFailed {
                inline("exclamationmark.triangle.fill", .red,
                       Text("Could not save this tag. Nothing was changed."))
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Validation

    private var trimmedName: String {
        draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The unique index on `tag.name` would turn this into a constraint failure
    /// on save. Saying so while the user types is the difference between an
    /// error they can fix and one that fires after the fact.
    private var nameIsTaken: Bool {
        model.tags.contains { $0.name == trimmedName && $0.id != draft.id }
    }

    /// An empty field is not an invalid pattern — it is a tag with no rule.
    private var patternProblem: TagRule.PatternProblem? {
        guard let pattern = draft.pattern, !pattern.isEmpty else { return nil }
        return TagRule.problem(with: pattern)
    }

    private var patternIsValid: Bool { patternProblem == nil }

    private var canSave: Bool { !trimmedName.isEmpty && !nameIsTaken && patternIsValid }

    // MARK: - Bindings and actions

    private var patternText: Binding<String> {
        Binding(get: { draft.pattern ?? "" },
                set: { draft.pattern = $0.isEmpty ? nil : $0 })
    }

    private var sourceBinding: Binding<String?> {
        Binding(get: { draft.sourceBundleId }, set: { choose($0) })
    }

    private var sourceChoices: [SourceSummary] {
        AppChooser.choices(seen: model.sources, selected: draft.sourceBundleId)
    }

    /// The browse row arrives here like any other value. Not writing it is what
    /// snaps the selection back to what it was: the getter can never return it,
    /// so cancelling the panel — or choosing an app Corvo cannot name — leaves
    /// the rule exactly as the user found it.
    private func choose(_ id: String?) {
        chooseFailed = false
        guard id == AppChooser.browseTag else {
            draft.sourceBundleId = id
            return
        }
        guard let url = AppChooser.run() else { return }
        guard let picked = AppChooser.bundleId(forApplicationAt: url) else {
            chooseFailed = true
            return
        }
        draft.sourceBundleId = picked
    }

    private func matches() -> AutoTagger.Matches {
        guard patternIsValid else { return .none }
        return model.items(matching: draft.rule)
    }

    private func save() {
        guard let saved = write() else { return }
        onSaved(saved)
    }

    /// Saving first is not an extra step: `addTag` would otherwise create the
    /// tag from its name alone, without the rule the user just wrote.
    private func saveAndApply() {
        guard let saved = write() else { return }
        model.applyRuleToExistingItems(saved)
        onSaved(saved)
    }

    /// The one write path, so the failure is reported the same way whichever
    /// button was pressed.
    private func write() -> Tag? {
        guard canSave else { return nil }
        guard let saved = model.saveTag(draft) else {
            saveFailed = true
            return nil
        }
        saveFailed = false
        draft = saved
        return saved
    }

    // MARK: - Pieces

    private func fieldLabel(_ key: LocalizedStringKey) -> some View {
        Text(key)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    /// Icon, colour and words together — none of the three carries the meaning
    /// on its own.
    private func inline(_ icon: String, _ tint: Color, _ text: Text) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: icon).foregroundStyle(tint)
            text.foregroundStyle(tint == .red ? tint : .secondary)
            Spacer(minLength: 0)
        }
        .font(.caption)
        .accessibilityElement(children: .combine)
    }
}
