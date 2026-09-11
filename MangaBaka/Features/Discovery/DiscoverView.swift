import SwiftUI

/// The Discover screen: several horizontal cover rows under a large title.
struct DiscoverView: View {
    @State private var model: DiscoverModel
    /// Bumped when a pull-to-refresh lands, for the haptic; see `Haptics`.
    @State private var refreshes = 0
    private let recentlyViewed: RecentlyViewedModel?
    @Binding private var path: [Series]
    /// Which cover the reader tapped, so the detail page can grow out of that
    /// one. See `open(_:from:)`.
    @Binding private var zoomSource: String?
    private let namespace: Namespace.ID
    private let onOpenStack: () -> Void
    /// The database's pulse, and the reader's own place in it.
    private let pulse: CommunityPulseService?
    private let chaptersRead: Int
    @Environment(\.displayScale) private var displayScale

    init(
        model: DiscoverModel,
        recentlyViewed: RecentlyViewedModel? = nil,
        path: Binding<[Series]>,
        zoomSource: Binding<String?>,
        namespace: Namespace.ID,
        pulse: CommunityPulseService? = nil,
        chaptersRead: Int = 0,
        onOpenStack: @escaping () -> Void
    ) {
        _model = State(initialValue: model)
        self.recentlyViewed = recentlyViewed
        _path = path
        _zoomSource = zoomSource
        self.namespace = namespace
        self.pulse = pulse
        self.chaptersRead = chaptersRead
        self.onOpenStack = onOpenStack
    }

    /// Opens a series, remembering which cover it came from.
    ///
    /// The same series can appear in two rows at once — rising and hidden gems
    /// share entries constantly — so the transition cannot be keyed on the
    /// series alone: two views would claim the same source id and the match
    /// would be ambiguous. The row is part of the key, and the tapped id is
    /// recorded here because the destination is built afterwards and has no
    /// other way to know which cover the reader actually touched.
    private func open(_ series: Series, from row: String) {
        zoomSource = "\(row)#\(series.id)"
        path.append(series)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.sectionGap) {
                header

                // Under the title, above the content, and it scrolls away with
                // both. Pinned, it would be a permanent accusation about a
                // screen that is working.
                if let detail = model.staleDetail {
                    StaleBar(headline: "Showing what you had", detail: detail) {
                        await model.load(forceRefresh: true)
                    }
                }

                openTheStack

                // Above the API's rows because it is the only one built from
                // what this reader actually did.
                if let recentlyViewed {
                    RecentlyViewedRow(model: recentlyViewed, namespace: namespace) {
                        open($0, from: "recent")
                    }
                }

                if model.isCompletelyEmpty {
                    emptyState
                } else {
                    ForEach(model.rows) { row in
                        rowView(row)
                    }
                    // Last, under the feeds. It is a grace note about the
                    // place, not a reason anyone opened the app.
                    if let figures = pulse?.pulse {
                        CommunityPulseCard(pulse: figures, chaptersRead: chaptersRead)
                    }
                }
            }
            .padding(.top, Metrics.scrollTopInset)
            .padding(.bottom, Metrics.scrollBottomInset)
        }
        .scrollIndicators(.hidden)
        .background(Palette.ground)
        .scrollEdge()
        .refreshable {
            await model.load(forceRefresh: true)
            refreshes += 1
        }
        // The rows are new; say so without a toast.
        .haptic(Haptics.refreshed, onEach: refreshes)
        .task { await model.load() }
        .task { await recentlyViewed?.load() }
        .task { await pulse?.load() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Discover")
                .typeScreenTitle()
                .foregroundStyle(Palette.textPrimary)
            Text(todayLine)
                .typeSubtitle()
                .foregroundStyle(Palette.textSecondary)
        }
        .padding(.horizontal, Metrics.gutter)
    }

    /// "Tuesday · 1,284 series cached". Both halves are real: the weekday from
    /// the clock, the count from the database. The mockup's third clause
    /// ("nothing waiting on a spinner") is dropped — it is a claim about
    /// performance that the app cannot verify at render time.
    private var todayLine: String {
        let weekday = Date().formatted(.dateTime.weekday(.wide))
        guard model.cachedCount > 0 else { return weekday }
        return "\(weekday) · \(model.cachedCount.formatted()) series cached"
    }

    /// The mockup opens Discover with a shortcut into the stack.
    ///
    /// DEVIATION: its subtitle reads "N left in today's stack". Discover cannot
    /// know that without duplicating the stack's queue and reaction logic, and
    /// a wrong number is worse than a plain one, so this says what the control
    /// does instead.
    private var openTheStack: some View {
        Button { onOpenStack() } label: {
            HStack(spacing: 10) {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Palette.onAccent)
                    .frame(width: 26, height: 26)
                    .background(Palette.accent, in: RoundedRectangle(
                        cornerRadius: 9, style: .continuous
                    ))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Open the stack")
                        .typeRowTitle()
                        .foregroundStyle(Palette.textPrimary)
                    Text("Swipe covers to find something new")
                        .typeSmallMeta()
                        .foregroundStyle(Palette.textMuted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 13)
            .background { Glass.floating(RoundedRectangle(
                cornerRadius: Metrics.radiusCard, style: .continuous
            )) }
            .contentShape(RoundedRectangle(cornerRadius: Metrics.radiusCard, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, Metrics.gutter)
        .padding(.top, 16)
    }

    @ViewBuilder
    private func rowView(_ row: DiscoverModel.Row) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                SectionHeader(title: row.title)
                Spacer(minLength: 0)
                Text(row.more)
                    .typeInstruction()
                    .foregroundStyle(Palette.accent)
                    .padding(.trailing, Metrics.gutter)
            }

            if row.isLoading && row.series.isEmpty {
                skeletonRow
            } else if row.series.isEmpty {
                Text("Nothing here right now.")
                    .typeSmallMeta()
                    .foregroundStyle(Palette.textMuted)
                    .padding(.horizontal, Metrics.gutter)
            } else {
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: Metrics.gapCovers) {
                        ForEach(row.series) { series in
                            Button { open(series, from: row.id) } label: {
                                CoverCard(series: series, meta: Self.meta(for: series))
                            }
                            .buttonStyle(.plain)
                            // The detail page grows out of this cover rather
                            // than sliding in over it, which is what makes the
                            // tap read as opening the thing you touched.
                            .matchedTransitionSource(id: "\(row.id)#\(series.id)", in: namespace)
                            // Fetch when the reader reaches the run-up to the
                            // end, not the end itself: by the time the last
                            // card is visible it is already too late to load
                            // without a visible stall.
                            .onAppear {
                                prefetchCovers(after: series, in: row)
                                guard shouldPrefetch(series, in: row) else { return }
                                Task { await model.loadMore(row.id) }
                            }
                        }

                        if row.isLoadingMore {
                            ProgressView()
                                .tint(Palette.textTertiary)
                                .frame(
                                    width: Metrics.coverRowWidth,
                                    height: Metrics.coverRowWidth / Metrics.coverAspect
                                )
                        }
                    }
                    .padding(.horizontal, Metrics.gutter)
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    /// Asks for the next few covers before they are on screen.
    ///
    /// Without this a cover only started downloading once it was already
    /// visible, so scrolling a row showed a BlurHash and then a pop-in for
    /// every card. Three ahead is about one flick of a thumb; more would be
    /// spending someone's data on covers they may never reach.
    private func prefetchCovers(after series: Series, in row: DiscoverModel.Row) {
        guard let index = row.series.firstIndex(where: { $0.id == series.id }) else { return }
        let upcoming = row.series
            .dropFirst(index + 1)
            .prefix(3)
            .map { $0.cover.url(forHeight: Metrics.coverRowWidth / Metrics.coverAspect,
                                scale: displayScale) }
        CoverStore.shared.prefetch(upcoming)
    }

    /// "Manhwa · 8.6". Each half only when the API supplied it.
    static func meta(for series: Series) -> String? {
        var parts: [String] = []
        if let type = series.type, !type.isEmpty { parts.append(type.capitalized) }
        if let rating = series.rating { parts.append(String(format: "%.1f", rating / 10)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// How far from the end of a row to start fetching the next page.
    /// Four cards is roughly one screen width at the row's cover size.
    private static let prefetchDistance = 4

    private func shouldPrefetch(_ series: Series, in row: DiscoverModel.Row) -> Bool {
        guard row.canLoadMore,
              let index = row.series.firstIndex(where: { $0.id == series.id })
        else { return false }
        return index >= row.series.count - Self.prefetchDistance
    }

    private var skeletonRow: some View {
        HStack(spacing: Metrics.gapCovers) {
            ForEach(0..<3, id: \.self) { _ in
                RoundedRectangle(cornerRadius: Metrics.radiusCoverRow, style: .continuous)
                    .fill(Palette.imagePlaceholder)
                    .frame(
                        width: Metrics.coverRowWidth,
                        height: Metrics.coverRowWidth / Metrics.coverAspect
                    )
            }
        }
        .padding(.horizontal, Metrics.gutter)
    }

    private var emptyState: some View {
        FailureState(error: model.failure ?? .offline) {
            await model.load(forceRefresh: true)
        }
    }
}
