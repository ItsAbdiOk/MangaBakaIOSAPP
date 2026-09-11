import SwiftUI

/// Choosing a series to blend from, without leaving Mix.
///
/// The "+" used to switch to the Search tab, which keeps its own state — the
/// last query, the last results, and the series page you had pushed onto it.
/// So adding a second seed dropped you back on the page for the first one,
/// and reaching a blank field meant backing out of a screen you never asked
/// for. Reported on 2026-09-10: "it's that endless cycle of it taking you back
/// to whatever you searched for last".
///
/// This is its own search, thrown away when the sheet closes, so every "+"
/// starts empty. It also stays open until the reader is done, because picking
/// three seeds is one job, not three.
struct SeedPickerSheet: View {
    let model: MixModel
    let repository: any SeriesRepositoryProtocol

    @State private var search: SearchModel
    @FocusState private var isFieldFocused: Bool
    @Environment(\.dismiss) private var dismiss

    init(model: MixModel, repository: any SeriesRepositoryProtocol) {
        self.model = model
        self.repository = repository
        _search = State(initialValue: SearchModel(repository: repository))
    }

    private var isFull: Bool { model.seeds.count >= MixModel.maxSeeds }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                field
                chosen
                results
            }
            .background(Palette.ground)
            .navigationTitle("Add a seed")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .edgeSwipeToDismiss()
        // Opens with the keyboard up: the reader tapped "+" to type a name,
        // and a field they have to tap again is a wasted step.
        .task { isFieldFocused = true }
    }

    /// The query as a non-optional binding, written once.
    ///
    /// The field and its clear button both need it, and both had their own
    /// copy of the same `Binding(get:set:)` — two places to change the day the
    /// query stops being an optional string.
    private var queryText: Binding<String> {
        Binding(
            get: { search.query.text ?? "" },
            set: { search.query.text = $0 }
        )
    }

    private var field: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Palette.textTertiary)
            TextField("Search for a series", text: queryText)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .submitLabel(.search)
            .focused($isFieldFocused)
            .typeBody()
            .foregroundStyle(Palette.textPrimary)
            .onSubmit { Task { search.cancelPendingDebounce(); await search.search() } }
            .onChange(of: search.query.text) { _, _ in search.queryDidChange() }

            SearchClearButton(text: queryText, onClear: { search.queryDidChange() })
        }
        .padding(.horizontal, 14)
        .frame(height: Metrics.field)
        .background(Palette.surfaceField, in: RoundedRectangle(
            cornerRadius: Metrics.radiusCard, style: .continuous
        ))
        .padding(.horizontal, Metrics.gutter)
        .padding(.vertical, 12)
    }

    /// What is already picked, so the reader can see when they are done rather
    /// than closing the sheet to check.
    @ViewBuilder
    private var chosen: some View {
        if !model.seeds.isEmpty {
            ScrollView(.horizontal) {
                HStack(spacing: Metrics.gapChips) {
                    ForEach(model.seeds) { series in
                        Button {
                            model.removeSeed(id: series.id)
                        } label: {
                            HStack(spacing: 6) {
                                Text(series.displayTitle ?? "Untitled series")
                                    .typeChip()
                                    .lineLimit(1)
                                Image(systemName: "xmark")
                                    .font(.system(size: 10, weight: .bold))
                            }
                            .foregroundStyle(Palette.textPrimary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Palette.surfaceChip, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove \(series.displayTitle ?? "this seed")")
                    }
                }
                .padding(.horizontal, Metrics.gutter)
            }
            .scrollIndicators(.hidden)
            .padding(.bottom, 12)
        }
    }

    @ViewBuilder
    private var results: some View {
        if search.isSearching && search.results.isEmpty {
            Spacer()
            ProgressView().tint(Palette.textQuaternary)
            Spacer()
        } else if search.results.isEmpty {
            Spacer()
            Text(search.message ?? "Type a title you love.")
                .typeSmallMeta()
                .foregroundStyle(Palette.textMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Metrics.gutter)
            Spacer()
        } else {
            List(search.results) { series in
                row(series)
                    .listRowBackground(Palette.ground)
                    .listRowSeparatorTint(Palette.hairline)
            }
            .listStyle(.plain)
            .scrollDismissesKeyboard(.immediately)
        }
    }

    private func row(_ series: Series) -> some View {
        let isSeed = model.seeds.contains { $0.id == series.id }
        return Button {
            if isSeed {
                model.removeSeed(id: series.id)
            } else {
                model.addSeed(series)
                // Full is the natural end of the job. Anything less and the
                // reader is likely to want another, so the sheet stays.
                if model.seeds.count >= MixModel.maxSeeds { dismiss() }
            }
        } label: {
            HStack(spacing: Metrics.gapCovers) {
                CoverImage(
                    cover: series.cover,
                    width: 44,
                    radius: 8,
                    accessibilityText: series.displayTitle ?? "Untitled series"
                )
                Text(series.displayTitle ?? "Untitled series")
                    .typeRowTitle()
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(2)
                Spacer(minLength: 8)
                Image(systemName: isSeed ? "checkmark.circle.fill" : "plus.circle")
                    .font(.system(size: 20))
                    .foregroundStyle(isSeed ? Palette.accent : Palette.textTertiary)
            }
            .contentShape(Rectangle())
        }
        // Not disabled when the seeds are full: this row might be one of them,
        // and tapping it is how you take it back out. A disabled row would also
        // fade its own title, which is how the Safe content row lost its label.
        .buttonStyle(.plain)
        .opacity(isFull && !isSeed ? 0.4 : 1)
        .allowsHitTesting(!(isFull && !isSeed))
    }
}
