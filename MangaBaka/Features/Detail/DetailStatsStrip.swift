import SwiftUI

/// The mockup's divided stats card: Rating, Ratings, Chapters, Volumes,
/// Started, each a number over an uppercase label.
///
/// It replaces a row of grey chips that said the same things in prose ("201
/// ch"), and it is where the rating count finally appears — the API has always
/// returned it and nothing showed it, so a 6.4-from-3 series and a
/// 6.4-from-64,000 series read identically.
///
/// Segments the API did not answer for are dropped rather than shown empty. A
/// series with no volumes is ordinary, and "—" in a box is not information.
struct DetailStatsStrip: View {
    let series: Series
    /// From `/v1/series/{id}`, because v2 has no `year` field at all — checked
    /// against the live API, on both the feeds and `/v2/series/{id}`.
    var year: Int?
    /// The schedule's current season, when it has read one. A webtoon on its
    /// third season numbers its episodes from one each time, so "212
    /// episodes" alone says less than "Season 3 · 212".
    var season: Int?

    /// Manhwa, manhua and webtoons are published in episodes on a platform,
    /// not chapters in a magazine, and readers of them say "episode".
    ///
    /// This no longer renames the count — Abdi asked for "Chapters" everywhere
    /// (2026-09-12). The number was always MangaBaka's chapter count, so one
    /// word for it is the honest label and the app now says the same thing on
    /// the stats strip, the library rows and the catch-up estimate. Still used
    /// for the "Season" stat, which is genuinely a webtoon idea.
    var isEpisodic: Bool {
        guard let type = series.type?.lowercased() else { return false }
        return ["manhwa", "manhua", "webtoon", "webcomic"].contains(type)
    }

    struct Stat: Identifiable {
        let id: String
        let value: String
        var label: String { id }
    }

    var stats: [Stat] {
        var out: [Stat] = []
        // `> 0` like every other stat here. A series that comes back rated 0
        // rather than null showed "0.0 RATING" as a headline number, with the
        // ratings count beside it dropped for being zero — so nothing on screen
        // exposed it as an absence.
        if let rating = series.rating, rating > 0 {
            out.append(Stat(id: "Rating", value: String(format: "%.1f", rating / 10)))
        }
        if let count = series.ratingCount, count > 0 {
            out.append(Stat(id: "Ratings", value: Self.compact(count)))
        }
        if isEpisodic, let season, season > 0 {
            out.append(Stat(id: "Season", value: String(season)))
        }
        if let chapters = series.totalChapters, chapters > 0 {
            out.append(Stat(id: "Chapters", value: String(Int(wholeOrClamped: chapters))))
        }
        if let volumes = series.finalVolume, volumes > 0 {
            out.append(Stat(id: "Volumes", value: String(Int(wholeOrClamped: volumes))))
        }
        // `published.rangeLine` ("2020 – ongoing") answers a question the
        // bare year never could — whether the series has ended — so it wins
        // whenever the v1 record carries it. `year` is the fallback for
        // every payload recorded before `published` existed.
        if let range = series.published?.rangeLine {
            out.append(Stat(id: "Started", value: range))
        } else if let year = year ?? series.year, year > 0 {
            out.append(Stat(id: "Started", value: String(year)))
        }
        return out
    }

    /// "#14 overall · #2 among manhwa — was #18 a year ago", from `popularity`.
    /// Shown as its own line under the number strip rather than folded into
    /// `stats`: it is a sentence, not a number-over-label column, and forcing
    /// it into that shape either truncates the words or shrinks every other
    /// stat down with it. Nil (and so drawn as nothing) when the series
    /// carries no `popularity` at all — absent on every v2 payload and on
    /// any row cached before this landed.
    private var popularityLine: String? { series.popularityTrendLine }

    @Environment(\.dynamicTypeSize) private var typeSize

    private var hasFooterLine: Bool {
        series.isLicensed == true || popularityLine != nil
    }

    var body: some View {
        if !stats.isEmpty || hasFooterLine {
            VStack(alignment: .leading, spacing: 0) {
                if !stats.isEmpty {
                    // One row, always, until the text is so large that
                    // shrinking it stops being legible.
                    //
                    // The first attempt wrapped to a second row as soon as
                    // five columns stopped fitting, which was one notch above
                    // the default text size — so an ordinary reader got a
                    // two-row card where the design has a strip. Scaling the
                    // labels instead keeps the strip a strip: they are five
                    // short words and 70% of small is still readable.
                    Group {
                        if typeSize.isAccessibilitySize {
                            FlowLayout(spacing: 0) { segments(fillsWidth: false) }
                        } else {
                            HStack(spacing: 0) { segments(fillsWidth: true) }
                        }
                    }
                }
                if hasFooterLine {
                    if !stats.isEmpty {
                        Divider().overlay(Palette.hairline)
                    }
                    footerLine
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.surface, in: RoundedRectangle(
                cornerRadius: Metrics.radiusCard, style: .continuous
            ))
            .hairlineBorder(Palette.hairline, radius: Metrics.radiusCard)
            .padding(.horizontal, Metrics.gutter)
        }
    }

    /// The "Licensed" chip and the popularity trend — the two bits of the
    /// v1 record that read as a sentence or a badge rather than a number, so
    /// they sit under the strip instead of squeezed into one of its columns.
    /// Nothing here shows when neither field is present.
    @ViewBuilder
    private var footerLine: some View {
        VStack(alignment: .leading, spacing: 6) {
            if series.isLicensed == true {
                Text("Licensed")
                    .typeChip()
                    .foregroundStyle(Palette.textEmphasis)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Palette.surfaceChip, in: Capsule())
            }
            if let popularityLine {
                Text(popularityLine)
                    .typeSmallMeta()
                    .foregroundStyle(Palette.textMuted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func segments(fillsWidth: Bool) -> some View {
        ForEach(Array(stats.enumerated()), id: \.element.id) { index, stat in
            VStack(spacing: 3) {
                Text(stat.value)
                    .typeRowTitle()
                    .foregroundStyle(Palette.textEmphasis)
                    .lineLimit(1)
                    .minimumScaleFactor(fillsWidth ? 0.7 : 1)
                Text(stat.label.uppercased())
                    .typeGridMeta()
                    .tracking(0.4)
                    .foregroundStyle(Palette.textMuted)
                    .lineLimit(1)
                    // A one-word label that wraps is always a defect. Shrinking
                    // it is the lesser evil, and "CHAPTERS" at 70% still reads.
                    .minimumScaleFactor(fillsWidth ? 0.7 : 1)
            }
            .fixedSize(horizontal: !fillsWidth, vertical: false)
            .frame(maxWidth: fillsWidth ? .infinity : nil)
            .padding(.vertical, 12)
            .padding(.horizontal, fillsWidth ? 4 : 14)
            .overlay(alignment: .trailing) {
                if fillsWidth, index < stats.count - 1 {
                    Rectangle().fill(Palette.hairline).frame(width: 0.5)
                }
            }
        }
    }

    /// "64.2k" rather than "64,231". The exact count is noise; the order of
    /// magnitude is the whole point of showing it.
    nonisolated static func compact(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fm", Double(count) / 1_000_000)
        }
        if count >= 1_000 {
            // Rounded before the suffix is chosen, or 999,950...999,999
            // formats to one decimal as "1000.0k" instead of crossing into
            // "m" — the boundary a straight division-then-format misses.
            let thousands = (Double(count) / 1_000 * 10).rounded() / 10
            if thousands >= 1_000 {
                return String(format: "%.1fm", Double(count) / 1_000_000)
            }
            return String(format: "%.1fk", thousands)
        }
        return String(count)
    }
}
