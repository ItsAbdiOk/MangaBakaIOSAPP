import Foundation

/// Pure decisions for the stack's drag gesture, kept out of `StackView` so
/// they can be tested without a view hierarchy.
enum StackGesture {
    /// Whether the drag just crossed `threshold` on this frame, in either
    /// direction of travel.
    ///
    /// A latch, not a level: `abs(current) >= threshold` alone would be true
    /// for every frame the finger holds past the commit line, and wiring
    /// that straight to a haptic would buzz continuously for as long as the
    /// reader held the card there. Comparing against `previous` means it
    /// answers true exactly once per crossing — and true again if the reader
    /// drags back under the line and re-crosses it, which is a second,
    /// distinct commitment worth its own tick.
    nonisolated static func crossedThreshold(
        previous: CGFloat, current: CGFloat, threshold: CGFloat
    ) -> Bool {
        abs(previous) < threshold && abs(current) >= threshold
    }
}
