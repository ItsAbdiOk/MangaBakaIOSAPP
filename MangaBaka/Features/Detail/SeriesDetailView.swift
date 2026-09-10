import SwiftUI

/// The rabbit hole. Every row is a way onward; the screen must never dead-end.
struct SeriesDetailView: View {
    let series: Series
    let repository: any SeriesRepositoryProtocol
    let library: any LibraryProviding
    /// The app's one copy of the reader's library.
    let libraryStore: LibraryModel
    /// The release schedule, read from its cache only — see `cachedCadence`.
    let schedule: ReleaseScheduleService?
    let characters: CharacterService?
    let taste: TasteProfile?
    @Binding var path: [Series]
    /// Sends this series to Mix as a seed and switches to that tab.
    var onUseAsSeed: ((Series) -> Void)?
    /// Opens a search for one of the series' tags.
    var onOpenTag: ((String) -> Void)?
    var onOpenSchedule: (() -> Void)?

    @State private var similar: [Series] = []
    @State private var alsoLike: [Series] = []
    @State private var extras = SeriesExtras()
    @State private var favouredTags: Set<String> = []
    @State private var cast: [SeriesCharacter] = []
    @State private var isCastLoading = false
    @State private var cadence: Cadence?
    @State private var isCadenceLoading = false
    @State private var isLoading = true
    @Environment(\.openURL) private var openURL
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        ScrollView {
            // The mockup's order, which is an argument about what a reader
            // wants: what it is, then what to do about it, then the numbers,
            // then the words, then everywhere else to go.
            VStack(alignment: .leading, spacing: Metrics.detailRowGap) {
                DetailHero(
                    series: series,
                    schedule: cadence,
                    isScheduleLoading: isCadenceLoading,
                    onOpenSchedule: onOpenSchedule
                )
                .padding(.top, 4)
                actions
                DetailStatsStrip(series: series, year: extras.year)
                if let description = series.description, !description.isEmpty {
                    DetailSynopsis(text: Self.prose(from: description))
                }
                CharacterRow(characters: cast, isLoading: isCastLoading)
                DetailTags(tags: extras.tags, favoured: favouredTags) { tag in
                    onOpenTag?(tag)
                }
                DetailCredits(series: series)
                relatedRow
                onwardRow("Similar", similar)
                onwardRow("Readers also like", alsoLike)
                TrackerScores(series: series)
                readElsewhere
                newsSection
                provenance
            }
            .padding(.bottom, Metrics.scrollBottomInset)
        }
        .scrollIndicators(.hidden)
        .background(alignment: .top) {
            DetailBackdrop(cover: series.cover)
                .background(Palette.ground)
                .ignoresSafeArea()
        }
        .navigationTitle(series.displayTitle ?? "Series")
        .navigationBarTitleDisplayMode(.inline)
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
        LibraryControl(series: series, library: library, store: libraryStore)
    }

    @ViewBuilder
    private var seedAction: some View {
        if onUseAsSeed != nil {
                Button { onUseAsSeed?(series) } label: {
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
                .buttonStyle(.plain)
                .accessibilityHint("Adds this series to the Mix and opens it")
        }
    }

    @ViewBuilder
    private func onwardRow(_ title: String, _ items: [Series]) -> some View {
        if isLoading || !items.isEmpty {
            VStack(alignment: .leading, spacing: 11) {
                Text(title)
                    .typeDetailSectionHeader()
                    .foregroundStyle(Palette.textPrimary)
                    .padding(.horizontal, Metrics.gutter)

                if items.isEmpty {
                    HStack(spacing: Metrics.gapCovers) {
                        ForEach(0..<3, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: Metrics.radiusCoverRow, style: .continuous)
                                .fill(Palette.imagePlaceholder)
                                .frame(
                                    width: Metrics.coverDetailRowWidth,
                                    height: Metrics.coverDetailRowWidth / Metrics.coverAspect
                                )
                        }
                    }
                    .padding(.horizontal, Metrics.gutter)
                } else {
                    ScrollView(.horizontal) {
                        HStack(alignment: .top, spacing: Metrics.gapCovers) {
                            ForEach(items) { item in
                                Button { path.append(item) } label: {
                                    CoverCard(series: item, width: Metrics.coverDetailRowWidth)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, Metrics.gutter)
                    }
                    .scrollIndicators(.hidden)
                }
            }
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
            .foregroundStyle(Palette.textQuaternary)
            .padding(.horizontal, Metrics.gutter)
    }

    // MARK: - Sections

    /// Sequels, prequels, spin-offs and source novels. The strongest onward
    /// path there is, because it is an explicit link rather than a guess.
    @ViewBuilder
    private var relatedRow: some View {
        if !extras.relationships.isEmpty {
            VStack(alignment: .leading, spacing: 11) {
                Text("Related")
                    .typeDetailSectionHeader()
                    .foregroundStyle(Palette.textPrimary)
                    .padding(.horizontal, Metrics.gutter)

                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: Metrics.gapCovers) {
                        ForEach(extras.relationships) { relation in
                            Button { path.append(relation.series) } label: {
                                CoverCard(
                                    series: relation.series,
                                    width: Metrics.coverDetailRowWidth,
                                    meta: relation.label
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, Metrics.gutter)
                }
                .scrollIndicators(.hidden)
            }
        }
    }

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

    private func load() async {
        isLoading = true
        async let similarResult = repository.feed(.similar(seriesId: series.id), forceRefresh: false)
        async let alsoResult = repository.feed(.readersAlsoLike(seriesId: series.id), forceRefresh: false)
        async let extrasResult = repository.extras(for: series.id)
        similar = await similarResult.series
        alsoLike = await alsoResult.series
        extras = await extrasResult
        isLoading = false
        async let cast: Void = loadCast()
        async let cadence: Void = loadCadence()
        async let taste: Void = loadTaste()
        _ = await (cast, cadence, taste)
    }

    /// Cached for the session after the first series page, so this is one
    /// request per launch rather than one per page.
    private func loadTaste() async {
        favouredTags = await taste?.favouredTagNames() ?? []
    }

    /// Both tracker ids come from MangaBaka's own `source` block, so no lookup
    /// is needed to find them. A series carrying neither has no cast to show,
    /// and in that case nothing is asked and no row appears.
    private func loadCast() async {
        guard let characters,
              series.aniListID != nil || series.shikimoriID != nil
        else { return }
        isCastLoading = true
        defer { isCastLoading = false }
        cast = await characters.characters(
            aniListID: series.aniListID,
            shikimoriID: series.shikimoriID
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
              series.mangaUpdatesID != nil,
              ReleaseScheduleService.canPredict(status: series.status)
        else { return }
        isCadenceLoading = true
        defer { isCadenceLoading = false }
        if case let .measured(estimate) = await schedule.cadence(for: series) {
            cadence = estimate
        }
    }
}

/// Chips that wrap onto as many lines as they need.
struct FlowChips: View {
    let items: [String]

    var body: some View {
        if !items.isEmpty {
            FlowLayout {
                ForEach(items, id: \.self) { item in
                    Text(item)
                        .typeChip()
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.horizontal, 9)
                        // minHeight, not height: at accessibility text sizes a
                        // fixed 30pt pill clips its own label.
                        .frame(minHeight: Metrics.headerPill)
                        .background(Palette.surfaceChip, in: Capsule())
                        .overlay(Capsule().strokeBorder(Palette.border, lineWidth: 0.5))
                }
            }
        }
    }
}
