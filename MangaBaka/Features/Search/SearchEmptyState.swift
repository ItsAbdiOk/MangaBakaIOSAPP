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
        CoverGrid(items: model.results) { index, series, layout in
            Button {
                open(series)
            } label: {
                CoverCard(
                    series: series,
                    width: layout.cardWidth,
                    radius: Metrics.radiusCoverGrid,
                    meta: Self.meta(for: series),
                    sizing: .gridColumn,
                    quickActions: quickActions(for: series)
                )
            }
            .zoomSource("search", series.id)
            .buttonStyle(.press)
            // The first screen assembles; everything after it just appears.
            // `hasArrived` is per card identity, so a card that survives a
            // results change never re-runs this — only the grid being
            // removed from the tree did that, and it no longer is (R F1).
            .arrives(index: Self.arrivalIndex(position: index, columns: layout.columns))
            .onAppear {
                guard layout.shouldLoadMore(
                    index: index, count: model.results.count,
                    hasMore: model.hasMore, isLoadingMore: model.isLoadingMore
                ) else { return }
                Task { await model.loadMore() }
            }
        }
        .modifier(ResultsLanded(model: model, kind: contentKind))
    }

    /// Opening a result is how most searches end, and Recent only heard
    /// about Return and "Show results" — "typed berserk, tapped the cover"
    /// was never in the list (UX#10, LW §2). `record` refuses blanks itself.
    private func open(_ series: Series) {
        recents.record(model.query.text ?? "")
        zoomRoute?.source = ZoomRoute.id("search", series.id)
        zoomRoute?.neighbours = model.results
        path.append(series)
    }

    /// Hold a result: Save, Mark read, Open — in the cover's own context
    /// menu, beside "Copy cover" (R F3; decision 2026-09-13: wire it). The
    /// two library writes go through `LibraryService.add`, which moves an
    /// entry already tracked rather than failing on it; "Saved" is what a
    /// discovery surface means by save (`StackModel.pushSaveToLibrary`),
    /// and "Mark read" is the completed shelf. Without a library to write
    /// to, only Open is offered.
    private func quickActions(for series: Series) -> CoverQuickActions.Actions {
        var actions = CoverQuickActions.Actions(open: { open(series) })
        if let library {
            actions.save = { write(series, to: .planToRead, via: library, said: "Saved") }
            actions.markRead = { write(series, to: .completed, via: library, said: "Marked read") }
        }
        return actions
    }

    private func write(
        _ series: Series, to state: LibraryEntry.State, via library: any LibraryProviding, said: String
    ) {
        Task {
            do throws(APIError) {
                _ = try await library.add(seriesId: series.id, state: state)
                toasts?.show(said)
            } catch let error {
                toasts?.show(error.userFacingMessage, kind: .failure)
            }
        }
    }

    /// "Manga · 2019 · Releasing". Discover's "Manhwa · 8.6" was built for
    /// browsing, where the score is the point; on a results grid the reader
    /// is asking "is this the one I meant", and a 1990s original next to
    /// its 2019 remake looked identical (R F15). The score is dropped: at
    /// 111pt the meta is one line, and type · year · status already fills
    /// it. Each half only when the API supplied it — `/v2/series/search`
    /// sends `year: null` (curl, 2026-09-13), so online results read
    /// "Manga · Releasing" and only the offline index carries the year.
    nonisolated static func meta(for series: Series) -> String? {
        let parts = [
            DetailHero.typeLabel(series.type),
            series.year.map { String($0) },
            SeriesStatus.label(for: series.status)
        ].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Three rows: the first screen of results on a phone. A guess at how
    /// many cards are visible under the field and heading; past it, a card
    /// only appears by scrolling, and `.arrives` delaying it by up to 270ms
    /// after it entered the viewport left a band of blank cells at the
    /// bottom of every fast scroll (R F14).
    nonisolated static let firstScreenRows = 3

    /// The stagger step for the card at `position`: its place in the first
    /// screen, or 0 — arrive at once — for every card after it.
    nonisolated static func arrivalIndex(position: Int, columns: Int) -> Int {
        position < firstScreenRows * columns ? position : 0
    }

    /// The covers to warm the moment a page lands: the two rows under the
    /// first screen. Discover prefetches three ahead per row with the note
    /// that more is "spending someone's data on covers they may never
    /// reach"; two rows is the same restraint for a grid. The rest of the
    /// page loads as it scrolls in, as before.
    nonisolated static func coverPrefetchRange(count: Int, columns: Int) -> Range<Int> {
        let first = min(count, firstScreenRows * columns)
        return first..<min(count, first + 2 * columns)
    }

    /// What VoiceOver hears when the content area settles (R F7): the
    /// count, or that there is none. Nothing while a request is out — the
    /// dimmed grid is still the previous answer — and nothing on idle.
    nonisolated static func announcement(kind: ContentKind, shown: Int, total: Int?) -> String? {
        switch kind {
        case .results:
            if let total { return "\(total.formatted()) \(total == 1 ? "result" : "results")" }
            return "\(shown) results shown"
        case .empty:
            return "Nothing matched"
        case .idle, .skeleton, .failure:
            return nil
        }
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
        .modifier(ResultsLanded(model: model, kind: contentKind))
    }
}

/// What happens the moment the content area settles on an answer: VoiceOver
/// is told (R F7), and the rows just under the first screen have their
/// covers warmed (R minor). One modifier on both the grid and the empty
/// state — each announces only its own kind, so nothing is said twice.
///
/// Keyed on a token rather than on `contentKind` alone: two empty queries
/// in a row are both `.empty`, and two answers in a row are both
/// `.results`, and each deserves its own announcement. Silent while a
/// request is out, when the grid on screen is still the previous answer.
///
/// `@MainActor` spelled out: `token` reads the model off the main actor
/// and the isolation `ViewModifier` implies is not something to lean on.
@MainActor
struct ResultsLanded: ViewModifier {
    let model: SearchModel
    /// `SearchView.contentKind`, passed in rather than recomputed here so
    /// there is one reading of the state machine, not two that could drift.
    let kind: SearchView.ContentKind

    @Environment(\.displayScale) private var displayScale
    @Environment(\.dynamicTypeSize) private var typeSize

    private struct Token: Equatable {
        let kind: SearchView.ContentKind
        let isWorking: Bool
        let ids: [Int]
        let total: Int?
    }

    private var token: Token {
        Token(
            kind: kind,
            isWorking: model.isSearching || model.isPending,
            ids: model.results.map(\.id),
            total: model.total
        )
    }

    func body(content: Content) -> some View {
        content.onChange(of: token, initial: true) { _, now in
            guard !now.isWorking else { return }
            if let message = SearchView.announcement(kind: now.kind, shown: now.ids.count, total: now.total) {
                AccessibilityNotification.Announcement(message).post()
            }
            guard now.kind == .results else { return }
            prefetchCovers()
        }
    }

    /// Sized for the reference phone's column rather than the measured one
    /// — the variant `Cover.url(forHeight:)` picks is the same across the
    /// 375–430pt phones at 3×, and this runs before the grid has measured.
    private func prefetchCovers() {
        let layout = CoverGridLayout.resolve(
            availableWidth: Metrics.referenceScreenWidth - 2 * Metrics.gutter,
            isAccessibilitySize: typeSize.isAccessibilitySize
        )
        let range = SearchView.coverPrefetchRange(count: model.results.count, columns: layout.columns)
        let urls = model.results[range].map {
            $0.cover.url(forHeight: layout.cardWidth / Metrics.coverAspect, scale: displayScale)
        }
        CoverStore.shared.prefetch(urls)
    }
}
