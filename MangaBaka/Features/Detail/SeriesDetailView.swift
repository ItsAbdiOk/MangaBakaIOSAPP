import SwiftUI

/// The rabbit hole. Every row is a way onward; the screen must never dead-end.
struct SeriesDetailView: View {
    let series: Series
    let repository: any SeriesRepositoryProtocol
    @Binding var path: [Series]

    @State private var similar: [Series] = []
    @State private var alsoLike: [Series] = []
    @State private var extras = SeriesExtras()
    @State private var isLoading = true
    @Environment(\.openURL) private var openURL
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.detailRowGap) {
                hero
                if let description = series.description, !description.isEmpty {
                    Text(description)
                        .typeBody()
                        .foregroundStyle(Palette.textBody)
                        .padding(.horizontal, Metrics.gutter)
                }
                trackerScores
                relatedRow
                onwardRow("Similar", similar)
                onwardRow("Readers also like", alsoLike)
                publishersSection
                readElsewhere
                newsSection
                provenance
            }
            .padding(.top, 12)
            .padding(.bottom, Metrics.scrollBottomInset)
        }
        .scrollIndicators(.hidden)
        .background(Palette.ground)
        .navigationTitle(series.displayTitle ?? "Series")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: series.id) { await load() }
    }

    private var hero: some View {
        HStack(alignment: .top, spacing: Metrics.gapHero) {
            CoverImage(
                cover: series.cover,
                width: Metrics.coverDetailHeroWidth,
                radius: Metrics.radiusCoverRow
            )
            VStack(alignment: .leading, spacing: 8) {
                Text(series.displayTitle ?? "Untitled series")
                    .typeDetailHeroTitle()
                    .foregroundStyle(Palette.textEmphasis)
                    .fixedSize(horizontal: false, vertical: true)

                if let authors = series.authors, !authors.isEmpty {
                    Text(authors.joined(separator: ", "))
                        .typeSubtitle()
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(2)
                }

                // Only chips the API actually gave us. A missing field shows
                // nothing rather than a guess.
                FlowChips(items: chips)
            }
        }
        .padding(.horizontal, Metrics.gutter)
    }

    private var chips: [String] {
        var out: [String] = []
        if let type = series.type { out.append(type.capitalized) }
        if let status = series.status { out.append(status.capitalized) }
        if let rating = series.rating {
            out.append(String(format: "%.1f", rating / 10))
        }
        if let chapters = series.totalChapters, chapters > 0 {
            out.append("\(Int(chapters)) ch")
        }
        return out
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
    private var publishersSection: some View {
        if let publishers = series.publishers, !publishers.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Published by")
                    .typeDetailSectionHeader()
                    .foregroundStyle(Palette.textPrimary)
                FlowChips(items: publishers.map { publisher in
                    if let type = publisher.type { "\(publisher.name) · \(type)" } else { publisher.name }
                })
            }
            .padding(.horizontal, Metrics.gutter)
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

    private func load() async {
        isLoading = true
        async let similarResult = repository.feed(.similar(seriesId: series.id), forceRefresh: false)
        async let alsoResult = repository.feed(.readersAlsoLike(seriesId: series.id), forceRefresh: false)
        async let extrasResult = repository.extras(for: series.id)
        similar = await similarResult.series
        alsoLike = await alsoResult.series
        extras = await extrasResult
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
