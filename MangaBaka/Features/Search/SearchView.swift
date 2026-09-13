import SwiftUI

/// Search, with type/status/sort/rating filters in a sheet.
struct SearchView: View {
    @Bindable var model: SearchModel
    @Binding var path: [Series]
    @Environment(\.zoomRoute) private var zoomRoute
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(ToastCentre.self) private var toasts: ToastCentre?
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
                // Saving used to close the sheet with nothing confirming it
                // landed (gap 55) — the reader had no way to tell "saved"
                // from "the tap missed". `save` reports whether it actually
                // did (it refuses an empty query or name), so the toast says
                // which — matching the house wording for a one-word write
                // confirmation (`RootView+Session.swift:291`,
                // `LibraryEditSheet.swift:266`).
                if lenses.save(name: name, query: model.query) {
                    toasts?.show("Lens saved")
                    // A lens saved while the idle screen's own count walk is
                    // still running used to be dropped rather than queued
                    // behind it (gap 53) — asking again here enqueues it, and
                    // `LensCounts.load` now drains a shared queue rather than
                    // a fixed snapshot, so it is picked up before the walk
                    // ends rather than only on the idle screen's next
                    // appearance.
                    counts.load(lenses.own)
                } else {
                    toasts?.show("Couldn't save that lens", kind: .failure)
                }
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
                    // Breathes while a request is out, so the field itself
                    // says "working" without a spinner beside it.
                    .symbolEffect(.pulse, isActive: model.isSearching && !reduceMotion)
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

    @ViewBuilder
    private var headingText: some View {
        // Nil while a new search is in flight, so a heading over the
        // incoming skeleton cannot claim the previous query's count (gap 50:
        // "SearchView.swift:194" used to hold "12 shown" above a grid that
        // was about to show something else entirely).
        if let heading {
            Text(heading)
                .typeSubsectionHeader()
                .foregroundStyle(Palette.textPrimary)
                .countsNotCuts()
                .animation(Motion.reduced(.snappy(duration: 0.25)), value: heading)
                .fixedSize(horizontal: false, vertical: true)
        }
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
            SurpriseMeButton(isSearching: model.isSearching) {
                model.query.sort = "random"
                Task { model.cancelPendingDebounce(); await model.search() }
            }
        }
        .fixedSize()
    }

    /// "12 shown · Score" once anything is asked for, nil before that and
    /// while a new search is in flight.
    private var heading: String? {
        SearchHeading.text(
            isEmpty: model.query.isEmpty,
            isSearching: model.isSearching,
            count: model.results.count,
            sortLabel: SortOrder.label(for: model.query.sort)
        )
    }

    @ViewBuilder
    private var content: some View {
        if model.query.isEmpty {
            SearchIdleView(
                lenses: lenses,
                counts: counts,
                recents: recents,
                onRun: { lens in
                    Task { await model.apply(lens.query) }
                },
                onRunTerm: { term in
                    Task { await model.apply(SearchQuery(text: term)) }
                }
            )
        } else if model.isSearching {
            // The shape of the answer, not a spinner: the grid the results
            // will fill, shimmering, so nothing jumps when they land.
            CoverSkeletonGrid()
        } else if let failure = model.failure, model.results.isEmpty {
            // Nothing to show and the ask failed outright — a full failure
            // screen (gap 7). Search is the one screen decision 4 names for
            // an automatic retry: it is the one place the reader is sitting
            // there waiting on exactly this answer, unlike a background row
            // elsewhere that ticks without retrying itself.
            FailureState(
                error: failure,
                retry: { await model.search() },
                autoRetry: true
            )
        } else if model.results.isEmpty {
            emptyState
        } else {
            grid
        }
    }

    private var grid: some View {
        VStack(spacing: 0) {
            // A failure that still has content to show is not a blocking
            // failure — the last good results stay on screen, under a bar
            // naming why they might be stale, rather than the grid vanishing
            // out from under the reader on every throttled keystroke (gap 7).
            if let failure = model.failure {
                StaleBar(
                    headline: failure.headline,
                    detail: failure.countdown ?? failure.userFacingMessage,
                    retry: { await model.search() }
                )
                .padding(.bottom, 12)
            }
            resultsGrid
            if model.isLoadingMore {
                ProgressView()
                    .tint(Palette.accent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
            } else if let pageFailure = model.pageFailure {
                // A page-2+ request that failed outright used to read as the
                // end of the results (gap 15) — this says otherwise and
                // offers to try that same page again.
                InlineFailure(error: pageFailure) { await model.loadMore() }
                    .padding(.vertical, 16)
            } else if model.stoppedEarly {
                // Gave up after too many filtered-empty pages in a row —
                // not the same as reaching the real end (gap 51), and looked
                // identical to it until now.
                Text("Stopped early — more of this may exist further in.")
                    .typeSmallMeta()
                    .foregroundStyle(Palette.textMuted)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
            }
        }
    }

    private var resultsGrid: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
            ForEach(model.results) { series in
                Button {
                    zoomRoute?.source = ZoomRoute.id("search", series.id)
                    path.append(series)
                } label: {
                    CoverCard(
                        series: series,
                        width: 111,
                        radius: Metrics.radiusCoverGrid,
                        meta: DiscoverView.meta(for: series)
                    )
                }
                .zoomSource("search", series.id)
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

    // Internal, not private: the empty state lives in its own file for the
    // lint's ceiling. See SearchEmptyState.swift.
    var displayedQuery: String {
        let text = (model.query.text ?? "").trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? "these filters" : "\u{201C}\(text)\u{201D}"
    }
}

/// The rule behind `SearchView.heading`, pulled out of the view entirely so it
/// is testable without a live `SearchView` (this project has no
/// ViewInspector) — gap 50.
enum SearchHeading {
    /// "shown", not "results": this is the number loaded so far, and a query
    /// matching thousands read "24 results" and then "47 results" as the
    /// reader scrolled — the same query reporting different totals. Nil while
    /// `isSearching`: the count on screen at that instant still describes the
    /// query the reader just left, not the one the skeleton beneath it is
    /// about to answer — `SearchView.swift:194` used to hold the previous
    /// query's count above the incoming skeleton with nothing telling them
    /// apart.
    static func text(isEmpty: Bool, isSearching: Bool, count: Int, sortLabel: String?) -> String? {
        guard !isEmpty, !isSearching else { return nil }
        let text = "\(count) shown"
        guard let sortLabel else { return text }
        return "\(text) · \(sortLabel)"
    }
}

/// "Surprise me" reads as live even while disabled during a search (gap 52).
///
/// Its own small view, rather than a plain `Button` inline, because the text
/// deliberately sets its own colour (`Palette.textSecondary`, to sit a step
/// quieter than "Browse") — and `PressStyle`'s own disabled colour, set on
/// `configuration.label` from the outside, is overridden by a label's own
/// more specific `.foregroundStyle` further in (see `PressStyle`'s doc
/// comment). A label with no opinion dims automatically; one with an opinion,
/// like this one, has to read `isEnabled` itself.
private struct SurpriseMeButton: View {
    let isSearching: Bool
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    private var isActuallyEnabled: Bool { isEnabled && !isSearching }

    var body: some View {
        Button(action: action) {
            Text("Surprise me")
                .typeInstruction()
                .foregroundStyle(isActuallyEnabled ? Palette.textSecondary : Palette.textQuaternary)
                .frame(minHeight: Metrics.headerPill)
                .contentShape(Rectangle())
        }
        .buttonStyle(.press)
        .disabled(!isActuallyEnabled)
    }
}
