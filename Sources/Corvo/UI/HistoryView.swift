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
    /// Opens Settings. The panel is the only surface left when the menu bar icon
    /// is switched off — the ⌘, that opens Settings lives on the `MenuBarExtra`
    /// menu, and that menu is exactly what disappears with the icon.
    let onOpenSettings: () -> Void

    /// Narrows the tag sheet's left column. It used to be the name of the tag
    /// being made as well, and one field could not go on being both once the
    /// right column grew the rest of a tag's parameters.
    @State private var tagText = ""
    /// The tag being written in the sheet's right column. Reset when the sheet
    /// opens, so a cancelled draft is not waiting there the next time.
    @State private var tagDraft = Tag(id: nil, name: "", color: nil)
    @State private var tagKind = TagKind.all
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
            tagStrip
            Divider()
            HStack(spacing: 0) {
                FilterSidebar(model: model)
                Divider()
                carousel
            }
            Divider()
            shortcutRail
        }
        // The minimum is what it takes to draw a whole card under the chrome:
        // 48 of search, 30 of tags, 30 of rail, the rules between them, and the
        // 250pt card inside its own padding. Below that the panel would clip the
        // one thing it exists to show, so the number moved when the strip was
        // added rather than staying at a figure that was true before it.
        .frame(minWidth: 700, minHeight: 410)
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
            // Sibling of the magnifying glass rather than a card-coloured
            // control: this is chrome, and the cards are what the panel is for.
            Button(action: onOpenSettings) {
                Image(systemName: "gearshape")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Settings (⌘,)")
            .accessibilityLabel("Settings")
        }
        .padding(.horizontal, 16)
        .frame(height: 48)
    }

    /// Tags across the top instead of underneath the apps in the sidebar.
    ///
    /// The two lists shared one 190pt column and they do not grow alike. Apps
    /// arrive on their own — one appears for every place anything has ever been
    /// copied from, and nothing the user does adds or removes them — while tags
    /// are put there by hand and stay few. So the list that grows is the one
    /// that pushed the other off the bottom of the panel, and the one pushed off
    /// is the one somebody built on purpose. Thirteen apps was enough.
    ///
    /// Across the top they stop competing for the same space: the column is free
    /// to be as long as the apps make it, and the tags sit in a row that is read
    /// in one pass rather than scrolled to.
    ///
    /// The row stays even with no tags in it, for the reason the sidebar's tag
    /// section used to: it carries the only way into the tag manager, and a user
    /// with no tags yet is exactly the one who needs to find it.
    private var tagStrip: some View {
        HStack(spacing: 0) {
            if model.tags.isEmpty {
                // Says what the empty row is for, in the place the tags will
                // appear, rather than leaving a bare band with a lone button at
                // the end of it — which is what a user with no tags saw, and
                // reads as something broken rather than something not used yet.
                //
                // Quiet on purpose, and it names the key: the same reasoning as
                // the card's own "Name this (⌘R)". A hint the user has to
                // already know is not a hint.
                Text("Tags you add with ⌘T show up here")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 16)
                Spacer(minLength: 8)
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(model.tags) { tag in tagChip(tag) }
                    }
                    .padding(.horizontal, 16)
                }
                .scrollIndicators(.never)
            }
            editTagsButton
        }
        .frame(height: 30)
        .accessibilityLabel("Tags")
    }

    /// A capsule, matching the tags drawn on the cards: the same thing named the
    /// same way in both places, so filling one is visibly the same object as the
    /// one printed on the clipping.
    ///
    /// Clicking the active chip clears the filter, which is the behaviour the
    /// sidebar rows already had — and the fill is what makes clicking it again a
    /// sensible thing to try.
    private func tagChip(_ tag: Tag) -> some View {
        let isOn = model.selectedTag == tag.id
        return Button {
            model.selectedTag = isOn ? nil : tag.id
        } label: {
            HStack(spacing: 5) {
                // The glyph carries the rule, the colour carries the tag's own
                // colour, exactly as in the sidebar this replaces.
                Image(systemName: tag.rule.isActive ? "bolt.fill" : "tag.fill")
                    .font(.caption2)
                    .foregroundStyle(TagColor.named(tag.color)?.color ?? .secondary)
                Text(tag.name).lineLimit(1)
            }
            .font(.callout)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(isOn ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.06),
                        in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    /// Pinned outside the scroll view rather than trailing the chips, so it does
    /// not walk off the edge once there are more tags than fit: it is the only
    /// route to the tag manager, and a route that scrolls away is one a user has
    /// to already know about to reach.
    private var editTagsButton: some View {
        Button { model.sheet = .tags } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.caption)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("Edit tags and rules (⌘⇧T)")
        .accessibilityLabel("Edit tags and rules")
        .padding(.trailing, 12)
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
                                     isMarked: model.isMarked(item),
                                     number: HistoryModel.number(forIndex: index),
                                     blobs: blobs,
                                     onHover: { midX in
                                         PreviewPanel.shared.hover(item: item, cardMidX: midX,
                                                                   blobs: blobs)
                                     },
                                     onHoverEnd: { PreviewPanel.shared.endHover() })
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
            // Third of the three ways out holding a clipping, so it sits with
            // the other two. The number is written on each card as well, and
            // that turned out not to be enough on its own: the rail is where a
            // person looks to find out what the keys do, and a shortcut absent
            // from it reads as one that does not exist. Being in both places
            // costs one hint in a row that has the room.
            KeycapHint(key: "⌘1-9", label: "Paste that card")
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
            // Two axes now, so two hints: the column of apps runs down, the row
            // of tags runs across, and each pair of keys points the way its own
            // list is drawn.
            KeycapHint(key: "⌘↑↓", label: "Apps")
            KeycapHint(key: "⌘←→", label: "Tags")
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
            // Registered with the modifier, exactly like the pair above, and not
            // read off `NSEvent.modifierFlags` inside the bare-arrow handler.
            // The bare registration is not offered ⌘+arrow at all: measured in
            // `commandArrowsReachTheFiltersAndLeaveTheBareArrowsAlone`, where a
            // ⌘→ posted at the window moved neither the cursor nor the filter
            // until this pair existed. The ⇧ arrows do work that way, which is
            // what made it look like the rule — it is not: ⇧ is folded into the
            // key's own characters, ⌘ makes the event a key equivalent, and only
            // an equivalent registered with ⌘ is ever asked about it.
            shortcutButton(.leftArrow, modifiers: .command) { model.moveTagFilter(-1) }
            shortcutButton(.rightArrow, modifiers: .command) { model.moveTagFilter(1) }
            // The way to Settings that survives the menu bar icon being switched
            // off, which is what takes the `MenuBarExtra` menu — and its own ⌘,
            // — away. Registered here as well as there, both reaching the same
            // `showSettings()`, so there is no second path to keep in step.
            shortcutButton(",", modifiers: .command) { onOpenSettings() }
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
                tagDraft = Tag(id: nil, name: "", color: nil)
                tagKind = .all
                highlighted = nil
                model.sheet = .naming
            }
            shortcutButton("t", modifiers: [.command, .shift]) { model.sheet = .tags }
            // ⌘1 through ⌘9 paste the card wearing that number, rather than
            // moving the cursor onto it. Selecting would save nothing: the
            // arrows already do that, and what the numbers buy is skipping the
            // walk entirely — see it, press it, it is pasted.
            //
            // One clipping and not the run, for the same reason a double-click
            // is one clipping: a key that names a specific card is pointing at
            // that card, whatever else happens to be marked.
            ForEach(1...HistoryModel.numberedCards, id: \.self) { number in
                shortcutButton(KeyEquivalent(Character("\(number)")), modifiers: .command) {
                    guard let item = model.item(atNumber: number) else { return }
                    onPaste([item])
                }
            }
        }
        // Off while a sheet is up. Every key in this group acts on the list
        // behind the sheet, and a sheet is a question with the answer still
        // being typed: ⌘1 pasted a clipping and took the panel off screen from
        // under an open tag editor, and ⌘→ moved the filter under it. Measured
        // in `theShortcutsDoNotReachThroughAnOpenSheet` — a presented sheet does
        // not stop the presenter's shortcuts on its own.
        //
        // On the group rather than on the keys this change added, because the
        // ones already here reach through it in exactly the same way and a guard
        // per key is a guard somebody forgets on the tenth.
        .disabled(model.sheet != nil)
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

    /// Reach a tag that exists, on the left; make one, on the right.
    ///
    /// Both are needed. A tag is stored under the name it was written with, so
    /// typing at a tag one letter or one capital off from the one that was meant
    /// does not fail — it quietly files the clipping under a second tag beside
    /// it, and the user finds out when the strip has "Work" and "work" in it.
    /// Reaching an existing tag should not require remembering how it was
    /// spelled.
    ///
    /// The right half is the whole `TagEditor`, not a name field. Making a tag
    /// here used to produce a tag with nothing but a name: no colour, no rule,
    /// no source. Getting those onto it meant leaving, opening the manager,
    /// finding the tag just made and filling it in — two screens for one
    /// thought. It is the same editor the manager shows rather than a second
    /// form beside it, so there is one place where a tag's parameters are
    /// defined and one place to fix when they change.
    ///
    /// One field per job, which is what splits the old single field in two: it
    /// was both the filter over existing tags and the name of the new one, and
    /// those want opposite things the moment the form grew past a name.
    private var tagSheet: some View {
        VStack(spacing: 0) {
            tagSheetHeader
            Divider()
            HStack(spacing: 0) {
                tagPicker
                Divider()
                TagEditor(model: model, draft: $tagDraft, onSaved: attach,
                          showsActions: false)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    // Whichever half was typed in last owns ⏎, and the button
                    // says which. Without this, starting to write a new tag
                    // while a search match is highlighted would leave ⏎ adding
                    // that match instead of the tag being written.
                    .onChange(of: tagDraft.name) { _, _ in highlighted = nil }
            }
            Divider()
            tagSheetFooter
        }
        .frame(width: 640, height: 430)
    }

    /// What is being tagged, and what it already carries. Spans both columns
    /// because it is the subject of both of them.
    private var tagSheetHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Names what it acts on. ⌘T reaches the whole selection, and a
            // headline that said "Add a tag" over five selected clippings was
            // the sheet keeping the most important thing about itself to itself.
            Text(tagSheetTitle).font(.headline)
            tagsAlreadyOn
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var tagSheetFooter: some View {
        HStack(spacing: 10) {
            KeycapHint(key: "↑↓", label: "Pick")
            Spacer(minLength: 8)
            Button("Cancel") { model.sheet = nil }
            // Adds the highlighted tag when the list has the keyboard, and
            // otherwise makes the one being written on the right. `confirmTag`
            // is where that choice lives.
            Button(addButtonLabel) { confirmTag() }
                .keyboardShortcut(.defaultAction)
                .disabled(!canConfirmTag)
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
    }

    /// Says which of the two halves ⏎ is currently pointing at, because the two
    /// do different things and the button is the only thing on screen that can
    /// tell them apart.
    private var addButtonLabel: LocalizedStringKey {
        guard highlighted == nil else { return "Add" }
        return "Create and add"
    }

    private var canConfirmTag: Bool {
        guard highlighted == nil else { return true }
        return TagDraft.canSave(tagDraft, among: model.tags)
    }

    /// The left column: everything that already exists, narrowed two ways.
    private var tagPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                sheetLabel("Your tags")
                Spacer(minLength: 0)
                // The count after filtering, so an empty list is visibly the
                // filter's doing rather than the app having lost the tags.
                // `format:` and not interpolation: a bare "\(count)" extracts
                // "%lld" into the String Catalog as a translatable string, which
                // is a key no translator can do anything with.
                Text(tagChoices.count, format: .number)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            TextField("Search tags", text: $tagText)
                .textFieldStyle(.roundedBorder)
                // On the field, which is what holds focus when this column has
                // it. An arrow key that reaches a single-line text field is
                // spent moving the caret, so this is also the only place the
                // list can be reached without the mouse.
                .onKeyPress(.upArrow) { moveHighlight(-1) }
                .onKeyPress(.downArrow) { moveHighlight(1) }
                // Typing takes the best match, so ⌘T, a few letters and ⏎ is
                // still the whole gesture for the thing this sheet is opened
                // for most.
                //
                // This field used to refuse to highlight anything, and that was
                // right while it was also the name of the tag being made:
                // answering ⏎ with somebody else's tag when a new name had been
                // typed would have been the sheet doing the opposite of what
                // was asked. The field cannot make a tag any more — the right
                // column does that — so the risk it was guarding against is
                // gone, and what is left is a search box that ought to act like
                // one.
                .onChange(of: tagText) { _, text in
                    highlighted = text.isEmpty || tagChoices.isEmpty ? nil : 0
                }
            tagKindFilter
            tagChoiceList
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(width: 250)
    }

    /// The second filter, and it is not invented for this screen: whether a tag
    /// applies itself is the one fact the strip and the manager's list already
    /// single out, each with the same bolt. Sorting by it is what makes a long
    /// list of hand-applied tags stop hiding the two that have rules.
    private var tagKindFilter: some View {
        Picker("Show", selection: $tagKind) {
            ForEach(TagKind.allCases) { kind in
                Text(kind.label).tag(kind)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    /// "this clipping" over one, the count over more.
    ///
    /// Two strings rather than one with `^[…](inflect: true)`, and not only
    /// because "Tag 1 clipping" is what a program says. The branch is on
    /// `count > 1`, so the other side is plural for every number that can reach
    /// it and needs no agreement engine to say so — which matters here, because
    /// this app's `inflect:` markup does not currently work: `Text` strips it
    /// and leaves the singular ("Tag 3 clipping"), and `String(localized:)`
    /// leaks it raw. Seven strings written before this one have the same
    /// problem and are not this change's to fix.
    private var tagSheetTitle: LocalizedStringKey {
        let count = model.selectedItems.count
        guard count > 1 else { return "Tag this clipping" }
        return "Tag \(count) clippings"
    }

    /// The one label with something to explain rather than to name: a tag on
    /// three of five selected clippings is not here, and nothing else on the
    /// sheet would ever say so. Split for the reason `tagSheetTitle` is.
    private var carriedLabel: LocalizedStringKey {
        let count = model.selectedItems.count
        guard count > 1 else { return "On this clipping" }
        return "On all \(count) clippings"
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
            VStack(alignment: .leading, spacing: 6) {
                sheetLabel(carriedLabel)
                Flow {
                    ForEach(carried) { tag in carriedChip(tag) }
                }
            }
            .accessibilityElement(children: .contain)
        }
    }

    /// The capsule the cards and the tag strip already draw, with the way to
    /// take it off added to it.
    ///
    /// A row in a box was the third way this app drew a tag, and it was drawn
    /// that way in the one place a tag is handled rather than read. Chips are
    /// also what makes the set honest: they wrap, so seven of them push the
    /// sheet taller instead of overflowing a fixed box and painting across the
    /// field and the buttons, which is what the rows did.
    ///
    /// Only the ✕ is a button. The chip is a statement of what is on the
    /// clipping, and a whole-capsule target would make "remove" the thing that
    /// happens when you click a label to read it.
    private func carriedChip(_ tag: Tag) -> some View {
        HStack(spacing: 5) {
            // The glyph carries the rule and its colour carries the tag's, the
            // same pairing `tagChip` uses — one element for two facts rather
            // than a dot beside an icon.
            Image(systemName: tag.rule.isActive ? "bolt.fill" : "tag.fill")
                .font(.caption2)
                .foregroundStyle(TagColor.named(tag.color)?.color ?? .secondary)
            Text(tag.name).lineLimit(1)
            Button { remove(tag) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
                    // The glyph is 8pt; the thing you have to hit is not.
                    .frame(width: 14, height: 14)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Remove this tag from the clipping")
            .accessibilityLabel("Remove \(tag.name)")
        }
        .font(.callout)
        .padding(.leading, 9)
        .padding(.trailing, 3)
        .padding(.vertical, 3)
        .background(Color.primary.opacity(0.06), in: Capsule())
    }

    /// The column is a fixed height, so this fills it rather than sizing to its
    /// rows: a list that grew and shrank as the filter narrowed would move the
    /// filter above it on every keystroke.
    private var tagChoiceList: some View {
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
            // Keeps the keyboard's row on screen. Without it ↓ walks past the
            // last visible row into a highlight nobody can see.
            .onChange(of: highlighted) { _, new in
                guard let new, tagChoices.indices.contains(new) else { return }
                proxy.scrollTo(tagChoices[new].id)
            }
        }
        .scrollIndicators(.never)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
        .overlay { if tagChoices.isEmpty { emptyChoices } }
        .accessibilityElement(children: .contain)
    }

    /// Which of the three reasons the list is empty, because they ask different
    /// things of the reader: make one, widen the filter, or stop — there is
    /// nothing left to add.
    private var emptyChoices: some View {
        Text(emptyChoicesNote)
            .font(.caption)
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 12)
    }

    private var emptyChoicesNote: LocalizedStringKey {
        guard !model.tags.isEmpty else { return "No tags yet. Make the first one on the right." }
        guard tagText.isEmpty, tagKind == .all else { return "No tag matches this search." }
        return "Every tag you have is already on this."
    }

    /// Names a region of the sheet. Two of them, and they are the whole reason
    /// the sheet reads at all now: what is on the clipping and what can be put
    /// on it were two identical grey boxes, told apart only by a small ✕ on the
    /// rows of one of them.
    private func sheetLabel(_ key: LocalizedStringKey) -> some View {
        Text(key)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    private var tagChoices: [Tag] {
        model.tagChoices(for: model.selectedItems, matching: tagText)
            .filter(tagKind.accepts)
    }

    /// The second axis the left column filters on.
    ///
    /// Not invented for this screen: whether a tag applies itself is the one
    /// fact the tag strip and the manager's list already single out, each with
    /// the same bolt. This is that distinction made selectable.
    enum TagKind: CaseIterable, Identifiable {
        case all, auto, manual

        var id: Self { self }

        var label: LocalizedStringKey {
            switch self {
            case .all: "All"
            case .auto: "Auto"
            case .manual: "Manual"
            }
        }

        func accepts(_ tag: Tag) -> Bool {
            switch self {
            case .all: true
            case .auto: tag.rule.isActive
            case .manual: !tag.rule.isActive
            }
        }
    }

    /// The dot, the name and the bolt, in the order the tag manager's list
    /// already puts them.
    ///
    /// The bolt is not decoration here, and it was missing: the filter above
    /// this list separates tags that apply themselves from tags that do not, and
    /// a row that does not say which it is leaves the user filtering on a
    /// property they cannot see. The manager's list has carried it all along.
    private func tagChoiceRow(_ tag: Tag, isHighlighted: Bool) -> some View {
        HStack(spacing: 7) {
            Circle()
                .fill(TagColor.named(tag.color)?.color ?? Color.secondary.opacity(0.35))
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            Text(tag.name).lineLimit(1)
            Spacer(minLength: 4)
            if tag.rule.isActive {
                Image(systemName: "bolt.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Applies itself")
            }
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
        // Written through `saveTag` and not `addTag(_:to:)`: the latter makes a
        // tag out of a name alone, which is exactly the tag with no colour and
        // no rule that the right column exists to stop this sheet producing.
        guard TagDraft.canSave(tagDraft, among: model.tags) else { return }
        guard let saved = model.saveTag(tagDraft) else { return }
        attach(saved)
    }

    /// The editor's `onSaved`, and where ⏎ lands once the draft is stored. Puts
    /// the tag on the selection, which is the one thing this sheet does that the
    /// manager does not.
    private func attach(_ tag: Tag) {
        model.addTag(tag.name, to: model.selectedItems)
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
