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

    @Environment(\.dynamicTypeSize) private var typeSize

    struct Stat: Identifiable {
        let id: String
        let value: String
        var label: String { id }
    }

    var stats: [Stat] {
        var out: [Stat] = []
        if let rating = series.rating {
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

    var body: some View {
        if !stats.isEmpty {
            // Five segments across a phone are already narrow; at accessibility
            // text sizes they cannot hold a five-digit rating count and a word,
            // so the strip becomes a wrapping grid rather than clipping.
            Group {
                if typeSize.isAccessibilitySize {
                    // Each segment takes its own width here. Left at
                    // maxWidth: .infinity — right for five columns — a wrapped
                    // segment claimed the whole row, so "2025 / STARTED" sat
                    // alone across the screen at title size.
                    FlowLayout(spacing: 0) { segments(fillsWidth: false) }
                } else {
                    HStack(spacing: 0) { segments(fillsWidth: true) }
                }
            }
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
                Text(stat.label.uppercased())
                    .typeGridMeta()
                    .tracking(0.4)
                    .foregroundStyle(Palette.textQuaternary)
            }
            .frame(maxWidth: fillsWidth ? .infinity : nil)
            .padding(.vertical, 12)
            .padding(.horizontal, fillsWidth ? 6 : 14)
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
