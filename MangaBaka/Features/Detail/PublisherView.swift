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
    @State private var detail: PublisherDetail?
    @State private var series: [Series] = []
    /// Everything MangaBaka attributes to the name, from the count endpoint —
    /// Shueisha is thousands, and the header said "100" because that was the
    /// page (Abdi's screenshot, 2026-09-11). Nil until counted.
    @State private var total: Int?
    @State private var page = 1
    @State private var hasMore = false
    @State private var isLoadingMore = false
    @State private var isLoading = true
    @State private var failed = false
    @Environment(\.openURL) private var openURL
    @Environment(\.zoomRoute) private var zoomRoute

    private let columns = Array(
        repeating: GridItem(.flexible(), spacing: Metrics.gapCovers), count: 3
    )

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.detailRowGap) {
                header
                links
                if !isLoading || !series.isEmpty { orderPicker }
                if isLoading {
                    CoverSkeletonGrid()
                } else if series.isEmpty {
                    Text(failed ? "Couldn't reach MangaBaka. Pull to try again."
                                : "MangaBaka lists nothing under this name yet.")
                        .typeSmallMeta()
                        .foregroundStyle(Palette.textMuted)
                        .padding(.horizontal, Metrics.gutter)
                } else {
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
        .task(id: order) { await load() }
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

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(name)
                .typeDetailHeroTitle()
                .foregroundStyle(Palette.textEmphasis)
                .fixedSize(horizontal: false, vertical: true)
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
                                    .font(.system(size: 10, weight: .semibold))
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

    private var grid: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("From \(name)")
                    .typeDetailSectionHeader()
                    .foregroundStyle(Palette.textPrimary)
                Text((total ?? series.count).formatted())
                    .typeChip()
                    .foregroundStyle(Palette.textMuted)
                    .countsNotCuts()
            }
            .padding(.horizontal, Metrics.gutter)
            LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                ForEach(series) { item in
                    Button {
                        zoomRoute?.source = ZoomRoute.id("publisher", item.id)
                        path.append(item)
                    } label: {
                        CoverCard(
                            series: item, width: 111, radius: Metrics.radiusCoverGrid,
                            meta: DiscoverView.meta(for: item)
                        )
                    }
                    .zoomSource("publisher", item.id)
                    .buttonStyle(.press)
                    // Two rows from the bottom, as Search does, so the next
                    // page is usually there before the reader is.
                    .onAppear {
                        guard hasMore, !isLoadingMore,
                              let index = series.firstIndex(where: { $0.id == item.id }),
                              index >= series.count - 6
                        else { return }
                        Task { await loadMore() }
                    }
                }
            }
            .padding(.horizontal, Metrics.gutter)
            if isLoadingMore {
                ProgressView()
                    .tint(Palette.accent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
            }
        }
    }

    private var query: SearchQuery {
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
    private func load() async {
        isLoading = true
        failed = false
        page = 1
        async let found = repository.search(query)
        async let counted = repository.count(query)
        let result = await found
        series = result.series
        // The API's own signal (`pagination.next`), not the filtered count:
        // this list is filtered for `isDiscoverable`/format after the fetch,
        // so a page with one filtered row made `count >= limit` false and
        // stopped paging after page one for any publisher common enough to
        // have one. See FeedResult.hasMore.
        hasMore = result.hasMore
        if case .staleAfter = result.origin { failed = series.isEmpty }
        total = await counted
        // The directory knows publishers, not people.
        if kind == .publisher, detail == nil,
           let id = await catalogue.findPublisher(named: name)?.publisherID {
            detail = await catalogue.publisher(id: id)
        }
        isLoading = false
    }

    /// The next page, appended; a short page is the end. Deduplicated,
    /// because the API repeats a series across pages when its ordering
    /// shifts between requests, and a duplicate id traps ForEach.
    func loadMore() async {
        guard hasMore, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        page += 1
        let result = await repository.search(query)
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
    }
}
