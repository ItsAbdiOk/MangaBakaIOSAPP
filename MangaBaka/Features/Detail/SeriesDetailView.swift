import SwiftUI

/// The rabbit hole. Every row is a way onward; the screen must never dead-end.
struct SeriesDetailView: View {
    let series: Series
    let repository: any SeriesRepositoryProtocol
    @Binding var path: [Series]

    @State private var similar: [Series] = []
    @State private var alsoLike: [Series] = []
    @State private var isLoading = true
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
                onwardRow("Similar", similar)
                onwardRow("Readers also like", alsoLike)
                provenance
            }
            .padding(.top, 12)
            .padding(.bottom, 24)
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

    private func load() async {
        isLoading = true
        async let similarResult = repository.feed(.similar(seriesId: series.id), forceRefresh: false)
        async let alsoResult = repository.feed(.readersAlsoLike(seriesId: series.id), forceRefresh: false)
        similar = await similarResult.series
        alsoLike = await alsoResult.series
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
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 9)
                        .frame(height: Metrics.headerPill)
                        .background(Palette.surfaceChip, in: Capsule())
                        .overlay(Capsule().strokeBorder(Palette.border, lineWidth: 0.5))
                }
            }
        }
    }
}
