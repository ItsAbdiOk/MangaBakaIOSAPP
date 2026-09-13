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
    private let onOpenStack: () -> Void
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
        hasCompletedOnboarding: Bool = true,
        onOpenStack: @escaping () -> Void
    ) {
        self.whatsNew = whatsNew
        self.hasCompletedOnboarding = hasCompletedOnboarding
        _model = State(initialValue: model)
        self.inProgress = inProgress
        self.recentlyViewed = recentlyViewed
        _path = path
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
        zoomRoute?.source = ZoomRoute.id(row, series.id)
        path.append(series)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.sectionGap) {
                // The title, its line and the stack shortcut are one group:
                // Abdi, 2026-09-13, "shrink this section, it takes up too
                // much space" — the section gap plus the card's own top
                // padding put 42pt between two things that belong together.
                VStack(alignment: .leading, spacing: 10) {
                    header
                    openTheStack
                }

                if !inProgress.isEmpty {
                    PickBackUp(entries: inProgress, path: $path)
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
                }

                // Above the stack shortcut, once, after an update. Not
                // pinned and not a sheet: it is a note, and the screen it
                // sits on is the point.
                if let whatsNew, whatsNew.isDue(hasCompletedOnboarding: hasCompletedOnboarding) {
                    WhatsNewCard(release: ReleaseNotes.current) {
                        Motion.run(.snappy(duration: 0.25)) { whatsNew.dismiss() }
                    }
                    .padding(.top, 16)
                }

                // Above the API's rows because it is the only one built from
                // what this reader actually did.
                if let recentlyViewed {
                    RecentlyViewedRow(model: recentlyViewed) {
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
            .padding(.vertical, 10)
            .background { Glass.floating(RoundedRectangle(
                cornerRadius: Metrics.radiusCard, style: .continuous
            )) }
            .contentShape(RoundedRectangle(cornerRadius: Metrics.radiusCard, style: .continuous))
        }
        .buttonStyle(.press)
        .padding(.horizontal, Metrics.gutter)
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
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: Metrics.gapCovers) {
                        ForEach(row.series) { series in
                            Button { open(series, from: row.id) } label: {
                                CoverCard(series: series, meta: Self.meta(for: series))
                            }
                            .buttonStyle(.press)
                            // The detail page grows out of this cover rather
                            // than sliding in over it, which is what makes the
                            // tap read as opening the thing you touched.
                            .zoomSource(row.id, series.id)
                            .arrives()
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
                    .scrollTargetLayout()
                }
                .scrollIndicators(.hidden)
                // A row settles on a card, not between two.
                .scrollTargetBehavior(.viewAligned)

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
