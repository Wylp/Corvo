import SwiftUI

/// Sources and tags. Every row is a toggle: clicking the active one clears the
/// filter, so the active row is filled rather than merely bolded — "on" has to be
/// legible at a glance for clicking it again to make sense.
struct FilterSidebar: View {
    @Bindable var model: HistoryModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if !model.sources.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        sectionTitle("Sources")
                        ForEach(model.sources) { source in
                            FilterRow(isOn: model.selectedSource == source.bundleId) {
                                model.selectedSource = model.selectedSource == source.bundleId
                                    ? nil : source.bundleId
                            } label: {
                                icon(forBundleId: source.bundleId)
                                Text(source.name).lineLimit(1)
                                Spacer(minLength: 4)
                                Text(source.count, format: .number)
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                // Unlike Sources, this section stays put when it is empty: it
                // carries the only way into the tag manager, and a user with no
                // tags yet is exactly who needs to find it.
                VStack(alignment: .leading, spacing: 2) {
                    tagsHeader
                    ForEach(model.tags) { tag in
                        FilterRow(isOn: model.selectedTag == tag.id) {
                            model.selectedTag = model.selectedTag == tag.id ? nil : tag.id
                        } label: {
                            // The glyph carries the rule, the colour carries the
                            // tag's own colour — neither depends on the other.
                            Image(systemName: tag.rule.isActive ? "bolt.fill" : "tag.fill")
                                .frame(width: 16)
                                .foregroundStyle(TagColor.named(tag.color)?.color ?? .secondary)
                            Text(tag.name).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 14)
        }
        .scrollIndicators(.never)
        .frame(width: 190)
    }

    private var tagsHeader: some View {
        HStack(spacing: 4) {
            sectionTitle("Tags")
            Spacer(minLength: 0)
            Button { model.isManagingTags = true } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.caption)
                    .frame(width: 18, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Edit tags and rules (⌘⇧T)")
            .accessibilityLabel("Edit tags and rules")
            .padding(.trailing, 6)
            .padding(.bottom, 3)
        }
    }

    private func sectionTitle(_ key: LocalizedStringKey) -> some View {
        Text(key)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.bottom, 3)
    }

    @ViewBuilder
    private func icon(forBundleId bundleId: String) -> some View {
        if let icon = AppIcon.image(forBundleId: bundleId) {
            Image(nsImage: icon).resizable().frame(width: 16, height: 16)
        } else {
            Image(systemName: "app.dashed").frame(width: 16).foregroundStyle(.secondary)
        }
    }
}

private struct FilterRow<Label: View>: View {
    let isOn: Bool
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) { label() }
                .font(.callout)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(isOn ? Color.accentColor.opacity(0.2) : .clear,
                            in: RoundedRectangle(cornerRadius: 6))
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}
