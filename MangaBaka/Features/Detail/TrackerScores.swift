import SwiftUI

/// The same series as scored by other trackers.
///
/// Real data from the API's `source` field, normalised to 0-100 so the numbers
/// are comparable — AniList's 100-point scale and Anime-Planet's 5-star scale
/// otherwise sit side by side meaning different things.
struct TrackerScores: View {
    let series: Series

    private var entries: [(String, Double)] {
        (series.source ?? [:])
            .compactMap { name, entry -> (String, Double)? in
                guard let score = entry.ratingNormalized else { return nil }
                return (name, score)
            }
            .sorted { $0.0 < $1.0 }
    }

    var body: some View {
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
                                Text(Self.name(name))
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

    /// The API's keys are snake_case identifiers. These are the names the
    /// trackers call themselves, which is what a reader recognises.
    static func name(_ key: String) -> String {
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
}
