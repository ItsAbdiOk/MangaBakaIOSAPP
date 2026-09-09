import SwiftUI

/// The mockup's minimum-rating control: five equal segments — Any, 6+, 7+, 8+,
/// 9+ — with the current choice named in the accent beside the heading.
///
/// It replaces a `Stepper`, which was wrong in two ways beyond looking
/// different. Reaching 9+ from Any took nine taps on a control whose whole
/// range is five useful values, and the arrows gave no indication of what those
/// values were until you had walked to them.
///
/// The API expresses rating 0-100, so a segment labelled "8+" sends 80.
struct RatingSegments: View {
    @Binding var minimum: Int?

    /// Nil is "Any" — not zero. Sending `minimum_rating=0` would be a filter
    /// that matches everything while still narrowing the query, which is how a
    /// control that does nothing gets shipped.
    static let steps: [Int?] = [nil, 60, 70, 80, 90]

    static func label(for step: Int?) -> String {
        guard let step else { return "Any" }
        return "\(step / 10)+"
    }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(Self.steps.enumerated()), id: \.offset) { _, step in
                let isOn = minimum == step
                Button { minimum = step } label: {
                    Text(Self.label(for: step))
                        .typeChip()
                        .foregroundStyle(isOn ? Palette.onAccent : Palette.textSecondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        // minHeight, not height: at accessibility text sizes a
                        // fixed 34pt segment clips its own label.
                        .frame(minHeight: Metrics.ratingSegment)
                        .background(
                            isOn ? Palette.accent : Palette.surfaceChip,
                            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    step == nil ? "Any rating" : "Rated \(step.map { $0 / 10 } ?? 0) or higher"
                )
                .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
            }
        }
    }
}
