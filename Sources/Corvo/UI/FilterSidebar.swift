import SwiftUI

/// The apps anything was ever copied from. Every row is a toggle: clicking the
/// active one clears the filter, so the active row is filled rather than merely
/// bolded — "on" has to be legible at a glance for clicking it again to make
/// sense.
///
/// Tags used to live below this list and no longer do: see `HistoryView.tagStrip`
/// for why a column that grows on its own is a bad neighbour for one that does
/// not.
struct FilterSidebar: View {
    @Bindable var model: HistoryModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                sectionTitle("Sources")
                ForEach(model.sources) { source in
                    FilterRow(isOn: model.selectedSource == source.bundleId) {
                        model.selectedSource = model.selectedSource == source.bundleId
                            ? nil : source.bundleId
                    } label: {
                        AppIcon.view(forBundleId: source.bundleId)
                        Text(source.name).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(source.count, format: .number)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 14)
        }
        .scrollIndicators(.never)
        .frame(width: 190)
    }

    private func sectionTitle(_ key: LocalizedStringKey) -> some View {
        Text(key)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.bottom, 3)
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
