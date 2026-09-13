import SwiftUI

/// Type, status, sort and minimum rating filters.
struct FilterSheet: View {
    @Binding var query: SearchQuery
    let onApply: () -> Void
    /// Saving a lens happens here, in the sheet that owns filters, so Search
    /// and Mix both get it without it being designed twice. Absent where a
    /// caller has nowhere to put a lens.
    var onSaveLens: (() -> Void)?
    /// The tag catalogue, so tags can be picked here rather than typed. Absent
    /// where a caller has none to offer.
    var catalogue: CatalogueService?
    /// "Browse offline" — answer from the bundled index and send zero
    /// requests, rather than waiting for the network to actually fail first.
    /// Absent where a caller has nowhere to read or set it (`SeedPickerSheet`,
    /// which builds its own `SearchModel` without wiring offline support).
    var preferOffline: Binding<Bool>?

    @State private var isPickingTags = false
    /// The filters "Clear all" threw away, kept so they can be put back.
    @State private var cleared: SearchQuery?

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
                .arrives(index: 0)

                section("Status") {
                    FlowLayout {
                        ForEach(statuses, id: \.self) { status in
                            chip(status, isOn: query.statuses.contains(status)) {
                                toggle(&query.statuses, status)
                            }
                        }
                    }
                }
                .arrives(index: 1)

                section("Sort") {
                    FlowLayout {
                        ForEach(sorts, id: \.value) { sort in
                            chip(sort.label, isOn: query.sort == sort.value) {
                                query.sort = query.sort == sort.value ? nil : sort.value
                            }
                        }
                    }
                }
                .arrives(index: 2)

                if catalogue != nil {
                    section("Tags") {
                        tagRow
                    }
                    .arrives(index: 3)
                }

                ratingSection
                    .arrives(index: 4)

                yearSection
                    .arrives(index: 5)

                if let preferOffline {
                    section("Offline") {
                        Toggle(isOn: preferOffline) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Browse offline")
                                    .typeRowTitle()
                                    .foregroundStyle(Palette.textPrimary)
                                Text("""
                                Filters the bundled top 20,000 series with no requests. \
                                Covers load when you're back online.
                                """)
                                    .typeSmallMeta()
                                    .foregroundStyle(Palette.textMuted)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .tint(Palette.accent)
                    }
                    .arrives(index: 6)
                }

                HStack(spacing: Metrics.gapChips) {
                    if let onSaveLens {
                        SaveLensButton(isEnabled: !query.isEmpty) {
                            onSaveLens()
                            dismiss()
                        }
                    }

                    // Reversible in place, rather than gone.
                    //
                    // This wiped every filter with no undo and no
                    // confirmation. A confirmation would be worse — a dialog
                    // in front of a sheet to protect a one-tap action — so the
                    // button keeps what it cleared and offers it back. It only
                    // stops offering when the reader changes a filter
                    // themselves, at which point there is nothing coherent to
                    // return to.
                    Button {
                        if let cleared {
                            query = cleared
                            self.cleared = nil
                        } else {
                            cleared = query
                            query = SearchQuery()
                        }
                    } label: {
                        Text(cleared == nil ? "Clear all" : "Undo clear")
                            .typeCTA()
                            .foregroundStyle(Palette.textPrimary)
                            .frame(maxWidth: .infinity)
                            .frame(height: Metrics.ctaSecondary)
                            .background(Palette.surfaceChip)
                            .clipShape(RoundedRectangle(cornerRadius: Metrics.radiusCard, style: .continuous))
                    }
                    .disabled(cleared == nil && query.isEmpty)

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
                        .foregroundStyle(Palette.textMuted)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(Metrics.gutter)
        }
        .scrollIndicators(.hidden)
        .background(Palette.ground)
        .sheet(isPresented: $isPickingTags) {
            if let catalogue {
                TagPickerSheet(
                    catalogue: catalogue,
                    selected: $query.tags,
                    mode: $query.tagMode
                )
            }
        }
    }

    /// The tags currently filtering, and the way in to choose more.
    private var tagRow: some View {
        FlowLayout(spacing: Metrics.gapChips) {
            ForEach(query.tags, id: \.self) { tag in
                Button {
                    query.tags.removeAll { $0 == tag }
                } label: {
                    HStack(spacing: 6) {
                        Text(tag).typeChip()
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                    }
                    .foregroundStyle(Palette.accent)
                    .padding(.horizontal, 12)
                    .frame(height: Metrics.headerPill)
                    .background(Palette.accentTint, in: Capsule())
                    .overlay(Capsule().strokeBorder(Palette.accent.opacity(0.5), lineWidth: 0.5))
                    .tapTarget()
                }
                .buttonStyle(.press)
                .accessibilityLabel("Remove \(tag)")
            }

            // Dashed, because it is a slot rather than a chosen thing.
            Button { isPickingTags = true } label: {
                HStack(spacing: 5) {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Palette.accent)
                    Text("Add tags").typeChip()
                }
                .foregroundStyle(Palette.textPrimary)
                .padding(.horizontal, 12)
                .frame(height: Metrics.headerPill)
                .overlay(Capsule().strokeBorder(Palette.borderDashed, style: StrokeStyle(
                    lineWidth: 0.5, dash: [3]
                )))
                .contentShape(Capsule())
                .tapTarget()
            }
            .buttonStyle(.press)
        }
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
                .tapTarget()
                .animation(Motion.reduced(Motion.snappy), value: isOn)
        }
        .buttonStyle(.press)
        .haptic(Haptics.selection, on: isOn)
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

    /// First-publication-year range. Plain number fields rather than a
    /// slider or wheel — the mockup Abdi will send later replaces this, and
    /// two fields say exactly what they mean without inventing a control.
    /// Offline-only today: see `SearchQuery.yearFrom`'s doc comment.
    private var yearSection: some View {
        section("Year") {
            HStack(spacing: Metrics.gapChips) {
                yearField("From", value: $query.yearFrom)
                yearField("To", value: $query.yearTo)
            }
        }
    }

    private func yearField(_ placeholder: String, value: Binding<Int?>) -> some View {
        TextField(placeholder, text: Binding(
            get: { value.wrappedValue.map(String.init) ?? "" },
            set: { value.wrappedValue = Int($0.filter(\.isNumber)) }
        ))
        .keyboardType(.numberPad)
        .typeChip()
        .foregroundStyle(Palette.textPrimary)
        .padding(.horizontal, 14)
        .frame(height: Metrics.headerPill)
        .frame(maxWidth: .infinity)
        .background(Palette.surfaceChip)
        .clipShape(RoundedRectangle(cornerRadius: Metrics.radiusCard, style: .continuous))
    }
}
