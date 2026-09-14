import SwiftUI

/// The rabbit hole. Every row is a way onward; the screen must never dead-end.
struct SeriesDetailView: View {
    let series: Series
    let repository: any SeriesRepositoryProtocol
    let library: any LibraryProviding
    /// The app's one copy of the reader's library.
    let libraryStore: LibraryModel
    /// The release schedule. The detail page asks it for one series at a time
    /// (`cadence(for:)`), which costs at most one MangaUpdates request, rather
    /// than triggering the ten-page build the schedule screen pays for.
    let schedule: ReleaseScheduleService?
    let characters: CharacterService?
    let taste: TasteProfile?
    /// Nearest-neighbour search over the bundled sentence embeddings, for
    /// "Similar by description". Not defaulted: `EmbeddingIndex()` loads a
    /// 7.3 MB file, and a defaulted parameter meant a caller that forgot it
    /// silently loaded a second copy per series page. `AppServices` holds the
    /// one instance and every page is handed it.
    var embeddingIndex: EmbeddingIndex
    /// Resolves an embedding neighbour's id to a title — see
    /// `loadSimilarByDescription()`. Not defaulted for the same reason as
    /// `embeddingIndex`: it, too, is a file-backed actor there should be one
    /// of.
    var offlineCatalogue: OfflineCatalogue
    /// The volumes on Apple Books. Optional like the others: a page without
    /// it shows MangaBaka's own editions instead.
    var appleBooks: AppleBooksClient?
    /// Fills volume gaps Apple does not carry. Nil in a build with no Google
    /// Books key, which is every Release build — see Secrets.example.xcconfig.
    var googleBooks: GoogleBooksClient?
    /// Reads a publisher's own release feed — Webtoons, a GigaViewer magazine,
    /// or Naver Webtoon for the Korean original. Optional like the stores
    /// above: a page without it simply shows no release section.
    var releaseFeeds: ReleaseFeedService?
    /// MangaUpdates' vote-weighted categories; nil skips the section.
    var mangaUpdatesCategories: MangaUpdatesClient?
    /// Cover gap-filler by ISBN, asked only for volumes no store has art for.
    var openLibrary: OpenLibraryCovers?
    @State var openLibraryCovers: [Int: URL] = [:]
    /// Where the Open Library gap-fill pass stands — overall, and per volume
    /// number for the ones whose own answer has already landed. Per volume
    /// since item 57: the pass commits a cover the moment it finds one
    /// rather than at the end, so a spine must be able to say "asked and
    /// nobody has one" while its neighbours are still out.
    @State var openLibraryStatus = OpenLibraryProgress()
    @State var categories: [MangaUpdatesCategories.Category] = []
    @State var isCategoriesLoading = false
    @State var categoriesFailure: APIError?
    /// Opens a publisher's or studio's page from the credits.
    var onOpenPublisher: ((String) -> Void)?
    /// Opens a creator's page — everything they wrote or drew.
    var onOpenAuthor: ((String) -> Void)?
    /// The reader's content filter, so an explicit tag name is not shown to
    /// someone who filtered explicit content — a tag is rated independently of
    /// its series.
    var contentRatings: [String]?
    @Binding var path: [Series]
    /// Sends this series to Mix as a seed and switches to that tab.
    var onUseAsSeed: ((Series) -> Void)?
    /// Opens a search for one of the series' tags.
    var onOpenTag: ((String) -> Void)?
    var onOpenSchedule: (() -> Void)?

    @State var similar: [Series] = []
    /// Set only when `.similar` asked and failed with nothing to fall back
    /// on. Internal, not private, so `+Releases.swift`-style extensions could
    /// reach it if this screen grows another one; today only this file reads
    /// it.
    @State var similarFailure: APIError?
    @State var alsoLike: [Series] = []
    @State var alsoLikeFailure: APIError?
    /// Nearest neighbours by embedding — see `loadSimilarByDescription()`.
    /// No failure state: an on-device file read either has a vector for this
    /// series or it does not, and both leave this empty.
    @State var similarByDescription: [Series] = []
    // Internal, not private: the shelf lives in SeriesDetailView+Store.swift
    // for the lint's ceiling on this type.
    @State var appleVolumes: [AppleBooksVolume] = []
    /// Only the numbers Apple is missing; see `VolumeShelf.merge`.
    @State var googleVolumes: [GoogleBooksVolume] = []
    /// Why the store could not be asked, when that is what happened —
    /// distinct from "asked, and it has none", which shows MangaBaka's
    /// editions with no note. An `APIError`, not a `Bool` (item 60): offline,
    /// a 429, a 5xx and a decode failure all used to collapse into one bare
    /// line of text with no reason and no retry.
    @State var appleFailure: APIError?
    /// True while a store is still being asked for volumes — see
    /// `VolumesSection.isCheckingStore`.
    @State var isLoadingVolumes = false
    /// Which store's edition the shelf shows, when not the reader's own.
    @State var appleEdition: AppleVolumesRow.Edition?
    /// The release section's report. Internal, not private, so
    /// `SeriesDetailView+Releases.swift` can write to it.
    @State var releases: ReleaseReport = .empty
    @State var isReleasesLoading = false
    @State var extras = SeriesExtras()
    @State var covers: [SeriesImage] = []
    /// Set only when the image fetch itself failed — nil for a series that
    /// genuinely has none. `SeriesRepositoryProtocol.images(for:)` already
    /// draws this line (nil vs. `[]`); this just keeps it past `loadCore`
    /// instead of collapsing both into `covers = []` (gap 32/16).
    @State var coversFailure: APIError?
    @State private var openCoversAt: GalleryStart?
    /// The gallery's images, captured the moment it opens rather than read
    /// live from `otherCovers` — gap 67: Apple's volumes can still be landing
    /// after the reader has already opened the fan, and a computed property
    /// that keeps growing under an open pager reads as the page shifting
    /// under a finger mid-swipe.
    @State private var openCoversImages: [SeriesImage] = []
    @State private var favouredTags: Set<String> = []
    @State private var favouredTagIDs: Set<Int> = []
    @State var cast: [SeriesCharacter] = []
    @State var isCastLoading = false
    /// Set only when every source `CharacterService` asked failed outright —
    /// see `CharacterService.CharacterCast.failed`.
    @State var castFailure: APIError?
    @State var cadence: Cadence?
    /// Set only when the cadence ask itself failed — see
    /// `ReleaseScheduleService.SeriesCadence.failed`.
    @State var cadenceFailure: APIError?
    @State var isCadenceLoading = false
    @State private var isLoading = true
    /// Which series `loadCore` / `loadOnward` last finished for. `.task(id:
    /// series.id)` is cancelled on disappear and started again on appear, and
    /// a push (a related series, a publisher) or a `fullScreenCover` (the
    /// gallery) both take this page through that — so coming back re-ran the
    /// whole load: `filled = nil` dropped the synopsis and chapter count to
    /// skeletons before the six-hour cache refilled them, and the seven
    /// onward legs were asked again, two of them behind MangaUpdates' 3 s
    /// spacer and Open Library's up-to-36 s of HEADs, for a page the reader
    /// had already read (review item 32, 2026-09-14). Two ids, not one: a
    /// gallery opened while the onward legs were still out cancels them, and
    /// only those should be re-asked on return — never the core, whose reset
    /// is the visible flash.
    @State private var coreLoadedID: Int?
    @State private var onwardLoadedID: Int?
    /// How far the page has scrolled, fed to `DetailBackdrop` for its
    /// parallax and to `DetailBarTitle` for its crossfade. A reference type,
    /// not `@State var scrollOffset: CGFloat` — see `ScrollTracker`, which
    /// records why (item 54: every scroll frame rebuilt this whole body).
    /// Tracked here, not in the backdrop, because the backdrop sits in
    /// `.background` on this `ScrollView`, outside the content whose
    /// geometry `onScrollGeometryChange` reports.
    @State private var scroll = ScrollTracker()

    /// The series with `extras.full`'s gaps already filled in, computed once
    /// when `extras` lands rather than per read of `shown`. `shown` is read
    /// eleven times in one pass of `body` and `Series.filling` copies the
    /// whole struct each time (item 54). Nil until `loadCore` has answered,
    /// and reset at the top of every load so a page whose `series` changed
    /// never shows the previous one's filled-in fields.
    @State private var filled: Series?
    /// The parsed synopsis, cached because `Self.prose` runs a Markdown
    /// parse over the whole description — see item 54. Recomputed when the
    /// description changes, not per body pass.
    @State private var synopsis: AttributedString?
    /// `TagGrouping.groups` over up to 146 tags, computed when `extras` or
    /// the taste profile changes rather than per body pass (item 54).
    @State private var tagGroups: [TagGroup] = []

    /// Where a section sits in the page's arrival choreography — see
    /// `sectionIndex(for:)`. The mockup's own order (the comment on `body`),
    /// named so `.arrives(index:)` at each call site reads as "this section,
    /// in this order" rather than a bare integer nobody can trace back to
    /// the layout.
    enum Section: Int, CaseIterable {
        case stats, synopsis, cast, tags, credits, releases, volumes, editions, onwardRows, categories,
             trackers
    }

    /// A section's place in the stagger, tested in `DetailMotionTests`
    /// rather than only eyeballed on a device — a index typo here staggers
    /// the wrong section without changing anything a screenshot would catch
    /// at a glance.
    nonisolated static func sectionIndex(for section: Section) -> Int { section.rawValue }

    /// The page-level fact worth a `StaleBar`: the six-way `extras` fetch, or
    /// either onward feed, answered from a stale cache or not at all. A
    /// section-level `InlineFailure` says which piece is missing; this says
    /// the page as a whole may be out of date (gap 10, worst afternoon #2).
    /// `coversFailure` is defaulted so the three existing legs read
    /// unchanged. It is the fourth: `/images` failing used to be recorded and
    /// never read anywhere, so a throttled reader saw a series with no fan,
    /// pixel-identical to one that genuinely has no covers (item 25).
    nonisolated static func pageFailure(
        extras: SeriesExtras, similarOrigin: FeedResult.Origin, alsoOrigin: FeedResult.Origin,
        coversFailure: APIError? = nil
    ) -> APIError? {
        if let failure = extras.failure { return failure }
        if let coversFailure { return coversFailure }
        for origin in [similarOrigin, alsoOrigin] {
            if case let .staleAfter(error) = origin { return error }
        }
        return nil
    }

    @State var similarOrigin: FeedResult.Origin = .network
    @State var alsoOrigin: FeedResult.Origin = .network
    private var pageFailure: APIError? {
        Self.pageFailure(
            extras: extras, similarOrigin: similarOrigin, alsoOrigin: alsoOrigin,
            coversFailure: coversFailure
        )
    }

    /// The series as this screen shows it: the copy the reader arrived with,
    /// with anything it was missing filled in from the full v1 record fetched
    /// alongside the tags.
    ///
    /// The copies are not equal. A feed's v2 payload has no description, no
    /// chapter count, no status and no `source`, so a page opened from the
    /// swipe stack had no synopsis, no length and no next-chapter estimate —
    /// while the same series opened from Search had all three. The reader is
    /// looking at one series; it should not matter which door they came in by.
    var shown: Series { filled ?? series }
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        ScrollView {
            // The mockup's order, which is an argument about what a reader
            // wants: what it is, then what to do about it, then the numbers,
            // then the words, then everywhere else to go.
            VStack(alignment: .leading, spacing: Metrics.detailRowGap) {
                DetailHero(
                    series: shown,
                    schedule: cadence,
                    isScheduleLoading: isCadenceLoading,
                    onOpenSchedule: onOpenSchedule,
                    scheduleFailure: cadenceFailure,
                    onRetrySchedule: { await loadCadence() },
                    otherCovers: otherCovers,
                    preferredCover: frontCover,
                    onOpenCovers: openCovers
                )
                .padding(.top, 4)
                // Gap 10: a series page opened offline or throttled used to
                // say nothing at all — title and cover rendered, and every
                // section that needed a network answer simply had none, with
                // no line anywhere naming why. `pageFailure` is nil the
                // instant any one of the three legs it watches has a real
                // answer, so this never sits over content that is actually
                // current.
                if !isLoading, let pageFailure {
                    StaleBar(
                        headline: pageFailure.headline,
                        detail: pageFailure.userFacingMessage,
                        // Walked on the simulator 2026-09-14: a spinoff page
                        // ("One Piece: Law's Story") carried this bar reading
                        // "Too many requests, briefly" with a Retry and no
                        // countdown, and four screenshots at t=0/1/3/6 s were
                        // byte-identical — it never ticked and never retried
                        // itself. `StaleBar` has taken a `deadline` since
                        // review R F9 and `APIError` has carried the date
                        // since the `until:` payload landed; this call site
                        // simply never passed it, so the one bar a reader is
                        // most likely to meet was the one that could not
                        // count down. Nil for every non-rate-limit reason,
                        // which leaves those exactly as they were.
                        deadline: pageFailure.rateLimitDeadline,
                        // `loadCore`, not `load()`: every leg this bar can
                        // name is a MangaBaka-side one, and `load()` would
                        // re-pay cast, cadence, Apple, Google, Open Library,
                        // the release feeds and the categories — up to nine
                        // third-party requests, several behind 3 s spacers —
                        // for a failure none of them caused (item 26). The
                        // sections' own `InlineFailure`s retry their own.
                        retry: { await loadCore() }
                    )
                }
                actions
                // Under the actions, before the numbers: starting to read is
                // the other thing to do about a series, and the full list of
                // links is a screen and a half further down.
                ReadRow(links: extras.links)
                DetailStatsStrip(series: shown, year: extras.year, season: cadence?.season)
                    .arrives(index: Self.sectionIndex(for: .stats))
                if let synopsis {
                    DetailSynopsis(text: synopsis)
                        .arrives(index: Self.sectionIndex(for: .synopsis))
                }
                CharacterRow(
                    characters: cast, isLoading: isCastLoading, failure: castFailure,
                    retry: { await loadCast() },
                    // The service's own clients, so a profile sheet shares
                    // their spacing and backoff (item 63).
                    aniList: characters?.aniList, shikimori: characters?.shikimori
                )
                .arrives(index: Self.sectionIndex(for: .cast))
                tagSection
                    .arrives(index: Self.sectionIndex(for: .tags))
                DetailCredits(
                    series: shown, onOpenPublisher: onOpenPublisher, onOpenAuthor: onOpenAuthor
                )
                .arrives(index: Self.sectionIndex(for: .credits))
                ReleaseSection(
                    report: releases, isLoading: isReleasesLoading, links: extras.links,
                    retry: { await loadReleases() }
                )
                .arrives(index: Self.sectionIndex(for: .releases))
                volumesShelf
                    .arrives(index: Self.sectionIndex(for: .volumes))
                DetailEditions(editions: extras.editions)
                    .arrives(index: Self.sectionIndex(for: .editions))
                DetailOnwardRows(
                    relationships: extras.relationships,
                    similar: similar,
                    alsoLike: alsoLike,
                    similarByDescription: similarByDescription,
                    isLoading: isLoading,
                    similarFailure: similarFailure,
                    alsoLikeFailure: alsoLikeFailure,
                    onRetrySimilar: { await loadSimilar() },
                    onRetryAlsoLike: { await loadAlsoLike() },
                    path: $path
                )
                .arrives(index: Self.sectionIndex(for: .onwardRows))
                TrackerScores(series: shown)
                    .arrives(index: Self.sectionIndex(for: .trackers))
                DetailCategories(
                    categories: categories, isLoading: isCategoriesLoading,
                    failure: categoriesFailure, onRetry: loadCategories
                )
                .arrives(index: Self.sectionIndex(for: .categories))
                readElsewhere
                newsSection
                provenance
            }
            .padding(.bottom, Metrics.scrollBottomInset)
        }
        .scrollIndicators(.hidden)
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.contentOffset.y + geometry.contentInsets.top
        } action: { _, travelled in
            scroll.update(travelled: travelled)
        }
        .background(alignment: .top) {
            DetailBackdrop(cover: shown.cover, tracker: scroll)
                .background(Palette.ground)
                .ignoresSafeArea()
        }
        .scrollEdgeEffectStyle(.hard, for: .top)
        .detailBarTitle(
            shown.displayTitle ?? "Series", shareURL: SeriesWebLink.url(for: shown), tracker: scroll
        )
        .fullScreenCover(item: $openCoversAt) { start in
            CoverGallery(
                series: shown,
                frontCover: frontCover ?? shown.cover,
                // A snapshot taken when the gallery opened (gap 67), not a
                // live read of `otherCovers`: Apple's volumes can still be
                // landing after the fan is tapped, and a pager whose page
                // count grows under a reader's finger mid-swipe is the worse
                // failure than showing the count as it was at the moment of
                // the tap.
                images: openCoversImages,
                startAt: start.value
            )
        }
        .task(id: series.id) { await load() }
    }
}

/// Everything below moved out of the primary struct into this same-file
/// extension purely for the lint's 250-line body-length ceiling — `private`
/// members stay reachable from an extension in the same file.
extension SeriesDetailView {
    /// Snapshots the gallery's images at the moment of the tap — see
    /// `openCoversImages` — and refuses to open on a series with nothing to
    /// show, where a full-screen cover over an empty pager was a dead end
    /// with a close button and nothing else.
    private func openCovers(startingAt index: Int) {
        let images = otherCovers
        guard !images.isEmpty else { return }
        openCoversImages = images
        openCoversAt = GalleryStart(value: index)
    }

    /// The mockup pairs the primary action with "Use as seed", which is the
    /// only place in the app that sends a specific series into a blend from the
    /// screen where you decided you liked it.
    private var actions: some View {
        // Side by side normally; stacked at accessibility text sizes, where
        // two fixed-height buttons sharing a row truncated into "Add to li…"
        // and "Use as…" — both unreadable, and the primary action of the page
        // among them.
        Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: Metrics.gapStrip) {
                    libraryAction
                    seedAction
                }
                .padding(.leading, Metrics.gutter)
            } else {
                HStack(spacing: Metrics.gapStrip) {
                    libraryAction
                        .padding(.leading, Metrics.gutter)
                    seedAction
                }
            }
        }
        .padding(.trailing, Metrics.gutter)
    }

    private var libraryAction: some View {
        LibraryControl(series: shown, library: library, store: libraryStore)
    }

    @ViewBuilder
    private var seedAction: some View {
        if onUseAsSeed != nil {
            Button { onUseAsSeed?(shown) } label: {
                Text("Use as seed")
                    .typeChip()
                    .lineLimit(1)
                    .padding(.horizontal, 16)
                    // minHeight, not height: at accessibility text sizes a
                    // fixed 52pt button clips its own label.
                    .frame(minHeight: Metrics.ctaPrimary)
                    .foregroundStyle(Palette.textPrimary)
                    .background(
                        Palette.surfaceChip,
                        in: RoundedRectangle(
                            cornerRadius: Metrics.radiusCard, style: .continuous
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: Metrics.radiusCard, style: .continuous)
                            .strokeBorder(Palette.border, lineWidth: 0.5)
                    )
            }
            .buttonStyle(.press)
            .accessibilityHint("Adds this series to the Mix and opens it")
        }
    }

    /// A licence obligation, not a nicety: CC BY-NC-SA requires attribution to
    /// MangaBaka and to the upstream sources the data came from.
    private var provenance: some View {
        Text("""
        Data from MangaBaka, and through it AniList, Kitsu, MangaUpdates, \
        MyAnimeList and Anime-Planet. CC BY-NC-SA 4.0.
        """)
            .typeFootnote()
            .foregroundStyle(Palette.textMuted)
            .padding(.horizontal, Metrics.gutter)
    }

    // MARK: - Sections

    @ViewBuilder
    private var readElsewhere: some View {
        LinksSection(links: extras.links)
    }

    @ViewBuilder
    private var newsSection: some View {
        NewsSection(items: extras.news)
    }

    /// Descriptions arrive as Markdown and were being printed raw, so a real
    /// series page ended with a literal "*Source: Tappytoon*" and a line of
    /// three hyphens. Parsing it renders the emphasis and drops the rules.
    ///
    /// `.inlineOnlyPreservingWhitespace`, not `.full`. Full parsing produces
    /// block elements that `Text` renders end to end with no separator, which
    /// turned a real description into "...extent of his powers. Source:
    /// TappytoonKnown as the weakest hunter..." — two paragraphs and a caption
    /// welded into one sentence.
    static func prose(from markdown: String) -> AttributedString {
        let cleaned = markdown
            .replacingOccurrences(of: "\n---\n", with: "\n\n")
            .replacingOccurrences(of: "\n\n\n", with: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        return (try? AttributedString(markdown: cleaned, options: options))
            ?? AttributedString(cleaned)
    }

    /// The cover to lead with, and the rest behind it.
    ///
    /// An English edition where the series has one — MangaBaka's own pick for a
    /// Korean manhwa is usually the Korean volume one, which is handsome and
    /// unreadable to most people looking at this app.
    var preferred: SeriesImage? {
        covers.preferredCover(nativeLanguage: shown.nativeLanguage)
    }

    private var frontCover: Cover? { preferred?.image }

    /// Everything except whichever cover is already on the front, so the fan
    /// never shows the same image twice.
    private func load() async {
        // Two intervals, not one. "Readable" is when the page has its own
        // content and stops looking empty; "complete" is when the rows a reader
        // scrolls to have filled in. Measuring only the second would report a
        // page that felt instant as three seconds slow.
        //
        // Idempotent per series — see `coreLoadedID`. A core that failed is
        // not recorded, so the next appearance asks again; the `StaleBar`'s
        // own retry calls `loadCore()` directly and is unaffected. The
        // signpost therefore measures first opens only, not cache hits.
        if coreLoadedID != series.id {
            await Signposts.measure("Detail readable") { await loadCore() }
            guard extras.failure == nil, !Task.isCancelled else { return }
            coreLoadedID = series.id
        }
        if onwardLoadedID != series.id {
            await Signposts.measure("Detail complete") { await loadOnward() }
            // A leg cut short by the reader leaving is re-asked on return;
            // its cancelled answer writes nothing (item 30).
            guard !Task.isCancelled else { return }
            onwardLoadedID = series.id
        }
    }

    /// A section-level failure worth a line under its header, or nil for
    /// the one error that is never on screen: `.cancelled` means the reader
    /// left, or the pager replaced the series, and a live page has nothing
    /// to say about a request nobody is waiting for (`APIError.cancelled`'s
    /// own doc comment; the cadence leg has done this since item 40). The
    /// categories, cast and Apple legs did not, so a cover opened mid-load
    /// came back to "Cancelled" and a Retry under three sections (review
    /// item 30, 2026-09-14).
    nonisolated static func presentableFailure(_ error: APIError) -> APIError? {
        if case .cancelled = error { return nil }
        return error
    }

    func loadCore() async {
        isLoading = true
        // Reset before the first await, not after: a `series` that changed
        // under this view (the pager, a deep link) must never render the
        // previous series' filled-in fields while its own answer is out.
        filled = nil
        refreshDerived()
        async let similarResult = repository.feed(.similar(seriesId: series.id), forceRefresh: false)
        async let alsoResult = repository.feed(.readersAlsoLike(seriesId: series.id), forceRefresh: false)
        async let extrasResult = repository.extras(for: series.id)
        async let imagesResult = repository.images(for: series.id)
        let similarAnswer = await similarResult
        similar = similarAnswer.series
        similarOrigin = similarAnswer.origin
        similarFailure = similarAnswer.blockingError
        let alsoAnswer = await alsoResult
        alsoLike = alsoAnswer.series
        alsoOrigin = alsoAnswer.origin
        alsoLikeFailure = alsoAnswer.blockingError
        extras = await extrasResult
        // nil is "asked and failed" — the gallery no longer treats it like an
        // empty answer (gap 16/32): `coversFailure` carries the reason so the
        // fan and the gallery can tell "no covers" from "couldn't ask".
        let imagesAnswer = await imagesResult
        covers = imagesAnswer ?? []
        // `images(for:)` answers `[SeriesImage]?`, not a `Fetched`, so the
        // real `APIError` behind a nil is lost before it reaches here — a
        // change this batch does not own (`SeriesRepository.swift`, batch 1,
        // already landed). Recorded anyway, even without detail, so a future
        // caller has *something* rather than reconstructing "nil happened"
        // from `covers.isEmpty` alone the way this file used to.
        coversFailure = imagesAnswer == nil
            ? .transport(underlying: "images(for:) returned nil", party: .mangaBaka)
            : nil
        filled = extras.full.map { series.filling(gapsFrom: $0) }
        refreshDerived()
        isLoading = false
    }

    /// The three values `body` used to recompute on every pass: the filled-in
    /// series' parsed synopsis and its grouped tags. Called when the inputs
    /// change — `extras` landing, the taste profile answering — rather than
    /// per frame (item 54).
    private func refreshDerived() {
        if let description = shown.description, !description.isEmpty {
            synopsis = Self.prose(from: description)
        } else {
            synopsis = nil
        }
        tagGroups = extras.richTags.isEmpty
            ? []
            : TagGrouping.groups(
                from: extras.richTags, allowedRatings: contentRatings, favouredIDs: favouredTagIDs
            )
    }

    private func loadOnward() async {
        async let cast: Void = loadCast()
        async let cadence: Void = loadCadence()
        async let taste: Void = loadTaste()
        async let store: Void = loadAppleVolumes()
        // After `store` in the argument list only for readability; it does
        // not depend on it. It does depend on `extras.links`, which `loadCore`
        // has already populated by the time `loadOnward` runs.
        async let onward: Void = loadReleases()
        // On-device, no network — grouped here anyway so it does not delay
        // "Detail readable" (`loadCore`), the same reasoning as every other
        // leg in this group.
        async let byDescription: Void = loadSimilarByDescription()
        async let categories: Void = loadCategories()
        _ = await (cast, cadence, taste, store, onward, byDescription, categories)
    }

    /// Grouped `tags_v2` where the series has them, the flat v1 names where it
    /// does not. The fallback matters: v2 payloads carry no tags at all, so a
    /// series reached through a shape that never fetched v1 would otherwise
    /// lose its tag row entirely rather than degrade.
    @ViewBuilder
    private var tagSection: some View {
        if !extras.richTags.isEmpty {
            DetailTagSections(
                // `tagGroups`, not a live `TagGrouping.groups` call: grouping
                // 146 tags is not a per-body-pass cost (item 54). Kept in
                // step by `refreshDerived()`.
                groups: tagGroups,
                favouredIDs: favouredTagIDs
            ) { tag in
                onOpenTag?(tag.name)
            }
        } else {
            DetailTags(tags: extras.tags, favoured: favouredTags) { tag in
                onOpenTag?(tag)
            }
        }
    }

    /// Cached for the session after the first series page, so this is one
    /// request per launch rather than one per page.
    private func loadTaste() async {
        favouredTags = await taste?.favouredTagNames() ?? []
        // Matched by id, never by name. The taste endpoint and the tag list are
        // different endpoints with different spellings, and matching strings
        // found exactly one tag in a series carrying 146.
        // Count this series into the taste profile before asking what the
        // profile says, so opening a series you have read makes its tags yours
        // immediately rather than on the next launch.
        if !extras.richTags.isEmpty {
            await taste?.note(shown.withTags(extras.richTags))
        }
        favouredTagIDs = await taste?.favouredTagIDs() ?? []
        refreshDerived()
    }

}
