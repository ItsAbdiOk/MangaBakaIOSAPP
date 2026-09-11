import Testing
import UIKit
@testable import MangaBaka

/// Whether the type ramp actually grows at every Dynamic Type step.
///
/// Apple's audit reports "Dynamic Type font sizes are partially unsupported"
/// on fifteen elements, all of them small type: the meta line under a cover
/// card ("Manga · 8.4"), the Settings section headers, the stack's provenance
/// line. Those use `typeGridMeta` and `typeEyebrow`, which ARE declared
/// relative to `.caption2`, so the report looked wrong.
///
/// `@ScaledMetric(relativeTo:)` is `UIFontMetrics.scaledValue(for:)` under a
/// different name, so the ramp can be measured here rather than guessed at
/// from a screenshot.
@Suite("Dynamic Type ramp")
struct DynamicTypeRampTests {
    /// Every content size category iOS can be set to, smallest first.
    private static let categories: [UIContentSizeCategory] = [
        .extraSmall, .small, .medium, .large, .extraLarge, .extraExtraLarge,
        .extraExtraExtraLarge, .accessibilityMedium, .accessibilityLarge,
        .accessibilityExtraLarge, .accessibilityExtraExtraLarge,
        .accessibilityExtraExtraExtraLarge
    ]

    /// One entry in the ramp: what it is called, its base size, and the text
    /// style `@ScaledMetric` anchors it to.
    private struct Style {
        let name: String
        let size: CGFloat
        let anchor: UIFont.TextStyle
    }

    private static let ramp: [Style] = [
        Style(name: "typeGridMeta", size: 10.5, anchor: .subheadline),
        Style(name: "typeEyebrow", size: 11, anchor: .subheadline),
        Style(name: "typeFootnote", size: 11, anchor: .subheadline),
        Style(name: "typeSmallMeta", size: 11.5, anchor: .subheadline),
        Style(name: "typeCardTitle", size: 12, anchor: .subheadline),
        Style(name: "typeChip", size: 12.5, anchor: .subheadline),
        Style(name: "typeSubtitle", size: 13, anchor: .subheadline),
        Style(name: "typeRowTitle", size: 13.5, anchor: .subheadline),
        Style(name: "typeBody", size: 14, anchor: .body)
    ]

    private func scaled(
        _ size: CGFloat,
        _ style: UIFont.TextStyle,
        _ category: UIContentSizeCategory
    ) -> CGFloat {
        UIFontMetrics(forTextStyle: style).scaledValue(
            for: size,
            compatibleWith: UITraitCollection(preferredContentSizeCategory: category)
        )
    }

    @Test("Every style grows at every step, with no step that does nothing")
    func rampGrowsAtEveryStep() {
        var stalled: [String] = []
        for style in Self.ramp {
            let values = Self.categories.map { scaled(style.size, style.anchor, $0) }
            for index in 1..<values.count where values[index] <= values[index - 1] {
                stalled.append(
                    "\(style.name) \(Self.categories[index - 1].rawValue)->"
                    + "\(Self.categories[index].rawValue): \(values[index - 1]) -> \(values[index])"
                )
            }
        }
        #expect(stalled.isEmpty, "steps where the text did not grow: \(stalled)")
    }

    /// Which text styles grow at every step, measured rather than assumed.
    ///
    /// Writes the whole table to /tmp so the choice of anchor is a reading of
    /// data rather than a guess. Never asserts: it is an instrument.
    @Test("Record how each anchor style behaves across the range")
    func recordAnchorBehaviour() {
        let anchors: [(String, UIFont.TextStyle)] = [
            ("caption2", .caption2), ("caption1", .caption1), ("footnote", .footnote),
            ("subheadline", .subheadline), ("callout", .callout), ("body", .body)
        ]
        var lines: [String] = []
        for (name, anchor) in anchors {
            let values = Self.categories.map { scaled(10.5, anchor, $0) }
            let stalls = (1..<values.count).filter { values[$0] <= values[$0 - 1] }.count
            let rendered = values.map { String(format: "%.1f", $0) }.joined(separator: " ")
            lines.append("\(name)\tstalls=\(stalls)\t\(rendered)")
        }
        try? lines.joined(separator: "\n")
            .write(toFile: "/tmp/mb-type-anchors.txt", atomically: true, encoding: .utf8)
        #expect(!lines.isEmpty)
    }
}
