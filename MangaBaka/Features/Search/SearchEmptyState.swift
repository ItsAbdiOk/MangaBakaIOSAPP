import SwiftUI

/// What the Search tab says when a query comes back with nothing.
///
/// Its own file for the lint's body-length ceiling, and because it is one idea:
/// an empty result is only honest if it says why. "Nothing matched 'one piece'"
/// was true and useless — a tag picked on another screen was still applied, and
/// nothing on the page said so.
extension SearchView {
    /// What `content` actually shows, decided in one pure place — mirrors
    /// `MixResults.ResultsState` — so the swap between them can be tested
    /// without ViewInspector (this project has none) and so the view keying
    /// its arrival animation off this has a single value, rather than
    /// re-animating on every incidental change inside one branch (a result
    /// arriving inside `.results`, say). Lives here rather than in
    /// `SearchView.swift` for the lint's type-length ceiling.
    enum ContentKind: Equatable {
        case idle, skeleton, failure, empty, results
    }

    /// Decided from what was *asked* and whether an answer is *pending* —
    /// never from `query.isEmpty`. Reading the query made a Type chip tapped
    /// on the idle panel (a query with nothing asked) render as "Nothing
    /// matched these filters" (UX#1, 2026-09-13 walk), and made the ≥300 ms
    /// debounce after a first keystroke render the same way (E F4). And a
    /// grid with content stays put while the next answer is on its way —
    /// swapping it for the skeleton on every pause re-ran a second of blur
    /// and stagger over results that were mostly the same (R F1); the view
    /// dims it instead.
    nonisolated static func contentKind(
        hasAsked: Bool,
        isPending: Bool,
        isSearching: Bool,
        hasBlockingFailure: Bool,
        resultsEmpty: Bool
    ) -> ContentKind {
        if !hasAsked { return .idle }
        if !resultsEmpty { return .results }
        if isPending || isSearching { return .skeleton }
        if hasBlockingFailure { return .failure }
        return .empty
    }

    var contentKind: ContentKind {
        Self.contentKind(
            hasAsked: model.hasAsked,
            isPending: model.isPending,
            isSearching: model.isSearching,
            hasBlockingFailure: model.failure != nil && model.results.isEmpty,
            resultsEmpty: model.results.isEmpty
        )
    }

    // Moved from `SearchView.swift` for the lint's type-length ceiling.
    var resultsGrid: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
            ForEach(Array(model.results.enumerated()), id: \.element.id) { index, series in
                Button {
                    // Opening a result is how most searches end, and Recent
                    // only heard about Return and "Show results" — "typed
                    // berserk, tapped the cover" was never in the list
                    // (UX#10, LW §2). `record` refuses blanks itself.
                    recents.record(model.query.text ?? "")
                    zoomRoute?.source = ZoomRoute.id("search", series.id)
                    zoomRoute?.neighbours = model.results
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
                // `Motion.stagger` caps at 6 steps on its own — the grid
                // assembles rather than queuing for a long list of results.
                .arrives(index: index)
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

    func shouldPrefetch(_ series: Series) -> Bool {
        guard model.hasMore, !model.isLoadingMore,
              let index = model.results.firstIndex(where: { $0.id == series.id })
        else { return false }
        return index >= model.results.count - Self.prefetchDistance
    }

    /// Names the filters where there are any. "Try a looser filter" is advice;
    /// "3 filters are still applied" is the answer.
    var emptyAdvice: String {
        let count = model.query.activeFilterCount
        guard count > 0 else { return "Try a looser filter, or let the API pick." }
        return count == 1
            ? "One filter is still applied."
            : "\(count) filters are still applied."
    }

    var emptyState: some View {
        VStack(spacing: 0) {
            Text("Nothing matched \(displayedQuery)")
                .typeBody()
                .foregroundStyle(Palette.textPrimary)
            Text(emptyAdvice)
                .typeInstruction()
                .foregroundStyle(Palette.textTertiary)
                .multilineTextAlignment(.center)
                .padding(.top, 8)

            if model.query.activeFilterCount > 0 {
                Button {
                    Task { await model.clearFilters() }
                } label: {
                    Text("Clear filters")
                        .typeRowTitle()
                        .foregroundStyle(Palette.textPrimary)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 11)
                        .background(Palette.surfaceChip, in: Capsule())
                }
                .buttonStyle(.press)
                .padding(.top, 16)
            }
            Button {
                Task { await model.surpriseMe() }
            } label: {
                Text("Random with these filters")
                    .typeRowTitle()
                    .foregroundStyle(Palette.onAccent)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 11)
                    .background(Palette.accent, in: Capsule())
            }
            .buttonStyle(.press)
            .padding(.top, 16)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 8)
        .padding(.vertical, 34)
    }
}
