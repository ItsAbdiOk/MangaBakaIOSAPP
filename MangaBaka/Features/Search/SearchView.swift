import SwiftUI

/// Search, with type/status/sort/rating filters in a sheet.
struct SearchView: View {
    @Bindable var model: SearchModel
    @Binding var path: [Series]

    @State private var showFilters = false

    private let columns = Array(
        repeating: GridItem(.flexible(), spacing: Metrics.gapCovers),
        count: 3
    )

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.sectionGap) {
                Text("Search")
                    .typeScreenTitle()
                    .foregroundStyle(Palette.textPrimary)
                    .padding(.horizontal, Metrics.gutter)

                searchBar
                    .padding(.horizontal, Metrics.gutter)

                content
            }
            .padding(.top, 62)
            .padding(.bottom, Metrics.tabBarClearance)
        }
        .scrollIndicators(.hidden)
        .background(Palette.ground)
        .sheet(isPresented: $showFilters) {
            FilterSheet(query: $model.query) {
                Task { model.cancelPendingDebounce(); await model.search() }
            }
            .presentationDetents([.medium, .large])
            .presentationCornerRadius(Metrics.radiusSheet)
        }
    }

    private var searchBar: some View {
        HStack(spacing: Metrics.gapChips) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Palette.textTertiary)
                TextField("Title, author, or tag", text: Binding(
                    get: { model.query.text ?? "" },
                    set: { model.query.text = $0 }
                ))
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
                .foregroundStyle(Palette.textPrimary)
                .typeBody()
                .onSubmit { Task { model.cancelPendingDebounce(); await model.search() } }
                .onChange(of: model.query.text) { _, _ in model.queryDidChange() }
            }
            .padding(.horizontal, 14)
            .frame(height: Metrics.field)
            .background(Palette.surfaceField)
            .clipShape(RoundedRectangle(cornerRadius: Metrics.radiusCard, style: .continuous))

            Button {
                showFilters = true
            } label: {
                Text("Filters")
                    .typeCTA()
                    .foregroundStyle(Palette.textPrimary)
                    .padding(.horizontal, 16)
                    .frame(height: Metrics.field)
                    .background(Palette.surfaceChip)
                    .clipShape(RoundedRectangle(cornerRadius: Metrics.radiusCard, style: .continuous))
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.query.isEmpty {
            idleState
        } else if model.isSearching {
            ProgressView()
                .tint(Palette.accent)
                .frame(maxWidth: .infinity)
                .padding(.top, 60)
        } else if let message = model.message, model.results.isEmpty {
            errorState(message)
        } else if model.results.isEmpty {
            emptyState
        } else {
            grid
        }
    }

    private var grid: some View {
        VStack(spacing: 0) {
            resultsGrid
            if model.isLoadingMore {
                ProgressView()
                    .tint(Palette.accent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
            }
        }
    }

    private var resultsGrid: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
            ForEach(model.results) { series in
                Button { path.append(series) } label: {
                    CoverCard(series: series, width: 111, radius: Metrics.radiusCoverGrid)
                }
                .buttonStyle(.plain)
                // Two rows from the bottom, so the next page is usually there
                // before the reader arrives rather than after.
                .onAppear {
                    guard shouldPrefetch(series) else { return }
                    Task { await model.loadMore() }
                }
            }
        }
        .padding(.horizontal, Metrics.gutter)
    }

    /// Six results is two rows of the three-column grid.
    private static let prefetchDistance = 6

    private func shouldPrefetch(_ series: Series) -> Bool {
        guard model.hasMore, !model.isLoadingMore,
              let index = model.results.firstIndex(where: { $0.id == series.id })
        else { return false }
        return index >= model.results.count - Self.prefetchDistance
    }

    private var idleState: some View {
        VStack(spacing: 14) {
            Text("Search MangaBaka")
                .typeSubsectionHeader()
                .foregroundStyle(Palette.textPrimary)
            Text("Type a title, or let the shuffle pick something for you.")
                .typeSubtitle()
                .foregroundStyle(Palette.textSecondary)
                .multilineTextAlignment(.center)
            surpriseButton
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 44)
        .padding(.top, 70)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Text("Nothing matched \(displayedQuery)")
                .typeSubsectionHeader()
                .foregroundStyle(Palette.textPrimary)
            Text("Try fewer filters, or a shorter title.")
                .typeSubtitle()
                .foregroundStyle(Palette.textSecondary)
                .multilineTextAlignment(.center)
            surpriseButton
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 44)
        .padding(.top, 70)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 14) {
            Text(message)
                .typeSubsectionHeader()
                .foregroundStyle(Palette.textPrimary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 44)
        .padding(.top, 70)
    }

    private var surpriseButton: some View {
        Button {
            model.query.sort = "random"
            Task { model.cancelPendingDebounce(); await model.search() }
        } label: {
            // The label swaps for a spinner in place rather than the button
            // sitting inert. A random search is a live request against a shared
            // rate limit and can take a second or two; with no feedback the
            // only reasonable conclusion is that the button is broken. (From
            // the idle screen the whole section is replaced by the screen's own
            // spinner; this covers the "nothing matched" screen, where the
            // button stays put.)
            ZStack {
                Text("Surprise me")
                    .typeCTA()
                    .opacity(model.isSearching ? 0 : 1)
                if model.isSearching {
                    ProgressView()
                        .tint(Palette.onAccent)
                }
            }
            .foregroundStyle(Palette.onAccent)
            .padding(.horizontal, 20)
            .frame(height: Metrics.ctaSecondary)
            .background(Palette.accent)
            .clipShape(RoundedRectangle(cornerRadius: Metrics.radiusCard, style: .continuous))
        }
        .disabled(model.isSearching)
        .accessibilityLabel(model.isSearching ? "Finding something" : "Surprise me")
    }

    private var displayedQuery: String {
        let text = (model.query.text ?? "").trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? "these filters" : "\u{201C}\(text)\u{201D}"
    }
}

/// Type, status, sort and minimum rating filters.
private struct FilterSheet: View {
    @Binding var query: SearchQuery
    let onApply: () -> Void

    @Environment(\.dismiss) private var dismiss

    private let types = ["manga", "novel", "manhwa", "manhua", "oel", "other"]
    private let statuses = ["releasing", "completed", "hiatus", "cancelled", "upcoming"]
    private let sorts: [(value: String, label: String)] = [
        ("relevance_desc", "Relevance"),
        ("trending_7d", "Trending (7d)"),
        ("trending_30d", "Trending (30d)"),
        ("score_desc", "Score"),
        ("popularity_desc", "Popularity"),
        ("latest", "Latest"),
        ("random", "Random")
    ]

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
