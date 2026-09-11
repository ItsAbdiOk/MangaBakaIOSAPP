import SwiftUI
import UIKit

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
            // Fades in as well as out. Starting at full strength on the
            // section header drew a hard top edge, and the row read as a
            // grey panel with a title on it rather than colour coming off
            // the covers (Abdi's phone, 2026-09-11).
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: colour.opacity(Self.strength), location: 0.3),
                    .init(color: colour.opacity(Self.strength * 0.6), location: 0.65),
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
        let mean = UIColor(
            red: colours.map(\.red).reduce(0, +) / count,
            green: colours.map(\.green).reduce(0, +) / count,
            blue: colours.map(\.blue).reduce(0, +) / count,
            alpha: 1
        )
        // The mean of six covers is nearly grey — on the Rising row it
        // measured (28, 27, 26) at strength — so the hue is pushed back up
        // and the colour lifted before it goes on a near-black ground. The
        // factors are GUESSES.
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0
        mean.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: nil)
        return Color(
            hue: hue,
            saturation: min(1, saturation * 2.2 + 0.2),
            brightness: max(brightness, 0.7)
        )
    }
}
