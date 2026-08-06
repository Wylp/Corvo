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
    /// ⌘C: put the clipping on the clipboard and stop there. The other half of
    /// ⏎, for pasting somewhere Corvo cannot reach or at a moment it cannot pick.
    let onCopy: (ClipItem) -> Void

    @State private var tagText = ""
    @State private var nameText = ""
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
        // One sheet on the root, switched by the model. Both of these used to be
        // their own `.sheet` on their own view, one nested inside the other.
        .sheet(item: $model.sheet) { sheet in
            switch sheet {
            case .tags: TagManagerView(model: model)
            case .naming: tagSheet
            case .rename: nameSheet
            }
        }
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
                                     isSelected: index == model.selectedIndex, blobs: blobs,
                                     // The tags are handed over unread: this
                                     // fires on every pointer movement and
                                     // `tags(for:)` is a database query, so it
                                     // runs only if the preview actually opens.
                                     onHover: { midX in
                                         PreviewPanel.shared.hover(
                                             item: item, cardMidX: midX, blobs: blobs,
                                             tags: { model.tags(for: item) })
                                     },
                                     onHoverEnd: { PreviewPanel.shared.endHover() })
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

    /// ⏎ and ⌘C sit together at the head of the rail because they are the two
    /// ways out with the clipping: one lands it in the app you came from, the
    /// other just hands it to you.
    private var shortcutRail: some View {
        HStack(spacing: 14) {
            KeycapHint(key: "⏎", label: "Paste")
            KeycapHint(key: "⌘C", label: "Copy")
            KeycapHint(key: "⌘P", label: "Pin")
            // Before ⌘T, and the pair reads in the order the words mean: name
            // this one thing, then file it with the others.
            KeycapHint(key: "⌘R", label: "Name")
            KeycapHint(key: "⌘T", label: "Tag")
            KeycapHint(key: "⌘⇧T", label: "Edit tags")
            KeycapHint(key: "⌘⌫", label: "Delete")
            Spacer(minLength: 8)
            KeycapHint(key: "esc", label: "Close")
        }
        .padding(.horizontal, 16)
        .frame(height: 30)
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
            // Wins over the search field's own ⌘C: a shortcut registered on the
            // window's views is consulted before the menu item the field relies
            // on. Copying a card is what the panel is open for; copying the
            // query back out of the search box is not.
            shortcutButton("c", modifiers: .command) {
                if let item = model.selectedItem { onCopy(item) }
            }
            // ⌘⌫, not a bare ⌫: the search field holds focus while the panel is
            // open, so an unmodified Delete either steals backspace from the
            // field — destroying a clipping with no undo — or never fires at
            // all. ⌘⌫ is unambiguous, and it is what Finder and Paste use.
            shortcutButton(.delete, modifiers: .command) {
                if let item = model.selectedItem { model.delete(item) }
            }
            shortcutButton("p", modifiers: .command) {
                if let item = model.selectedItem { model.togglePinned(item) }
            }
            // ⌘R, not a second use of ⌘T: ⌘T attaches a *tag*, a label shared
            // across clippings and listed in the sidebar, while this names one
            // clipping and nothing else. Two jobs, two keys. ⌘R is free in this
            // panel and is what "rename" is bound to nearly everywhere it
            // exists — Return, the other candidate, already pastes.
            //
            // Seeded with the current name so ⌘R also *edits* one, and emptying
            // the field is the way back out of a name you regret.
            shortcutButton("r", modifiers: .command) {
                nameText = model.selectedItem?.label ?? ""
                model.sheet = .rename
            }
            shortcutButton("t", modifiers: .command) { tagText = ""; model.sheet = .naming }
            shortcutButton("t", modifiers: [.command, .shift]) { model.sheet = .tags }
        }
        .opacity(0)
        .frame(width: 0, height: 0)
    }

    /// Every shortcut in the panel takes the hover preview down on its way
    /// through, which is what "the keyboard is in charge" means in practice.
    /// Here rather than in each action because it is true of all of them and
    /// there is no key that should leave a preview of some other card hanging:
    /// ←/→ move a selection the preview is not following, ⏎ and ⌘C are on their
    /// way out of the panel entirely, and ⌘R, ⌘T and ⌘⇧T raise a sheet that a
    /// floating window would sit on top of.
    ///
    /// It never runs the other way: nothing here opens a preview, so arrowing
    /// through the carousel stays silent.
    private func shortcutButton(_ key: KeyEquivalent,
                                modifiers: EventModifiers = [],
                                action: @escaping () -> Void) -> some View {
        Button {
            PreviewPanel.shared.dismiss()
            action()
        } label: {
            EmptyView()
        }
        .keyboardShortcut(key, modifiers: modifiers)
    }

    private var tagSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New tag").font(.headline)
            TextField("Tag name", text: $tagText)
                .onSubmit { confirmTag() }
            HStack {
                Spacer()
                Button("Cancel") { model.sheet = nil }
                Button("Add") { confirmTag() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 300)
    }

    /// Built to the same measurements as `tagSheet` on purpose. The two answer
    /// different questions, and the copy is where that difference lives: the
    /// button says the verb that happens, and the helper line names both what a
    /// name is for and how to take one back.
    private var nameSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Name this clipping").font(.headline)
            TextField("Name", text: $nameText)
                .onSubmit { confirmName() }
            Text("Shown on the card and searchable. Clear it to remove the name.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { model.sheet = nil }
                Button("Save") { confirmName() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 300)
    }

    private func confirmName() {
        if let id = model.selectedItem?.id {
            model.setLabel(nameText, forItemId: id)
        }
        model.sheet = nil
    }

    private func confirmTag() {
        if let item = model.selectedItem {
            model.addTag(tagText, to: item)
        }
        model.sheet = nil
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
