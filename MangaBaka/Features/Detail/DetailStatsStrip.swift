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
        if let chapters = series.totalChapters, chapters > 0 {
            out.append(Stat(id: "Chapters", value: String(Int(chapters))))
        }
        if let volumes = series.finalVolume, volumes > 0 {
            out.append(Stat(id: "Volumes", value: String(Int(volumes))))
        }
        if let year = year ?? series.year, year > 0 {
            out.append(Stat(id: "Started", value: String(year)))
        }
        return out
    }

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        if !stats.isEmpty {
            // One row, always, until the text is so large that shrinking it
            // stops being legible.
            //
            // The first attempt wrapped to a second row as soon as five columns
            // stopped fitting, which was one notch above the default text size
            // — so an ordinary reader got a two-row card where the design has a
            // strip. Scaling the labels instead keeps the strip a strip: they
            // are five short words and 70% of small is still readable.
            Group {
                if typeSize.isAccessibilitySize {
                    FlowLayout(spacing: 0) { segments(fillsWidth: false) }
                } else {
                    HStack(spacing: 0) { segments(fillsWidth: true) }
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
                    .foregroundStyle(Palette.textQuaternary)
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
    static func compact(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fm", Double(count) / 1_000_000)
        }
        if count >= 1_000 {
            return String(format: "%.1fk", Double(count) / 1_000)
        }
        return String(count)
    }
}
