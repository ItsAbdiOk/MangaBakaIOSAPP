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
    /// One tick per pip boundary the finger has crossed since the drag
    /// began — `.haptic(_:onEach:)` needs an ever-increasing counter, not
    /// the index itself, which can decrease as a finger drags back down.
    @State private var crossings = 0
    /// Tracked with `.onGeometryChange` rather than a wrapping
    /// `GeometryReader`: a `GeometryReader` forces its content to a
    /// resolved size before layout, which is exactly what the `minHeight`
    /// below is there to avoid — a `height` would clip the label the moment
    /// Dynamic Type grows past it.
    @State private var trackWidth: CGFloat = 0

    /// Nil is "Any" — not zero. Sending `minimum_rating=0` would be a filter
    /// that matches everything while still narrowing the query, which is how a
    /// control that does nothing gets shipped.
    static let steps: [Int?] = [nil, 60, 70, 80, 90]

    static func label(for step: Int?) -> String {
        guard let step else { return "Any" }
        return "\(step / 10)+"
    }

    private var selectedIndex: Int { Self.steps.firstIndex(of: minimum) ?? 0 }

    /// How many pip boundaries a drag crossed moving from index `from` to
    /// index `to`. Pure so the drag's haptic count is testable without a
    /// live gesture: a fast drag across three pips still owes three ticks,
    /// not one for wherever the finger happened to land.
    nonisolated static func pipsCrossed(from: Int, to: Int) -> Int {
        abs(to - from)
    }

    /// Which segment a horizontal position falls in, clamped to the ends so a
    /// finger dragged past either edge still resolves to the first or last
    /// pip rather than losing the gesture. Mirrors `JumpIndex.letterIndex`.
    nonisolated static func index(atX x: CGFloat, width: CGFloat, count: Int) -> Int {
        guard count > 0, width > 0 else { return 0 }
        let clampedX = min(max(x, 0), width)
        let raw = Int(clampedX / width * CGFloat(count))
        return min(max(raw, 0), count - 1)
    }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(Self.steps.enumerated()), id: \.offset) { index, step in
                // Filled left-to-right up to the current selection, not
                // just the one segment exactly matched — a rating reads
                // as a level filled, not a single lit tile.
                let isOn = index <= selectedIndex && minimum != nil
                Button { select(index) } label: {
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
                        // Fills left-to-right: each pip's own turn to light
                        // up waits a beat longer than the one before it, so
                        // a jump from "Any" to "9+" reads as a sweep rather
                        // than four tiles switching at once. A guess,
                        // matched to `Motion.stagger`'s own step.
                        .animation(
                            Motion.reduced(Motion.snappy.delay(Motion.stagger(index, step: 0.03))),
                            value: isOn
                        )
                }
                .buttonStyle(.press)
                .accessibilityLabel(
                    step == nil ? "Any rating" : "Rated \(step.map { $0 / 10 } ?? 0) or higher"
                )
                .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
            }
        }
        .contentShape(Rectangle())
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { trackWidth = $0 }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in scrub(to: value.location.x, width: trackWidth) }
        )
        .haptic(Haptics.tick, onEach: crossings)
        // Landing on the top step is the reward; every lesser pip crossed on
        // the way there is just `Haptics.tick`.
        .sensoryFeedback(Haptics.success, trigger: minimum) { _, new in
            new == Self.steps.last.flatMap { $0 }
        }
    }

    private func select(_ index: Int) {
        crossings += Self.pipsCrossed(from: selectedIndex, to: index)
        minimum = Self.steps[index]
    }

    private func scrub(to x: CGFloat, width: CGFloat) {
        let index = Self.index(atX: x, width: width, count: Self.steps.count)
        guard index != selectedIndex else { return }
        select(index)
    }
}
