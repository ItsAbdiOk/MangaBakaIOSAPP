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
    let name: String
    let catalogue: CatalogueService
    let repository: any SeriesRepositoryProtocol
    @Binding var path: [Series]

    @State private var detail: PublisherDetail?
    @State private var series: [Series] = []
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
        .task { await load() }
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
                Text("\(series.count)")
                    .typeChip()
                    .foregroundStyle(Palette.textMuted)
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
                }
            }
            .padding(.horizontal, Metrics.gutter)
        }
    }

    /// The series list first — it is what the page is for — and the
    /// directory record beside it when the name is known there. A name the
    /// directory lacks (a studio, most often) is not a failure.
    private func load() async {
        isLoading = true
        failed = false
        var query = SearchQuery(publisher: name)
        query.sort = "popularity_desc"
        // One page, larger than Search's: REDICE STUDIO is 60 series and the
        // first cut showed 30 of them under a header saying 30.
        query.limit = 100
        async let found = repository.search(query)
        async let record = catalogue.findPublisher(named: name)
        let result = await found
        series = result.series
        if case .staleAfter = result.origin { failed = series.isEmpty }
        if let id = await record?.publisherID {
            detail = await catalogue.publisher(id: id)
        }
        isLoading = false
    }
}
