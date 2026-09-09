import SwiftUI

/// Type, status, sort and minimum rating filters.
struct FilterSheet: View {
    @Binding var query: SearchQuery
    let onApply: () -> Void

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

                section("Minimum rating") { ratingStepper }

                HStack(spacing: Metrics.gapChips) {
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

    private var ratingStepper: some View {
        // Steps of ten, matching how the API expresses rating (0-100), rather
        // than a slider whose value would rarely land on a round number.
        HStack {
            Text(query.minimumRating.map { "\($0)+" } ?? "Any")
                .typeBody()
                .foregroundStyle(Palette.textPrimary)
            Spacer()
            Stepper(
                "",
                value: Binding(
                    get: { query.minimumRating ?? 0 },
                    set: { query.minimumRating = $0 == 0 ? nil : $0 }
                ),
                in: 0...100,
                step: 10
            )
            .labelsHidden()
        }
        .padding(.horizontal, 14)
        .frame(height: Metrics.field)
        .background(Palette.surfaceChip)
        .clipShape(RoundedRectangle(cornerRadius: Metrics.radiusCard, style: .continuous))
    }
}
