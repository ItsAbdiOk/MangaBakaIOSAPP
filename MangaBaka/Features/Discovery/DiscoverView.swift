import SwiftUI

/// The Discover screen: several horizontal cover rows under a large title.
struct DiscoverView: View {
    /// What the reader is part-way through, shown first — Abdi, 2026-09-13:
    /// "put this at the top of the discovery page". Empty hides the row.
    var inProgress: [LibraryEntry] = []
    @State private var model: DiscoverModel
    /// Bumped when a pull-to-refresh lands, for the haptic; see `Haptics`.
    @State private var refreshes = 0
    private let recentlyViewed: RecentlyViewedModel?
    @Binding private var path: [Series]
    /// Which cover the reader tapped, so the detail page can grow out of that
    /// one. See `open(_:from:)`.
    @Environment(\.zoomRoute) private var zoomRoute
    /// The database's pulse, and the reader's own place in it.
    private let pulse: CommunityPulseService?
    private let chaptersRead: Int
    @Environment(\.displayScale) private var displayScale
    /// The card that says what this build added; see `ReleaseNotes`.
    private let whatsNew: WhatsNewState?
    private let hasCompletedOnboarding: Bool

    init(
        model: DiscoverModel,
        inProgress: [LibraryEntry] = [],
        recentlyViewed: RecentlyViewedModel? = nil,
        path: Binding<[Series]>,
        pulse: CommunityPulseService? = nil,
        chaptersRead: Int = 0,
        whatsNew: WhatsNewState? = nil,
        hasCompletedOnboarding: Bool = true
    ) {
        self.whatsNew = whatsNew
        self.hasCompletedOnboarding = hasCompletedOnboarding
        _model = State(initialValue: model)
        self.inProgress = inProgress
        self.recentlyViewed = recentlyViewed
        _path = path
        self.pulse = pulse
        self.chaptersRead = chaptersRead
    }

    /// Opens a series, remembering which cover it came from.
    ///
    /// The same series can appear in two rows at once — rising and hidden gems
    /// share entries constantly — so the transition cannot be keyed on the
    /// series alone: two views would claim the same source id and the match
    /// would be ambiguous. The row is part of the key, and the tapped id is
    /// recorded here because the destination is built afterwards and has no
    /// other way to know which cover the reader actually touched.
    private func open(_ series: Series, from row: String, siblings: [Series] = []) {
        zoomRoute?.source = ZoomRoute.id(row, series.id)
        zoomRoute?.neighbours = siblings
        path.append(series)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.sectionGap) {
                header

                // The "Open the stack" card that used to sit here is gone
                // (Abdi, 2026-09-13): the stack has its own tab. What the
                // reader is part-way through leads instead, at the same
                // cover width as every row under it.
                if !inProgress.isEmpty {
                    PickBackUp(entries: inProgress, path: $path, coverWidth: Metrics.coverRowWidth)
                }

                // Under the title, above the content, and it scrolls away with
                // both. Pinned, it would be a permanent accusation about a
                // screen that is working.
                if let detail = model.staleDetail {
                    VStack(alignment: .leading, spacing: 4) {
                        StaleBar(headline: "Showing what you had", detail: detail) {
                            await model.load(forceRefresh: true)
                        }
                        // The live half of a rate limit: `staleDetail` can
                        // only carry a headline, frozen at render time, since
                        // `StaleBar.detail` is a plain `String` — so a
                        // countdown that ticks needs its own line rather than
                        // living inside that string (gap 46).
                        if case let .rateLimited(until, _)? = model.staleFailure, let until {
                            Countdown(until: until)
                                .typeSmallMeta()
                                .foregroundStyle(Palette.textMuted)
                                .padding(.horizontal, Metrics.gutter + 18)
                        }
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .animation(Motion.reduced(Motion.settle), value: model.staleDetail)
                }

                // Above the stack shortcut, once, after an update. Not
                // pinned and not a sheet: it is a note, and the screen it
                // sits on is the point.
                if let whatsNew, whatsNew.isDue(hasCompletedOnboarding: hasCompletedOnboarding) {
                    WhatsNewCard(release: ReleaseNotes.current) {
                        Motion.run(Motion.snappy) { whatsNew.dismiss() }
                    }
                    .padding(.top, 16)
                    // First appearance rises in on `Motion.settle` (see
                    // `.arrives`); dismissing it — wrapped in
                    // `Motion.run(Motion.snappy)` above — removes it in the
                    // same animated transaction, so the sections below rise
                    // to fill the gap rather than jump.
                    .arrives(index: 0)
                }

                // Above the API's rows because it is the only one built from
                // what this reader actually did.
                if let recentlyViewed {
                    RecentlyViewedRow(model: recentlyViewed) {
                        open($0, from: "recent", siblings: recentlyViewed.series)
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
        // The rows are new; say so without a toast. Bumped only once `load`
        // has actually returned, so this fires when the feed lands, not when
        // the reader's pull gesture starts — see `Motion` rule 6.
        .haptic(Haptics.settled, onEach: refreshes)
        .task { await model.load() }
        .task { await recentlyViewed?.load() }
        .task { await pulse?.load() }
        // Marking a fresh install's notes as seen used to happen inline in
        // `body` via `WhatsNewState.isDue` — a write during view evaluation,
        // which SwiftUI warns about and does not promise to run at any
        // particular time (gap 49). `.task` runs outside the render pass, so
        // the same one-time stamp happens safely here instead.
        .task { whatsNew?.markSeenOnFreshInstall(hasCompletedOnboarding: hasCompletedOnboarding) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Discover")
                .typeScreenTitle()
                .foregroundStyle(Palette.textPrimary)
            Text(todayLine)
                .typeSubtitle()
                .foregroundStyle(Palette.textSecondary)
                // "1,284 series cached" rolls as the count changes on
                // refresh rather than cutting to the new figure.
                .countsNotCuts()
        }
        .padding(.horizontal, Metrics.gutter)
    }

    /// "Tuesday · 1,284 series cached". Both halves are real: the weekday from
    /// the clock, the count from the database. The mockup's third clause
    /// ("nothing waiting on a spinner") is dropped — it is a claim about
    /// performance that the app cannot verify at render time.
    private var todayLine: String {
        let weekday = Self.weekdayText()
        guard model.cachedCount > 0 else { return weekday }
        return "\(weekday) · \(model.cachedCount.formatted()) series cached"
    }

    /// The weekday, formatted once a day instead of once per `body`.
    ///
    /// `header` re-evaluates on every cached-count change and on every scroll
    /// frame that touches this view, and `Date().formatted(.dateTime…)` builds
    /// a format style and consults the calendar each time. The answer only
    /// changes at midnight, so it is cached against the day it was made for.
    ///
    /// A `static` slot rather than `@State`: only one Discover screen is ever
    /// on screen at a time, so one shared slot is what `@State` would have
    /// given here anyway — the same reasoning as
    /// `MixView.pendingFilterBlend`.
    @MainActor
    private static var cachedWeekday: (day: Date, text: String)?

    @MainActor
    private static func weekdayText(now: Date = Date()) -> String {
        let day = Calendar.current.startOfDay(for: now)
        if let cached = cachedWeekday, cached.day == day { return cached.text }
        let text = now.formatted(.dateTime.weekday(.wide))
        cachedWeekday = (day, text)
        return text
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
            // The tested pure decision (`arrivalIndex`) is this row's own
            // position among `model.rows` — the same thing `ForEach` above
            // hands every other row-keyed lookup in this file (`open`,
            // `prefetchCovers`), so there is one source of truth for "which
            // row is this" rather than a second index threaded in parallel.
            .arrives(index: Self.arrivalIndex(forRowID: row.id, in: model.rows))

            if row.isLoading && row.series.isEmpty {
                CoverSkeletonRow()
            } else if row.series.isEmpty, let failure = row.failure {
                // This row asked and failed, rather than asking and getting
                // nothing back — the two used to look identical (gap 13).
                InlineFailure(error: failure) {
                    await model.load(forceRefresh: true)
                }
            } else if row.series.isEmpty {
                Text("Nothing here right now.")
                    .typeSmallMeta()
                    .foregroundStyle(Palette.textMuted)
                    .padding(.horizontal, Metrics.gutter)
            } else {
                coverScroll(row)

                // A page-2-or-later failure used to read as the end of the
                // feed with nothing said about it (gap 15) — this is the one
                // line that says a page failed to load rather than the row
                // simply running out.
                if let pageFailure = row.pageFailure {
                    InlineFailure(error: pageFailure) {
                        await model.retryPage(row.id)
                    }
                    .padding(.top, 8)
                }
            }
        }
        // The covers' colour, faintly, on the ground behind them.
        .rowAmbient(row.series)
        // A guess: the whole row drifts a few points against that tint as
        // the page scrolls past it, in the outer vertical `ScrollView` —
        // `.parallax` needs to sit on a subview of the scroll view it
        // measures against, not inside the row's own horizontal one.
        .parallax(4)
    }

    /// The row's own horizontal scroll of covers — split out of `rowView`
    /// purely for the lint's function-length ceiling; the seam has no other
    /// meaning.
    private func coverScroll(_ row: DiscoverModel.Row) -> some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: Metrics.gapCovers) {
                ForEach(row.series) { series in
                    Button { open(series, from: row.id, siblings: row.series) } label: {
                        CoverCard(series: series, meta: Self.meta(for: series))
                    }
                    .buttonStyle(.press)
                    // The detail page grows out of this cover rather than
                    // sliding in over it, which is what makes the tap read
                    // as opening the thing you touched.
                    .zoomSource(row.id, series.id)
                    .arrives()
                    .enterScale()
                    // Fetch when the reader reaches the run-up to the end,
                    // not the end itself: by the time the last card is
                    // visible it is already too late to load without a
                    // visible stall.
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
            .scrollTargetLayout()
        }
        .scrollIndicators(.hidden)
        // A row settles on a card, not between two.
        .scrollTargetBehavior(.viewAligned)
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

    /// The arrival stagger index for the row at `id` in `rows`: its position,
    /// so the first row leads and the rest follow in order. `rowView` calls
    /// this directly rather than threading a second, parallel index in from
    /// `ForEach` — pulled out pure so it has a test without rendering the
    /// view (this project has no ViewInspector). A row id not found (should
    /// not happen — `rows` and this lookup share one source) arrives first
    /// rather than force-unwrapping.
    nonisolated static func arrivalIndex(forRowID id: String, in rows: [DiscoverModel.Row]) -> Int {
        rows.firstIndex { $0.id == id } ?? 0
    }

    /// "Manhwa · 8.6". Each half only when the API supplied it.
    static func meta(for series: Series) -> String? {
        var parts: [String] = []
        if let label = DetailHero.typeLabel(series.type) { parts.append(label) }
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

    /// `model.failure` is only ever set from an actual `.staleAfter` error
    /// (see `DiscoverModel.loadRows`) — never invented. A reader online with
    /// tight filters and four legitimately empty feeds used to be told
    /// "You're offline" purely because `?? .offline` needed *some* error to
    /// hand `FailureState`; that is no longer true here, so a genuinely empty
    /// screen gets a plain `EmptyState` instead of a guessed cause (gap 14).
    @ViewBuilder
    private var emptyState: some View {
        if let failure = model.failure {
            FailureState(error: failure) {
                await model.load(forceRefresh: true)
            }
        } else {
            EmptyState(
                title: "Nothing to show right now",
                message: "These feeds are empty at the moment. Pull to check again."
            )
        }
    }
}
