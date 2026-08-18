import AppKit
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
    /// Takes the whole selection, which is one clipping until ⇧← or ⇧→ makes it
    /// a run.
    let onPaste: ([ClipItem]) -> Void
    /// ⌘C: put the clipping on the clipboard and stop there. The other half of
    /// ⏎, for pasting somewhere Corvo cannot reach or at a moment it cannot pick.
    let onCopy: ([ClipItem]) -> Void

    @State private var tagText = ""
    /// Which row of the tag sheet the keyboard is on, or `nil` for "still in the
    /// field". See `HistoryModel.highlight`.
    @State private var highlighted: Int?
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
                    // Lazy, so the row builds the cards it is showing and not
                    // every clipping the query returned. `HStack` builds all of
                    // them, and a built card is not free: it asks the database
                    // for its tags, tokenises up to 1,200 characters, and an
                    // image card opens its blob off disk with nothing caching
                    // the result.
                    //
                    // The row reads `selectedIndex`, so every arrow key rebuilds
                    // whatever it builds. `theCarouselOnlyAsksAboutTheCardsItIsShowing`
                    // measures the difference on a 200-clipping history: two
                    // hundred tag queries per arrow press eagerly, four lazily.
                    LazyHStack(spacing: 12) {
                        ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                            ItemCard(item: item, tags: model.tags(for: item),
                                     isSelected: index == model.selectedIndex,
                                     isMarked: model.isMarked(item), blobs: blobs)
                                .id(item.id)
                                .onTapGesture(count: 2) { onPaste([item]) }
                                .onTapGesture { model.select(index) }
                                // ⇧-click, the way a range is selected in every
                                // list on this platform. `highPriorityGesture`
                                // and not `.gesture`, because the plain tap
                                // above would otherwise win and collapse the
                                // run it is meant to extend.
                                // ⌘-click before ⇧-click: both are high priority,
                                // and the first registered is the first
                                // consulted.
                                .highPriorityGesture(
                                    TapGesture().modifiers(.command)
                                        .onEnded { model.toggleMark(at: index) })
                                .highPriorityGesture(
                                    TapGesture().modifiers(.shift)
                                        .onEnded { model.extendSelection(to: index) })
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
            // Third because it changes what the first two act on, so it reads
            // as a qualifier of them rather than another thing to do — and the
            // label has to say so. Every other hint in this rail names a key
            // that performs its action on its own; ⇧ performs nothing. "Select
            // several" next to a lone ⇧ promises a key that does something when
            // pressed, and pressing it does nothing at all.
            KeycapHint(key: "⇧⌘", label: "Hold and click to select several")
            KeycapHint(key: "⌘P", label: "Pin")
            // Before ⌘T, and the pair reads in the order the words mean: name
            // this one thing, then file it with the others.
            KeycapHint(key: "⌘R", label: "Name")
            KeycapHint(key: "⌘T", label: "Tag")
            KeycapHint(key: "⌘⇧T", label: "Edit tags")
            KeycapHint(key: "⌘↑↓", label: "Filter")
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
            // One shortcut per arrow, not two. Registering ⇧+arrow as its own
            // shortcut looks right and is not: SwiftUI hands the ⇧ variant every
            // press of that key, so a bare arrow extended the run instead of
            // moving through it. Reading the flag at the moment of the press is
            // the version that holds.
            shortcutButton(.leftArrow) { arrow(-1) }
            shortcutButton(.rightArrow) { arrow(1) }
            // ⌘ and not a bare ↑/↓: left and right already walk the clippings,
            // so up and down walk what is being shown. ⌘ is what keeps the pair
            // from being one more thing the search field eats.
            shortcutButton(.upArrow, modifiers: .command) { model.moveFilter(-1) }
            shortcutButton(.downArrow, modifiers: .command) { model.moveFilter(1) }
            shortcutButton(.return) { pasteSelected() }
            // Wins over the search field's own ⌘C: a shortcut registered on the
            // window's views is consulted before the menu item the field relies
            // on. Copying a card is what the panel is open for; copying the
            // query back out of the search box is not.
            shortcutButton("c", modifiers: .command) {
                guard !model.selectedItems.isEmpty else { return }
                onCopy(model.selectedItems)
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
            shortcutButton("t", modifiers: .command) {
                tagText = ""
                highlighted = nil
                model.sheet = .naming
            }
            shortcutButton("t", modifiers: [.command, .shift]) { model.sheet = .tags }
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

    /// The field makes a tag; the list below it reaches one that already exists.
    ///
    /// Both are needed, and the list is the half that was missing. A tag is
    /// stored under the name it was written with, so typing at a tag one letter
    /// or one capital off from the one that was meant does not fail — it quietly
    /// files the clipping under a second tag beside it, and the user finds out
    /// when the sidebar has "Work" and "work" in it. Reaching an existing tag
    /// should not require remembering how it was spelled.
    private var tagSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add a tag").font(.headline)
            TextField("Tag name", text: $tagText)
                .onSubmit { confirmTag() }
                // On the field, which is what holds focus while this sheet is
                // up. An arrow key that reaches a single-line text field is
                // spent moving the caret, so this is also the only place the
                // list can be reached without the mouse.
                .onKeyPress(.upArrow) { moveHighlight(-1) }
                .onKeyPress(.downArrow) { moveHighlight(1) }
                // Typing changes which tags are on offer, so a row picked
                // against the old list is no longer the row under the cursor.
                // Dropping back to the field is the answer that cannot pick the
                // wrong tag.
                .onChange(of: tagText) { _, _ in highlighted = nil }
            tagsAlreadyOn
            tagChoiceList
            HStack {
                Spacer()
                Button("Cancel") { model.sheet = nil }
                Button("Add") { confirmTag() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 300)
    }

    /// What this clipping already carries, each row a way to take it back off.
    ///
    /// It belongs on this sheet and not only in the tag manager, because
    /// "which tags does this clipping have" is one thought and adding was the
    /// only half of it that had an answer here. A tag put on by mistake — and
    /// the whole reason for the list below is that they used to be easy to put
    /// on by mistake — had to be undone on a different screen, if the user found
    /// it at all.
    ///
    /// Removing takes the tag off *this clipping*. It is not `deleteTag`, which
    /// destroys the tag everywhere and lives behind a confirmation in the
    /// manager. Nothing here needs one: what is undone is undone by clicking the
    /// same name in the list below.
    @ViewBuilder
    private var tagsAlreadyOn: some View {
        let onAll = model.tagsOnAll(model.selectedItems)
        let carried = model.tags.filter { onAll.contains($0.name) }
        if !carried.isEmpty {
            VStack(spacing: 0) {
                ForEach(carried) { tag in
                    HStack(spacing: 0) {
                        tagChoiceRow(tag, isHighlighted: false)
                        Button { remove(tag) } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .padding(.trailing, 8)
                        .help("Remove this tag from the clipping")
                        .accessibilityLabel("Remove \(tag.name)")
                    }
                }
            }
            .frame(maxHeight: 108)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    /// Absent rather than empty when there is nothing to show, so a first tag is
    /// made in a sheet the same size as the one that made it.
    @ViewBuilder
    private var tagChoiceList: some View {
        if !tagChoices.isEmpty {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(tagChoices.enumerated()), id: \.element.id) { index, tag in
                            Button { add(tag) } label: {
                                tagChoiceRow(tag, isHighlighted: index == highlighted)
                            }
                            .buttonStyle(.plain)
                            .id(tag.id)
                        }
                    }
                }
                // Keeps the keyboard's row on screen. Without it ↓ walks past
                // the fourth row into a highlight nobody can see.
                .onChange(of: highlighted) { _, new in
                    guard let new, tagChoices.indices.contains(new) else { return }
                    proxy.scrollTo(tagChoices[new].id)
                }
            }
            // Four rows and the fifth cut in half: enough to scan, and it says
            // there is more below without a scroller having to appear.
            .frame(maxHeight: 108)
            .scrollIndicators(.never)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private var tagChoices: [Tag] {
        model.tagChoices(for: model.selectedItems, matching: tagText)
    }

    /// The dot and the name in the order the sidebar and the tag manager already
    /// use them.
    private func tagChoiceRow(_ tag: Tag, isHighlighted: Bool) -> some View {
        HStack(spacing: 7) {
            Circle()
                .fill(TagColor.named(tag.color)?.color ?? Color.secondary.opacity(0.35))
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            Text(tag.name).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        // The row is the target, not the words in it.
        .contentShape(Rectangle())
        .background(isHighlighted ? Color.accentColor.opacity(0.25) : .clear,
                    in: RoundedRectangle(cornerRadius: 4))
        .accessibilityAddTraits(isHighlighted ? .isSelected : [])
    }

    /// `.ignored` when there is no list to walk, so the arrow goes on to do
    /// whatever it did before rather than being swallowed by a sheet that had no
    /// use for it.
    private func moveHighlight(_ step: Int) -> KeyPress.Result {
        let moved = HistoryModel.highlight(highlighted, step: step, count: tagChoices.count)
        guard tagChoices.count > 0 else { return .ignored }
        highlighted = moved
        return .handled
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

    /// ⏎ means whichever of the two things the sheet does is currently in hand:
    /// take the highlighted tag, or make the one that was typed. Nothing is
    /// highlighted until an arrow says so, so typing a brand new name and
    /// pressing ⏎ can never be answered with somebody else's tag.
    private func confirmTag() {
        if let index = highlighted, tagChoices.indices.contains(index) {
            return add(tagChoices[index])
        }
        model.addTag(tagText, to: model.selectedItems)
        model.sheet = nil
    }

    /// Passes the stored name, not what was typed, so the tag the row stands for
    /// is the tag that gets attached — and to the whole selection, because the
    /// field beside it already does. A row that reached one clipping while
    /// typing the same name reached five would be the sheet contradicting
    /// itself.
    private func add(_ tag: Tag) {
        model.addTag(tag.name, to: model.selectedItems)
        model.sheet = nil
    }

    /// The sheet stays up, unlike `add`. Taking a tag off is the one thing here
    /// a user is likely to do twice in a row, and it is also the one worth
    /// seeing the result of: the row leaves the top list and reappears in the
    /// one below.
    private func remove(_ tag: Tag) {
        model.removeTag(tag, from: model.selectedItems)
        highlighted = nil
    }

    /// `NSEvent.modifierFlags` is the state right now, which during the handler
    /// for the key that was just pressed is the state that key was pressed with.
    private func arrow(_ step: Int) {
        model.arrow(step, extending: NSEvent.modifierFlags.contains(.shift))
    }

    private func pasteSelected() {
        guard !model.selectedItems.isEmpty else { return }
        onPaste(model.selectedItems)
    }

    /// Reads the selection through `selectedItem`, the model's own bounds-checked
    /// accessor — there is no second path that could index past `items`.
    private func scrollToSelection(_ proxy: ScrollViewProxy) {
        guard let id = model.selectedItem?.id else { return }
        guard !reduceMotion else { return proxy.scrollTo(id) }
        withAnimation(.snappy(duration: 0.22)) { proxy.scrollTo(id) }
    }
}
