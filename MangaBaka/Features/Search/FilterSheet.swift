import SwiftUI

/// Type, status, sort and minimum rating filters.
struct FilterSheet: View {
    @Binding var query: SearchQuery
    let onApply: () -> Void
    /// Saving a lens happens here, in the sheet that owns filters, so Search
    /// and Mix both get it without it being designed twice. Absent where a
    /// caller has nowhere to put a lens.
    var onSaveLens: (() -> Void)?

    @Environment(\.dismiss) private var dismiss

    private let types = ["manga", "novel", "manhwa", "manhua", "oel", "other"]
    private let statuses = ["releasing", "completed", "hiatus", "cancelled", "upcoming"]
    private let sorts = SortOrder.all

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.sectionGap) {
                Text("Filters")
                    .typeSheetTitle()
                    .foregroundStyle(Palette.textPrimary)

                section("Type") {
                    FlowLayout {
                        ForEach(types, id: \.self) { type in
                            chip(type, isOn: query.types.contains(type)) { toggle(&query.types, type) }
                        }
                    }
                }

                section("Status") {
                    FlowLayout {
                        ForEach(statuses, id: \.self) { status in
                            chip(status, isOn: query.statuses.contains(status)) {
                                toggle(&query.statuses, status)
                            }
                        }
                    }
                }

                section("Sort") {
                    FlowLayout {
                        ForEach(sorts, id: \.value) { sort in
                            chip(sort.label, isOn: query.sort == sort.value) {
                                query.sort = query.sort == sort.value ? nil : sort.value
                            }
                        }
                    }
                }

                ratingSection

                HStack(spacing: Metrics.gapChips) {
                    if let onSaveLens {
                        SaveLensButton(isEnabled: !query.isEmpty) {
                            onSaveLens()
                            dismiss()
                        }
                    }

                    Button {
                        query = SearchQuery()
                    } label: {
                        Text("Clear all")
                            .typeCTA()
                            .foregroundStyle(Palette.textPrimary)
                            .frame(maxWidth: .infinity)
                            .frame(height: Metrics.ctaSecondary)
                            .background(Palette.surfaceChip)
                            .clipShape(RoundedRectangle(cornerRadius: Metrics.radiusCard, style: .continuous))
                    }

                    Button {
                        onApply()
                        dismiss()
                    } label: {
                        Text("Show results")
                            .typeCTA()
                            .foregroundStyle(Palette.onAccent)
                            .frame(maxWidth: .infinity)
                            .frame(height: Metrics.ctaSecondary)
                            .background(Palette.accent)
                            .clipShape(RoundedRectangle(cornerRadius: Metrics.radiusCard, style: .continuous))
                    }
                }

                if onSaveLens != nil {
                    Text("The bookmark saves this as a lens. Greyed until a filter is set.")
                        .typeFootnote()
                        .foregroundStyle(Palette.textQuaternary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(Metrics.gutter)
        }
        .scrollIndicators(.hidden)
        .background(Palette.ground)
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            Text(title)
                .typeSubsectionHeader()
                .foregroundStyle(Palette.textPrimary)
            content()
        }
    }

    private func chip(_ label: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label.capitalized)
                .typeChip()
                .foregroundStyle(isOn ? Palette.onAccent : Palette.textSecondary)
                .padding(.horizontal, 14)
                .frame(height: Metrics.headerPill)
                .background(isOn ? Palette.accent : Palette.surfaceChip)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func toggle(_ collection: inout [String], _ value: String) {
        if let index = collection.firstIndex(of: value) {
            collection.remove(at: index)
        } else {
            collection.append(value)
        }
    }

    /// The mockup names the current value beside the heading in the accent,
    /// so the control says what it is set to without the reader parsing five
    /// segments to find the lit one.
    private var ratingSection: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .firstTextBaseline) {
                Text("Minimum rating")
                    .typeSubsectionHeader()
                    .foregroundStyle(Palette.textPrimary)
                Spacer(minLength: 8)
                Text(RatingSegments.label(for: query.minimumRating))
                    .typeChip()
                    .foregroundStyle(Palette.accent)
            }
            RatingSegments(minimum: $query.minimumRating)
        }
    }
}
