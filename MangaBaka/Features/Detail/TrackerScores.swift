import SwiftUI

/// The same series as scored by other trackers.
///
/// Real data from the API's `source` field, normalised to 0-100 so the numbers
/// are comparable — AniList's 100-point scale and Anime-Planet's 5-star scale
/// otherwise sit side by side meaning different things.
struct TrackerScores: View {
    let series: Series

    /// One extreme of a spread: the tracker's display name and its
    /// normalised (0-100) score, rounded for display.
    struct Extreme: Equatable {
        let name: String
        let score: Int
    }

    /// Whether readers of this series broadly agree, or are split, ported
    /// from a sibling project's "divisive" lens.
    enum Agreement: Equatable {
        case divisive(high: Extreme, low: Extreme)
        case agreed
    }

    /// GUESS: thresholds carried over from the sibling project, not derived
    /// from this app's own data. A spread this wide or narrow needs at
    /// least this many scored trackers to be meaningful.
    nonisolated private static let minSourcesForAgreement = 3
    nonisolated private static let divisiveSpread = 15.0
    nonisolated private static let agreedSpread = 5.0

    /// The disagreement (or agreement) verdict across a series' tracker
    /// scores, or nil when there isn't enough data to say anything, or the
    /// spread falls between the two thresholds.
    nonisolated static func agreement(_ source: [String: Series.TrackerEntry]) -> Agreement? {
        let scored = source
            .compactMap { key, entry -> (name: String, score: Double)? in
                guard let score = entry.ratingNormalized else { return nil }
                return (name: key, score: score)
            }
        guard scored.count >= minSourcesForAgreement else { return nil }

        guard let highest = scored.max(by: { $0.score < $1.score }),
              let lowest = scored.min(by: { $0.score < $1.score }) else { return nil }
        let spread = highest.score - lowest.score

        if spread >= divisiveSpread {
            return .divisive(
                high: Extreme(name: name(highest.name), score: Int(highest.score.rounded())),
                low: Extreme(name: name(lowest.name), score: Int(lowest.score.rounded()))
            )
        }
        if spread <= agreedSpread {
            return .agreed
        }
        return nil
    }

    private var entries: [(String, Double)] {
        (series.source ?? [:])
            .compactMap { name, entry -> (String, Double)? in
                guard let score = entry.ratingNormalized else { return nil }
                return (name, score)
            }
            .sorted { $0.0 < $1.0 }
    }

    private var agreement: Agreement? {
        Self.agreement(series.source ?? [:])
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
                                    .foregroundStyle(Palette.textMuted)
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

                if let line = verdictText(agreement) {
                    Text(line)
                        .typeSmallMeta()
                        .foregroundStyle(Palette.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, Metrics.gutter)
                }
            }
        }
    }

    private func verdictText(_ agreement: Agreement?) -> String? {
        switch agreement {
        case let .divisive(high, low):
            "Readers disagree: \(high.name) \(high.score), \(low.name) \(low.score)"
        case .agreed:
            "Every tracker agrees, within 5 points"
        case nil:
            nil
        }
    }

    /// The API's keys are snake_case identifiers. These are the names the
    /// trackers call themselves, which is what a reader recognises.
    nonisolated static func name(_ key: String) -> String {
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
