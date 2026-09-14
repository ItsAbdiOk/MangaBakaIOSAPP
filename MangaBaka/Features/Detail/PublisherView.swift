import SwiftUI

/// A publisher or studio, on its own page: who they are, and everything
/// MangaBaka attributes to them, most popular first.
///
/// Reached by tapping a name on a series page's Publishers row. Abdi,
/// 2026-09-11: "if we click on the publishers then we can get more
/// information about them", and "can I see what else REDICE STUDIO is
/// working on" — a studio with a polished style is a way to find the next
/// series. The series list is the point; the record is the header.
///
/// Two sources, because they cover different names. `/v2/series/search`
/// with `publisher=` answers for anything a series names — REDICE STUDIO
/// gives 60 series — while `/v1/publishers/search` is the directory, and
/// has no entry for REDICE at all (both checked live 2026-09-11). So the
/// list always comes from the search, and the record decorates it when
/// the directory knows the name.
struct PublisherView: View {
    /// Whose page: a publisher or studio (the API's `publisher=`), or a
    /// creator (`staff=`). Same page, different search key; the directory
    /// record only exists for publishers.
    enum Kind: Hashable {
        case publisher, author
    }

    let name: String
    var kind: Kind = .publisher
    let catalogue: CatalogueService
    let repository: any SeriesRepositoryProtocol
    @Binding var path: [Series]
    /// Not injected from `AppServices` yet — this view builds its own
    /// default so it keeps compiling either way, but a fresh instance per
    /// appearance means the Follow button here and a follows list shown
    /// anywhere else (`RemindersSection`) can disagree until the app is
    /// relaunched. See this feature's report for the one shared instance it
    /// should actually be wired to.
    var follows: PublisherFollows = PublisherFollows()

    /// How the list is ordered. Popularity first: "what is this studio
    /// known for"; newest for "what are they doing now" (Abdi, 2026-09-11).
    enum Order: String, CaseIterable {
        // Ascending: MangaBaka's popularity is a rank. See SortOrder.
        case popular = "popularity_asc"
        case newest = "latest"

        var label: String {
            switch self {
            case .popular: "Most popular"
            case .newest: "Newest"
            }
        }
    }

    @State private var order: Order = .popular
    /// The order the grid's current `series` answer. `.task(id: order)`
    /// re-runs on every re-appearance as well as on an order change, and
    /// without this it reset the grid to page 1 on every pop-back from a
    /// series opened in it — two search-window requests and the reader's
    /// place in the grid gone (D-1, fixed on Discover with `hasLoadedOnce`
    /// and not here; screens F10, 2026-09-14). Pull-to-refresh and the
    /// stale bar call `load()` directly and are unaffected.
    @State private var loadedOrder: Order?
    @State private var detail: PublisherDetail?
    @State private var series: [Series] = []
    /// Everything MangaBaka attributes to the name — Shueisha is thousands,
    /// and the header said "100" because that was the page (Abdi's
    /// screenshot, 2026-09-11). From the search response's own
    /// `pagination.count` (`FeedResult.total`); the separate `limit=1` count
    /// request is only spent when that is missing (screens F9, 2026-09-14 —
    /// E F1, fixed on Search a day earlier). Nil until known.
    @State private var total: Int?
    @State private var page = 1
    @State private var hasMore = false
    @State private var isLoadingMore = false
    @State private var isLoading = true
    /// Where the current `series` came from — cache, network, or a network
    /// failure that fell back to cache. Distinct from a bare `failed` flag
    /// so a stale list can still be shown, labelled, instead of collapsing
    /// to the same bare sentence a genuinely empty answer gets (gap 56).
    @State private var origin: FeedResult.Origin = .network
    /// Bumped on every `load()`, so a pull-to-refresh started while
    /// `.task(id: order)` is still landing its own results cannot have the
    /// older call's answer overwrite the newer one (gap 58).
    @State private var loadGeneration = 0
    /// Set when the *next* page failed outright — offline, throttled — kept
    /// separate from `origin` (which describes the first page) so a working
    /// first page and a failed second page can both be shown at once (gap 15).
    @State private var loadMoreFailure: APIError?
    @Environment(\.openURL) private var openURL
    @Environment(\.zoomRoute) private var zoomRoute
    @Environment(ToastCentre.self) private var toasts: ToastCentre?

    /// What the page shows, decided in one place — the same shape
    /// `LibraryModel.screenState` uses, so a publisher's list reads the same
    /// way the library does: loading first, a failure only when there is
    /// nothing to fall back on, and a real empty answer distinguished from
    /// both (gap 56).
    enum ScreenState: Equatable {
        case loading
        case failed(APIError)
        case empty
        case list
    }

    nonisolated static func state(
        series: [Series], origin: FeedResult.Origin, isLoading: Bool
    ) -> ScreenState {
        if isLoading && series.isEmpty { return .loading }
        if case let .staleAfter(error) = origin, series.isEmpty { return .failed(error) }
        if series.isEmpty { return .empty }
        return .list
    }

    private var screenState: ScreenState { Self.state(series: series, origin: origin, isLoading: isLoading) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.detailRowGap) {
                header
                links
                if screenState != .loading { orderPicker }
                if case let .staleAfter(error) = origin, !series.isEmpty {
                    StaleBar(
                        headline: "Showing what you had",
                        detail: error.userFacingMessage,
                        retry: { await load() }
                    )
                    .padding(.horizontal, Metrics.gutter)
                }
                switch screenState {
                case .loading:
                    CoverSkeletonGrid()
                case let .failed(error):
                    FailureState(error: error) { await load() }
                case .empty:
                    EmptyState(
                        title: "Nothing here yet",
                        message: "MangaBaka lists nothing under this name yet."
                    )
                case .list:
                    grid
                }
            }
            .padding(.top, 12)
            .padding(.bottom, Metrics.scrollBottomInset)
        }
        .scrollIndicators(.hidden)
        .background(Palette.ground)
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task(id: order) {
            guard Self.needsLoad(loadedOrder: loadedOrder, order: order, seriesIsEmpty: series.isEmpty) else {
                return
            }
            await load()
            loadedOrder = order
        }
    }

    /// Two chips, the way the Library filters states. A picked chip is the
    /// accent; the other is plain, so which one is on reads at a glance.
    private var orderPicker: some View {
        HStack(spacing: 8) {
            ForEach(Order.allCases, id: \.self) { candidate in
                Button {
                    guard candidate != order else { return }
                    order = candidate
                } label: {
                    Text(candidate.label)
                        .typeChip()
                        .foregroundStyle(candidate == order ? Palette.onAccent : Palette.textPrimary)
                        .padding(.horizontal, 13)
                        .frame(minHeight: Metrics.headerPill + 8)
                        .background(
                            candidate == order ? Palette.accent : Palette.surfaceChip, in: Capsule()
                        )
                        .contentShape(Capsule())
                }
                .buttonStyle(.press)
                .accessibilityAddTraits(candidate == order ? .isSelected : [])
            }
        }
        .padding(.horizontal, Metrics.gutter)
        .sensoryFeedback(Haptics.selection, trigger: order)
    }

    private var followKind: PublisherFollows.Kind {
        kind == .publisher ? .publisher : .author
    }

    /// A plain toggle with a toast, no confirmation dialog: following is
    /// reversible in one tap either way, and warning before an unfollow would
    /// treat "stop hearing about REDICE STUDIO" like deleting something.
    private var followButton: some View {
        let following = follows.isFollowing(name, kind: followKind)
        return Button {
            if following {
                follows.unfollow(name, kind: followKind)
                toasts?.show("Unfollowed \(name)")
            } else {
                follows.follow(name, kind: followKind)
                toasts?.show("Following \(name)")
            }
        } label: {
            Text(following ? "Following" : "Follow")
                .typeChip()
                .foregroundStyle(following ? Palette.textPrimary : Palette.onAccent)
                .padding(.horizontal, 14)
                .frame(minHeight: Metrics.headerPill + 8)
                .background(following ? Palette.surfaceChip : Palette.accent, in: Capsule())
                .overlay(Capsule().strokeBorder(Palette.border, lineWidth: following ? 0.5 : 0))
        }
        .buttonStyle(.press)
        .sensoryFeedback(Haptics.selection, trigger: following)
        .accessibilityLabel(following ? "Following \(name)" : "Follow \(name)")
        .accessibilityHint(
            following ? "Double tap to unfollow" : "Double tap to be notified about new series"
        )
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(name)
                    .typeDetailHeroTitle()
                    .foregroundStyle(Palette.textEmphasis)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                followButton
            }
            if let detail, !detail.summary.isEmpty {
                Text(detail.summary)
                    .typeSmallMeta()
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let text = detail?.description ?? detail?.note, !text.isEmpty {
                Text(text)
                    .typeBody()
                    .foregroundStyle(Palette.textBody)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
            }
        }
        .padding(.horizontal, Metrics.gutter)
    }

    @ViewBuilder
    private var links: some View {
        let usable = (detail?.links ?? []).filter { $0.safeURL != nil }
        if !usable.isEmpty {
            ScrollView(.horizontal) {
                HStack(spacing: Metrics.gapChips) {
                    ForEach(Array(usable.enumerated()), id: \.offset) { _, link in
                        Button {
                            if let url = link.safeURL { openURL(url) }
                        } label: {
                            HStack(spacing: 6) {
                                Text(Self.label(for: link))
                                    .typeChip()
                                    .lineLimit(1)
                                Image(systemName: "arrow.up.right")
                                    .typeSymbol(size: 10, weight: .semibold)
                                    .foregroundStyle(Palette.textMuted)
                            }
                            .foregroundStyle(Palette.textPrimary)
                            .padding(.horizontal, 14)
                            .frame(minHeight: Metrics.headerPill + 8)
                            .background(Palette.surfaceChip, in: Capsule())
                            .overlay(Capsule().strokeBorder(Palette.border, lineWidth: 0.5))
                        }
                        .buttonStyle(.press)
                    }
                }
                .padding(.horizontal, Metrics.gutter)
            }
            .scrollIndicators(.hidden)
        }
    }

    /// "x.com", "instagram.com": the host, which is what a reader
    /// recognises. The API's `type` is "news" for both.
    nonisolated static func label(for link: PublisherDetail.Link) -> String {
        link.safeURL?.host()?.replacingOccurrences(of: "www.", with: "") ?? "Link"
    }

    /// The number beside "From {name}". The real total when the count
    /// endpoint answered; `series.count` only when every page has already
    /// landed, which is the one case that count happens to equal the real
    /// total; nil — hidden, not a guess — otherwise (gap 57: this used to
    /// fall back to `series.count` unconditionally, which is the *page*
    /// size, and printed "100" for a publisher with thousands).
    nonisolated static func headerCount(total: Int?, seriesCount: Int, hasMore: Bool) -> Int? {
        if let total { return total }
        return hasMore ? nil : seriesCount
    }

    /// Whether `.task(id: order)` firing means a load. A re-appearance with
    /// the grid already answering this order is not one; an order change,
    /// a first appearance, or an empty grid (a load that was cancelled or
    /// failed on the way out) is. `nonisolated static` so the rule is
    /// testable without a hosted view (F10).
    nonisolated static func needsLoad(loadedOrder: Order?, order: Order, seriesIsEmpty: Bool) -> Bool {
        loadedOrder != order || seriesIsEmpty
    }

    /// The page the grid now holds after a `loadMore` answer: advanced only
    /// when the page actually landed, so a retry asks for the page that
    /// failed rather than the one after it (F27).
    nonisolated static func nextPage(after page: Int, result: FeedResult) -> Int {
        result.blockingError == nil ? page + 1 : page
    }
}

/// The grid, paging, and the loads that fill both — split from the type
/// above purely for the lint's body-length ceiling; `private` members stay
/// reachable from an extension in the same file.
extension PublisherView {
    var grid: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("From \(name)")
                    .typeDetailSectionHeader()
                    .foregroundStyle(Palette.textPrimary)
                if let count = Self.headerCount(total: total, seriesCount: series.count, hasMore: hasMore) {
                    Text(count.formatted())
                        .typeChip()
                        .foregroundStyle(Palette.textMuted)
                        .countsNotCuts()
                }
            }
            .padding(.horizontal, Metrics.gutter)
            CoverGrid(items: series) { index, item, layout in
                Button {
                    zoomRoute?.source = ZoomRoute.id("publisher", item.id)
                    zoomRoute?.neighbours = series
                    path.append(item)
                } label: {
                    CoverCard(
                        series: item, width: layout.cardWidth, radius: Metrics.radiusCoverGrid,
                        meta: DiscoverView.meta(for: item), sizing: .gridColumn
                    )
                }
                .zoomSource("publisher", item.id)
                .buttonStyle(.press)
                // Two rows from the bottom, as Search does, so the next
                // page is usually there before the reader is.
                .onAppear {
                    guard layout.shouldLoadMore(
                        index: index, count: series.count,
                        hasMore: hasMore, isLoadingMore: isLoadingMore
                    ) else { return }
                    Task { await loadMore() }
                }
            }
            if isLoadingMore {
                ProgressView()
                    .tint(Palette.accent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
            } else if let loadMoreFailure {
                // Gap 15: a failed page 2+ used to leave `hasMore` however the
                // failed `FeedResult` happened to default it, which read
                // identically to having reached the real end of the list —
                // nothing on screen told the two apart.
                InlineFailure(error: loadMoreFailure) { await loadMore() }
                    .padding(.vertical, 12)
            }
        }
    }

    var query: SearchQuery {
        var query = SearchQuery()
        switch kind {
        case .publisher: query.publisher = name
        case .author: query.staff = name
        }
        query.sort = order.rawValue
        query.page = page
        return query
    }

    /// The series list first — it is what the page is for — the total beside
    /// it, and the directory record when the name is known there. A name the
    /// directory lacks (a studio, most often) is not a failure.
    ///
    /// Guarded by `loadGeneration` throughout (gap 58): `.refreshable` and
    /// `.task(id: order)` can both call this, and a slower, older call
    /// landing after a newer one started used to be able to overwrite it —
    /// pull-to-refresh finishing after an order change, or the reverse.
    func load() async {
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        loadMoreFailure = nil
        page = 1
        let result = await repository.search(query)
        guard generation == loadGeneration else { return }
        series = result.series
        origin = result.origin
        // The API's own signal (`pagination.next`), not the filtered count:
        // this list is filtered for `isDiscoverable`/format after the fetch,
        // so a page with one filtered row made `count >= limit` false and
        // stopped paging after page one for any publisher common enough to
        // have one. See FeedResult.hasMore.
        hasMore = result.hasMore
        // Gap 57: falling back to `series.count` here is what printed "100"
        // for Shueisha — the page size, not the total. Hidden instead until
        // the real count answers; see `headerCount`. The search response
        // carries the total itself; `count` — a second request from the
        // same 30/min window — is only for a response that did not
        // (a cached or failed page, F9).
        if let known = result.total {
            total = known
        } else {
            total = await repository.count(query)
            guard generation == loadGeneration else { return }
        }
        // The directory knows publishers, not people.
        if kind == .publisher, detail == nil,
           let id = await catalogue.findPublisher(named: name)?.publisherID {
            guard generation == loadGeneration else { return }
            let found = await catalogue.publisher(id: id)
            guard generation == loadGeneration else { return }
            detail = found
        }
        guard generation == loadGeneration else { return }
        isLoading = false
    }

    /// The next page, appended; a short page is the end. Deduplicated,
    /// because the API repeats a series across pages when its ordering
    /// shifts between requests, and a duplicate id traps ForEach.
    func loadMore() async {
        guard hasMore, !isLoadingMore else { return }
        isLoadingMore = true
        loadMoreFailure = nil
        defer { isLoadingMore = false }
        // Asked for, not yet advanced to: `page += 1` used to run before the
        // request, so a failed page 2 left `page` at 2 and the trailing
        // `InlineFailure`'s retry asked for page 3 — page 2 was never seen
        // (screens F27, 2026-09-14). `SearchModel.loadMore` got this right.
        var next = query
        next.page = page + 1
        let result = await repository.search(next)
        page = Self.nextPage(after: page, result: result)
        let known = Set(series.map(\.id))
        let additions = result.series.filter { !known.contains($0.id) }
        series.append(contentsOf: additions)
        // The API's own signal, not the filtered count — see FeedResult.hasMore.
        //
        // Known gap, not a fix: this has no bounded-retry loop like
        // `SearchModel.loadMore`, and the grid asks for the next page from a
        // cell's `onAppear`. So a page whose rows are all filtered out adds
        // no cells, nothing re-triggers, and the list sits short of the end
        // until the reader scrolls again. Left alone deliberately — a
        // publisher's list is narrow enough that a wholly filtered page is
        // rare, and the alternative is a second copy of the search loop.
        hasMore = result.hasMore
        // Gap 15: a failed page read identically to the real end of the
        // list — `hasMore` on a `.staleAfter` result with nothing new
        // defaults `false`, same as a genuinely finished feed. `blockingError`
        // is nil whenever there is anything to show (including what this
        // page already had), so this only fires when the page truly added
        // nothing and the reason was a real failure.
        if additions.isEmpty { loadMoreFailure = result.blockingError }
    }
}
