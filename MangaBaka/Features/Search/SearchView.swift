import SwiftUI

/// Search, with type/status/sort/rating filters in a sheet.
struct SearchView: View {
    @Bindable var model: SearchModel
    @Binding var path: [Series]
    /// Opens the genre and tag browser.
    ///
    /// Lives in the screen's own header rather than the navigation bar: the
    /// app's custom top bar is drawn over the navigation bar on a root screen,
    /// so a toolbar button there was clipped to a sliver at the screen edge.
    let onBrowse: () -> Void
    let lenses: SearchLensStore
    let counts: LensCounts
    let catalogue: CatalogueService
    let recents: RecentSearches

    @State private var isNamingLens = false

    @State private var showFilters = false

    private let columns = Array(
        repeating: GridItem(.flexible(), spacing: Metrics.gapCovers),
        count: 3
    )

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.sectionGap) {
                searchBar
                    .padding(.horizontal, Metrics.gutter)

                // A heading and two links. Kept on one row until they no
                // longer fit: squeezed by both links, "30 results" broke into
                // "30" / "result" / "s" at the largest text size.
                //
                // The heading is absent while the screen is idle: the idle
                // screen carries its own section headers, and a standing
                // "Saved lenses" title sat above a Presets section even when
                // the reader had saved none — announcing a thing that was not
                // there.
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        if !model.query.isEmpty { headingText }
                        Spacer(minLength: 0)
                        headerActions
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        if !model.query.isEmpty { headingText }
                        headerActions
                    }
                }
                .padding(.horizontal, Metrics.gutter + 2)

                content
            }
            .padding(.top, Metrics.scrollTopInset)
            .padding(.bottom, Metrics.scrollBottomInset)
        }
        .scrollIndicators(.hidden)
        .background(Palette.ground)
        .scrollEdge()
        // The end of the results, felt: "no more" is different from "still
        // loading", and nothing on screen says which until now.
        .sensoryFeedback(Haptics.settled, trigger: model.hasMore) { old, new in
            old && !new && !model.results.isEmpty
        }
        .sheet(isPresented: $isNamingLens) {
            SaveLensSheet(query: model.query) { name in
                lenses.save(name: name, query: model.query)
            }
            .presentationDetents([.height(420)])
            .presentationCornerRadius(Metrics.radiusSheet)
        }
        .sheet(isPresented: $showFilters) {
            FilterSheet(
                query: $model.query,
                onApply: {
                    Task { model.cancelPendingDebounce(); await model.search() }
                },
                onSaveLens: { isNamingLens = true },
                catalogue: catalogue
            )
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
                .onSubmit {
                    recents.record(model.query.text ?? "")
                    Task { model.cancelPendingDebounce(); await model.search() }
                }
                .onChange(of: model.query.text) { _, _ in model.queryDidChange() }

                SearchClearButton(
                    text: Binding(
                        get: { model.query.text ?? "" },
                        set: { model.query.text = $0 }
                    ),
                    // Clearing is a search in its own right: the results for a
                    // query that no longer exists must not stay on screen.
                    onClear: { model.queryDidChange() }
                )
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

    private var headingText: some View {
        Text(heading)
            .typeSubsectionHeader()
            .foregroundStyle(Palette.textPrimary)
            .countsNotCuts()
            .animation(Motion.reduced(.snappy(duration: 0.25)), value: heading)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Two actions of different weight, drawn differently.
    ///
    /// They were three same-weight accent links — "Browse", "Surprise me" and
    /// the recents "Clear" below — which told the reader nothing about which
    /// one to reach for. Browse opens a whole other surface and is the one
    /// worth finding, so it takes a chip; "Surprise me" reorders the results
    /// you already have and stays a plain link.
    private var headerActions: some View {
        HStack(spacing: 12) {
            Button(action: onBrowse) {
                Text("Browse")
                    .typeInstruction()
                    .foregroundStyle(Palette.accent)
                    .padding(.horizontal, 13)
                    .frame(minHeight: Metrics.headerPill)
                    .background(Palette.accentTint, in: Capsule())
                    .overlay(Capsule().strokeBorder(Palette.accent.opacity(0.4), lineWidth: 0.5))
                    .contentShape(Capsule())
            }
            .buttonStyle(.press)
            Button {
                model.query.sort = "random"
                Task { model.cancelPendingDebounce(); await model.search() }
            } label: {
                Text("Surprise me")
                    .typeInstruction()
                    .foregroundStyle(Palette.textSecondary)
                    .frame(minHeight: Metrics.headerPill)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.press)
            .disabled(model.isSearching)
        }
        .fixedSize()
    }

    /// "12 results · Score" once anything is asked for. Nothing before that —
    /// see the note where it is used.
    private var heading: String {
        guard !model.query.isEmpty else { return "" }
        // "shown", not "results": this is the number loaded so far, and a query
        // matching thousands read "24 results" and then "47 results" as the
        // reader scrolled — the same query reporting different totals.
        let count = "\(model.results.count) shown"
        guard let sort = SortOrder.label(for: model.query.sort) else { return count }
        return "\(count) · \(sort)"
    }

    @ViewBuilder
    private var content: some View {
        if model.query.isEmpty {
            SearchIdleView(
                lenses: lenses,
                counts: counts,
                recents: recents,
                onRun: { lens in
                    model.query = lens.query
                    Task { model.cancelPendingDebounce(); await model.search() }
                },
                onRunTerm: { term in
                    model.query = SearchQuery(text: term)
                    Task { model.cancelPendingDebounce(); await model.search() }
                }
            )
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
                    CoverCard(
                        series: series,
                        width: 111,
                        radius: Metrics.radiusCoverGrid,
                        meta: DiscoverView.meta(for: series)
                    )
                }
                .buttonStyle(.press)
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

    // Internal, not private: the empty state lives in its own file for the
    // lint's ceiling. See SearchEmptyState.swift.
    var displayedQuery: String {
        let text = (model.query.text ?? "").trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? "these filters" : "\u{201C}\(text)\u{201D}"
    }
}
