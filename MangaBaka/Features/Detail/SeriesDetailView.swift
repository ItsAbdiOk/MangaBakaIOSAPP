import SwiftUI

/// The rabbit hole. Every row is a way onward; the screen must never dead-end.
struct SeriesDetailView: View {
    let series: Series
    let repository: any SeriesRepositoryProtocol
    let library: any LibraryProviding
    /// The release schedule, read from its cache only — see `cachedCadence`.
    let schedule: ReleaseScheduleService?
    @Binding var path: [Series]
    /// Sends this series to Mix as a seed and switches to that tab.
    var onUseAsSeed: ((Series) -> Void)?
    /// Opens a search for one of the series' tags.
    var onOpenTag: ((String) -> Void)?
    var onOpenSchedule: (() -> Void)?

    @State private var similar: [Series] = []
    @State private var alsoLike: [Series] = []
    @State private var extras = SeriesExtras()
    @State private var cadence: Cadence?
    @State private var isLoading = true
    @Environment(\.openURL) private var openURL
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
                    onOpenSchedule: onOpenSchedule
                )
                .padding(.top, 4)
                actions
                DetailStatsStrip(series: series, year: extras.year)
                if let description = series.description, !description.isEmpty {
                    Text(Self.prose(from: description))
                        .typeBody()
                        .foregroundStyle(Palette.textBody)
                        .padding(.horizontal, Metrics.gutter)
                }
                DetailTags(tags: extras.tags) { tag in
                    onOpenTag?(tag)
                }
                DetailCredits(series: series)
                relatedRow
                onwardRow("Similar", similar)
                onwardRow("Readers also like", alsoLike)
                trackerScores
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
        HStack(spacing: Metrics.gapStrip) {
            LibraryControl(series: series, library: library)
                .padding(.leading, Metrics.gutter)
            if onUseAsSeed != nil {
                Button { onUseAsSeed?(series) } label: {
                    Text("Use as seed")
                        .typeChip()
                        .lineLimit(1)
                        .padding(.horizontal, 16)
                        .frame(height: Metrics.ctaPrimary)
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
        .padding(.trailing, Metrics.gutter)
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

    /// The same series scored by other trackers. Real data from the API's
    /// `source` field, normalised to 0-100 so the numbers are comparable —
    /// AniList's 100-point scale and Anime-Planet's 5-star scale otherwise
    /// sit side by side meaning different things.
    @ViewBuilder
    private var trackerScores: some View {
        let entries = (series.source ?? [:])
            .compactMap { name, entry -> (String, Double)? in
                guard let score = entry.ratingNormalized else { return nil }
                return (name, score)
            }
            .sorted { $0.0 < $1.0 }

        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 11) {
                Text("Scores elsewhere")
                    .typeDetailSectionHeader()
                    .foregroundStyle(Palette.textPrimary)
                    .padding(.horizontal, Metrics.gutter)

                ScrollView(.horizontal) {
                    HStack(spacing: Metrics.gapStrip) {
                        ForEach(entries, id: \.0) { name, score in
                            VStack(spacing: 3) {
                                Text(String(format: "%.1f", score / 10))
                                    .scaledFont(size: 22, weight: .bold, relativeTo: .title2)
                                    .foregroundStyle(Palette.textPrimary)
                                Text(trackerName(name))
                                    .typeGridMeta()
                                    .foregroundStyle(Palette.textTertiary)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(Palette.surface, in: RoundedRectangle(
                                cornerRadius: Metrics.radiusThumb, style: .continuous
                            ))
                        }
                    }
                    .padding(.horizontal, Metrics.gutter)
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    private func trackerName(_ key: String) -> String {
        switch key {
        case "anilist": "AniList"
        case "my_anime_list": "MyAnimeList"
        case "anime_planet": "Anime-Planet"
        case "manga_updates": "MangaUpdates"
        case "anime_news_network": "ANN"
        case "kitsu": "Kitsu"
        default: key.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

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
        cadence = await schedule?.cachedCadence(forSeriesId: series.id)
        isLoading = false
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
