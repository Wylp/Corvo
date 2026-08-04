import SwiftUI

/// The panel. Search spans the top, filters sit on the left, the carousel takes
/// the rest, and a rail of key hints closes it off at the bottom.
///
/// The rail is not decoration. The panel has no title bar — see `FloatingPanel` —
/// so the keys *are* the chrome: it is where `esc` announces the way out and the
/// only place the shortcuts are visible at all.
struct HistoryView: View {
    @Bindable var model: HistoryModel
    let blobs: BlobStore
    let onPaste: (ClipItem) -> Void

    @State private var isEditingTag = false
    @State private var tagText = ""
    @FocusState private var isSearchFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            HStack(spacing: 0) {
                FilterSidebar(model: model)
                Divider()
                carousel
            }
            Divider()
            shortcutRail
        }
        .frame(minWidth: 700, minHeight: 380)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .background(shortcuts)
        .onAppear { isSearchFocused = true }
        .sheet(isPresented: $isEditingTag) { tagSheet }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.title3)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Search content or app…", text: $model.query)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($isSearchFocused)
                .onSubmit { pasteSelected() }
        }
        .padding(.horizontal, 16)
        .frame(height: 48)
    }

    @ViewBuilder
    private var carousel: some View {
        if model.items.isEmpty {
            emptyState
        } else {
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: 12) {
                        ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                            ItemCard(item: item, tags: model.tags(for: item),
                                     isSelected: index == model.selectedIndex, blobs: blobs)
                                .id(item.id)
                                .onTapGesture(count: 2) { onPaste(item) }
                                .onTapGesture { model.selectedIndex = index }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 22)
                }
                .scrollIndicators(.never)
                .onChange(of: model.selectedIndex) { _, _ in scrollToSelection(proxy) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Both states carry our own strings. `ContentUnavailableView.search(text:)`
    /// would have been shorter, but it renders SwiftUI's built-in copy in the
    /// system language — one Portuguese screen inside an English-first app.
    @ViewBuilder
    private var emptyState: some View {
        if model.query.isEmpty {
            ContentUnavailableView("Nothing here yet", systemImage: "bird",
                                   description: Text("Copy something and come back."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView("No matches", systemImage: "magnifyingglass",
                                   description: Text("Try another word, or clear the search."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var shortcutRail: some View {
        HStack(spacing: 14) {
            hint("⏎", "Paste")
            hint("⌘P", "Pin")
            hint("⌘T", "Tag")
            hint("⌫", "Delete")
            Spacer(minLength: 8)
            hint("esc", "Close")
        }
        .padding(.horizontal, 16)
        .frame(height: 30)
    }

    private func hint(_ key: LocalizedStringKey, _ label: LocalizedStringKey) -> some View {
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

    /// Invisible buttons are how SwiftUI registers a shortcut with no menu item.
    /// They live on the root, not on the carousel, so they keep working while the
    /// list is empty. The label is `EmptyView` rather than `""`, which would put
    /// an empty key in the String Catalog.
    private var shortcuts: some View {
        Group {
            shortcutButton(.leftArrow) { model.move(-1) }
            shortcutButton(.rightArrow) { model.move(1) }
            shortcutButton(.return) { pasteSelected() }
            shortcutButton(.delete) { if let item = model.selectedItem { model.delete(item) } }
            shortcutButton("p", modifiers: .command) {
                if let item = model.selectedItem { model.togglePinned(item) }
            }
            shortcutButton("t", modifiers: .command) { tagText = ""; isEditingTag = true }
        }
        .opacity(0)
        .frame(width: 0, height: 0)
    }

    private func shortcutButton(_ key: KeyEquivalent,
                                modifiers: EventModifiers = [],
                                action: @escaping () -> Void) -> some View {
        Button(action: action) { EmptyView() }
            .keyboardShortcut(key, modifiers: modifiers)
    }

    private var tagSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New tag").font(.headline)
            TextField("Tag name", text: $tagText)
                .onSubmit { confirmTag() }
            HStack {
                Spacer()
                Button("Cancel") { isEditingTag = false }
                Button("Add") { confirmTag() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 300)
    }

    private func confirmTag() {
        if let item = model.selectedItem {
            model.addTag(tagText, to: item)
        }
        isEditingTag = false
    }

    private func pasteSelected() {
        guard let item = model.selectedItem else { return }
        onPaste(item)
    }

    /// Reads the selection through `selectedItem`, the model's own bounds-checked
    /// accessor — there is no second path that could index past `items`.
    private func scrollToSelection(_ proxy: ScrollViewProxy) {
        guard let id = model.selectedItem?.id else { return }
        guard !reduceMotion else { return proxy.scrollTo(id) }
        withAnimation(.snappy(duration: 0.22)) { proxy.scrollTo(id) }
    }
}
