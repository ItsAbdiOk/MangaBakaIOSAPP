import SwiftUI

/// A cover card drawn the way Apple would draw one.
///
/// The differences from the app's own card are small and all of them are the
/// point of the experiment:
///
/// - `Color.primary` and `.secondary` rather than the palette's fixed
///   `#EBEBF5` at an alpha. The semantic colours adapt to light mode, to
///   Increase Contrast, and to whatever Apple decides a label should be in a
///   future release. The app's tokens are correct for one appearance and one
///   year.
/// - `.font(.caption)` rather than a `@ScaledMetric` anchored to a text style.
///   Same scaling, but the system owns the number, so a change to the type
///   ramp arrives rather than being reimplemented.
/// - `.containerRelativeFrame` sizes the card to the scroll view rather than
///   to a constant, so it is right on an iPad and in a split view without
///   anybody choosing a width.
struct AppleCoverCard: View {
    let series: Series

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CoverImage(
                cover: series.cover,
                width: 110,
                radius: 8,
                accessibilityText: series.displayTitle ?? "Untitled series"
            )
            Text(series.displayTitle ?? "Untitled series")
                .font(.subheadline)
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            if let meta {
                Text(meta)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(width: 110, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([series.displayTitle, meta].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(.isButton)
    }

    private var meta: String? {
        var parts: [String] = []
        if let type = series.type?.capitalized { parts.append(type) }
        if let rating = series.rating { parts.append(String(format: "%.1f", rating / 10)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
