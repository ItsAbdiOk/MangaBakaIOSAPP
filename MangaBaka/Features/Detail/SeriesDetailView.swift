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
    /// The volumes on Apple Books. Optional like the others: a page without
    /// it shows MangaBaka's own editions instead.
    var appleBooks: AppleBooksClient?
    /// Fills volume gaps Apple does not carry. Nil in a build with no Google
    /// Books key, which is every Release build — see Secrets.example.xcconfig.
    var googleBooks: GoogleBooksClient?
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

    @State private var similar: [Series] = []
    // Internal, not private: the shelf lives in SeriesDetailView+Store.swift
    // for the lint's ceiling on this type.
    @State var appleVolumes: [AppleBooksVolume] = []
    /// Only the numbers Apple is missing; see `VolumeShelf.merge`.
    @State var googleVolumes: [GoogleBooksVolume] = []
    /// The store was asked and did not answer — distinct from "asked, and it
    /// has none", which shows MangaBaka's editions with no note.
    @State var appleUnreachable = false
    /// Which store's edition the shelf shows, when not the reader's own.
    @State var appleEdition: AppleVolumesRow.Edition?
    @State private var alsoLike: [Series] = []
    @State var extras = SeriesExtras()
    @State var covers: [SeriesImage] = []
    @State private var openCoversAt: GalleryStart?
    @State private var favouredTags: Set<String> = []
    @State private var favouredTagIDs: Set<Int> = []
    @State private var cast: [SeriesCharacter] = []
    @State private var isCastLoading = false
    @State private var cadence: Cadence?
    @State private var isCadenceLoading = false
    @State private var isLoading = true

    /// The series as this screen shows it: the copy the reader arrived with,
    /// with anything it was missing filled in from the full v1 record fetched
    /// alongside the tags.
    ///
    /// The copies are not equal. A feed's v2 payload has no description, no
    /// chapter count, no status and no `source`, so a page opened from the
    /// swipe stack had no synopsis, no length and no next-chapter estimate —
    /// while the same series opened from Search had all three. The reader is
    /// looking at one series; it should not matter which door they came in by.
    var shown: Series {
        extras.full.map { series.filling(gapsFrom: $0) } ?? series
    }
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
                    otherCovers: otherCovers,
                    preferredCover: frontCover,
                    onOpenCovers: { openCoversAt = GalleryStart(value: $0) }
                )
                .padding(.top, 4)
                actions
                // Under the actions, before the numbers: starting to read is
                // the other thing to do about a series, and the full list of
                // links is a screen and a half further down.
                ReadRow(links: extras.links)
                DetailStatsStrip(series: shown, year: extras.year, season: cadence?.season)
                if let description = shown.description, !description.isEmpty {
                    DetailSynopsis(text: Self.prose(from: description))
                }
                CharacterRow(characters: cast, isLoading: isCastLoading)
                tagSection
                DetailCredits(
                    series: shown, onOpenPublisher: onOpenPublisher, onOpenAuthor: onOpenAuthor
                )
                volumesShelf
                DetailEditions(editions: extras.editions)
                DetailOnwardRows(
                    relationships: extras.relationships,
                    similar: similar,
                    alsoLike: alsoLike,
                    isLoading: isLoading,
                    path: $path
                )
                TrackerScores(series: shown)
                readElsewhere
                newsSection
                provenance
            }
            .padding(.bottom, Metrics.scrollBottomInset)
        }
        .scrollIndicators(.hidden)
        .background(alignment: .top) {
            DetailBackdrop(cover: shown.cover)
                .background(Palette.ground)
                .ignoresSafeArea()
        }
        .scrollEdgeEffectStyle(.hard, for: .top)
        .detailBarTitle(shown.displayTitle ?? "Series", shareURL: SeriesWebLink.url(for: shown))
        .fullScreenCover(item: $openCoversAt) { start in
            CoverGallery(
                series: shown,
                frontCover: frontCover ?? shown.cover,
                images: otherCovers,
                startAt: start.value
            )
        }
        .task(id: series.id) { await load() }
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
        await Signposts.measure("Detail readable") { await loadCore() }
        await Signposts.measure("Detail complete") { await loadOnward() }
    }

    private func loadCore() async {
        isLoading = true
        async let similarResult = repository.feed(.similar(seriesId: series.id), forceRefresh: false)
        async let alsoResult = repository.feed(.readersAlsoLike(seriesId: series.id), forceRefresh: false)
        async let extrasResult = repository.extras(for: series.id)
        async let imagesResult = repository.images(for: series.id)
        similar = await similarResult.series
        alsoLike = await alsoResult.series
        extras = await extrasResult
        covers = await imagesResult
        isLoading = false
    }

    private func loadOnward() async {
        async let cast: Void = loadCast()
        async let cadence: Void = loadCadence()
        async let taste: Void = loadTaste()
        async let store: Void = loadAppleVolumes()
        _ = await (cast, cadence, taste, store)
    }

    /// Grouped `tags_v2` where the series has them, the flat v1 names where it
    /// does not. The fallback matters: v2 payloads carry no tags at all, so a
    /// series reached through a shape that never fetched v1 would otherwise
    /// lose its tag row entirely rather than degrade.
    @ViewBuilder
    private var tagSection: some View {
        if !extras.richTags.isEmpty {
            DetailTagSections(
                groups: TagGrouping.groups(
                    from: extras.richTags,
                    allowedRatings: contentRatings,
                    favouredIDs: favouredTagIDs
                ),
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
    }

    /// Both tracker ids come from MangaBaka's own `source` block, so no lookup
    /// is needed to find them. A series carrying neither has no cast to show,
    /// and in that case nothing is asked and no row appears.
    private func loadCast() async {
        guard let characters,
              shown.aniListID != nil || shown.shikimoriID != nil
        else { return }
        isCastLoading = true
        defer { isCastLoading = false }
        cast = await characters.characters(
            aniListID: shown.aniListID,
            shikimoriID: shown.shikimoriID
        )
    }

    /// Asked separately from everything else, and after it.
    ///
    /// MangaUpdates spaces requests at one every three seconds, so this can
    /// take noticeably longer than the rest of the page. Awaiting it alongside
    /// the others would hold the whole screen on the slowest thing on it; the
    /// hero shows a spinner in its place instead.
    private func loadCadence() async {
        // Nothing is asked, and no spinner shown, for a series that has
        // finished or stopped — see `canPredict`.
        guard let schedule,
              shown.mangaUpdatesID != nil,
              ReleaseScheduleService.canPredict(status: shown.status)
        else { return }
        isCadenceLoading = true
        defer { isCadenceLoading = false }
        if case let .measured(estimate) = await schedule.cadence(for: shown) {
            cadence = estimate
        }
    }
}
