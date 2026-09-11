import SwiftUI

/// The covers' colour, bleeding into the ground behind a row.
///
/// The average of the first few covers' BlurHash colours — the DC term, read
/// without rendering — as a soft gradient behind the row: strongest at the
/// covers, gone by the bottom of the titles. A row of blue covers sits on a
/// faintly blue ground; a row of red ones on red. Nothing samples pixels and
/// nothing is blurred, so it costs a gradient per row.
///
/// The first six, not every cover in the row: a Discover row can hold sixty
/// once it has paged, and the colour should be the colour of what is on
/// screen, which is the first screenful. Not recomputed on scroll — the tint
/// is a hue for the row, not a live reflection, and a ground that shifted
/// colour under a scrolling thumb would read as a glitch.
extension View {
    func rowAmbient(_ series: [Series]) -> some View {
        background { RowAmbient(series: series) }
    }
}

struct RowAmbient: View {
    let series: [Series]

    /// How much of the covers' colour reaches the ground. A GUESS, tuned on
    /// the 16 Pro simulator: at 0.18 the ground beside "Rising this week"
    /// measured (28, 27, 26) against a page ground of (8, 8, 11) — there,
    /// but only if you looked. A row's average of six covers tends to a warm
    /// grey, so the strength has to carry more than a single colour would.
    nonisolated static let strength = 0.26
    nonisolated static let sampled = 6

    var body: some View {
        if let colour = Self.tint(for: series) {
            LinearGradient(
                stops: [
                    .init(color: colour.opacity(Self.strength), location: 0),
                    .init(color: colour.opacity(Self.strength * 0.5), location: 0.55),
                    .init(color: .clear, location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .padding(.horizontal, -Metrics.gutter)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    /// The mean of the sampled covers' average colours, or nil when none of
    /// them carries a BlurHash. A mean rather than the first cover's colour:
    /// one black-and-white manhwa cover among five colourful ones should not
    /// decide the row.
    nonisolated static func tint(for series: [Series]) -> Color? {
        let colours = series.prefix(sampled)
            .compactMap { $0.cover.blurhash }
            .compactMap(BlurHash.averageColour(of:))
        guard !colours.isEmpty else { return nil }
        let count = Double(colours.count)
        return Color(
            red: colours.map(\.red).reduce(0, +) / count,
            green: colours.map(\.green).reduce(0, +) / count,
            blue: colours.map(\.blue).reduce(0, +) / count
        )
    }
}
