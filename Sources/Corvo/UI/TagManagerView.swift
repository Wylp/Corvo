import SwiftUI

/// Where tags are made, edited and thrown away.
///
/// The same split the panel itself uses — a narrow list on the left, the thing
/// you are working on to the right — and the same keycap rail at the bottom,
/// because in a window with no title bar the keys are the chrome. Everything
/// here is reachable from the keyboard: the list is a real `List` with a
/// selection, so the arrow keys walk it, and ⌘N, ⌘⌫, ⏎ and esc cover the rest.
struct TagManagerView: View {
    @Bindable var model: HistoryModel
    @Environment(\.dismiss) private var dismiss

    @State private var selection: Int64?
    @State private var draft = Tag(id: nil, name: "", color: nil)
    @State private var isConfirmingDelete = false
    /// Read once when the confirmation opens, so the number the user is shown is
    /// the number that was true when they were asked.
    @State private var affectedItemCount = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                tagList
                Divider()
                TagEditor(model: model, draft: $draft) { saved in selection = saved.id }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            Divider()
            rail
        }
        .frame(width: 660, height: 430)
        .background(shortcuts)
        .onAppear { select(model.tags.first?.id) }
        .onChange(of: selection) { _, id in loadDraft(id) }
    }

    // MARK: - The list

    private var tagList: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(model.tags) { tag in
                    row(tag).tag(tag.id)
                }
            }
            .listStyle(.sidebar)
            .overlay {
                if model.tags.isEmpty { emptyList }
            }
            Divider()
            listBar
        }
        .frame(width: 200)
    }

    private func row(_ tag: Tag) -> some View {
        HStack(spacing: 7) {
            Circle()
                .fill(TagColor.named(tag.color)?.color ?? Color.secondary.opacity(0.35))
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            Text(tag.name).lineLimit(1)
            Spacer(minLength: 4)
            if tag.rule.isActive {
                // Which tags apply themselves is the one fact the list can carry
                // that the name cannot.
                Image(systemName: "bolt.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Applies itself")
            }
        }
    }

    private var emptyList: some View {
        VStack(spacing: 4) {
            Text("No tags yet").font(.callout.weight(.medium))
            Text("Press ⌘N to make one.").font(.caption).foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 12)
    }

    /// The `+` / `−` strip under a source list is the macOS idiom for this, and
    /// it is where the two shortcuts on the rail become clickable as well.
    private var listBar: some View {
        HStack(spacing: 2) {
            barButton("plus", "New tag") { newTag() }
            barButton("minus", "Delete tag") { confirmDelete() }
                .disabled(selectedTag == nil)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .frame(height: 28)
        .alert("Delete the tag “\(selectedTag?.name ?? "")”?", isPresented: $isConfirmingDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { deleteSelected() }
        } message: {
            Text("""
                ^[\(affectedItemCount) clipping](inflect: true) will lose this tag. \
                The clippings themselves stay.
                """)
        }
    }

    private func barButton(_ icon: String, _ label: LocalizedStringKey,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .frame(width: 22, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(label)
        .accessibilityLabel(label)
    }

    // MARK: - The rail

    private var rail: some View {
        HStack(spacing: 14) {
            KeycapHint(key: "⌘N", label: "New")
            KeycapHint(key: "⌘⌫", label: "Delete")
            KeycapHint(key: "⏎", label: "Save")
            Spacer(minLength: 8)
            KeycapHint(key: "esc", label: "Done")
        }
        .padding(.horizontal, 16)
        .frame(height: 30)
    }

    /// Invisible buttons, the same trick `HistoryView` uses: it is how SwiftUI
    /// registers a shortcut without a menu item to hang it on. ⏎ needs none —
    /// the editor's Save is the default action.
    private var shortcuts: some View {
        Group {
            Button { newTag() } label: { EmptyView() }
                .keyboardShortcut("n", modifiers: .command)
            // ⌘⌫ rather than a bare ⌫ for the same reason the panel uses it: a
            // text field holds the focus here, and an unmodified Delete would
            // either eat a backspace or never fire.
            Button { confirmDelete() } label: { EmptyView() }
                .keyboardShortcut(.delete, modifiers: .command)
            Button { dismiss() } label: { EmptyView() }
                .keyboardShortcut(.cancelAction)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
    }

    // MARK: - Actions

    private var selectedTag: Tag? {
        guard let selection else { return nil }
        return model.tags.first { $0.id == selection }
    }

    private func select(_ id: Int64?) {
        selection = id
        loadDraft(id)
    }

    /// ponytail: switching rows drops whatever was typed and not saved. Nothing
    /// stored is lost — the links and the rule on disk are untouched — so this
    /// costs a half-finished pattern at worst, and the rail says ⏎ saves.
    /// Upgrade: stash the draft per tag, or confirm on switch, if it stings.
    private func loadDraft(_ id: Int64?) {
        guard let tag = model.tags.first(where: { $0.id == id }) else { return }
        draft = tag
    }

    private func newTag() {
        selection = nil
        draft = Tag(id: nil, name: "", color: nil)
    }

    private func confirmDelete() {
        guard let tag = selectedTag else { return }
        affectedItemCount = model.itemCount(forTag: tag)
        isConfirmingDelete = true
    }

    private func deleteSelected() {
        guard let tag = selectedTag else { return }
        model.deleteTag(tag)
        guard let next = model.tags.first?.id else { return newTag() }
        select(next)
    }
}

/// One key drawn as a keycap next to what it does. Lives here rather than in
/// `HistoryView` only because two rails now share it; the style is Task 11's,
/// unchanged.
struct KeycapHint: View {
    let key: LocalizedStringKey
    let label: LocalizedStringKey

    var body: some View {
        HStack(spacing: 5) {
            Text(key)
                .font(.system(size: 10, weight: .medium))
                .frame(minWidth: 18, minHeight: 15)
                .padding(.horizontal, 3)
                .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 4))
                .overlay {
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Color.primary.opacity(0.12))
                }
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
