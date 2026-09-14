import Testing
import CoreGraphics
@testable import MangaBaka

/// The wrapping rule, and the measurement it is allowed to do.
///
/// `FlowLayout` declared `cache: inout ()` and used none of it: `sizeThatFits`
/// and `placeSubviews` each called `arrange`, which asked every subview for
/// its size, and `placeSubviews` then asked each one *again* while placing it.
/// A chip's `sizeThatFits` is a text measurement, so the tag groups on the
/// series page re-measured every label four times per layout pass. The sizes
/// now come from the `Layout` cache, taken once, and the wrapping rule is a
/// pure function over them — which is what lets it be asserted here at all.
@Suite("Flow layout wrapping")
struct FlowLayoutArrangeTests {
    private func chip(_ width: CGFloat, _ height: CGFloat = 30) -> CGSize {
        CGSize(width: width, height: height)
    }

    /// Expected to fail before the fix with: "type 'FlowLayout' has no member
    /// 'arrange'" — `arrange` was `private` and took `Subviews`, so it could
    /// only be exercised by rendering a view.
    @Test("Chips wrap when the next one will not fit")
    func wrapsOnOverflow() {
        // 100 + 8 + 100 = 208 fits in 250; adding a third needs 316.
        let rows = FlowLayout.arrange(
            sizes: [chip(100), chip(100), chip(100)], maxWidth: 250, spacing: 8
        )
        #expect(rows.map(\.indices) == [[0, 1], [2]])
    }

    @Test("Everything that fits stays on one line")
    func oneLineWhenItFits() {
        let rows = FlowLayout.arrange(
            sizes: [chip(40), chip(40), chip(40)], maxWidth: 400, spacing: 8
        )
        #expect(rows.map(\.indices) == [[0, 1, 2]])
        // `CGFloat(...)`, not a bare arithmetic literal: `#expect` captures
        // each side of `==` through its own autoclosure for the failure
        // message, and a standalone `40 * 3 + 8 * 2` defaults to `Int` there
        // even though it type-checks as `CGFloat` in the real comparison —
        // the macro's diagnostic then compares the two through `Any` and an
        // `Int` is never equal to a `CGFloat` there, however numerically
        // equal. Confirmed with a throwaway `swift test` package: the same
        // literal outside `#expect` compares `true`, and forcing `CGFloat`
        // here makes `#expect` agree.
        #expect(rows[0].width == CGFloat(40 * 3 + 8 * 2))
    }

    /// A single chip wider than the container used to hang off the edge. At
    /// large text sizes one long publisher name is enough, so it is capped to
    /// the container and left to truncate inside its own bounds.
    @Test("A chip wider than the container is capped, not overhung")
    func oversizeChipIsCapped() {
        let rows = FlowLayout.arrange(sizes: [chip(900)], maxWidth: 300, spacing: 8)
        #expect(rows.map(\.indices) == [[0]])
        #expect(rows[0].width == 300)
    }

    /// A row is as tall as its tallest member, or a two-line chip clips
    /// against the row below it.
    @Test("A row takes the height of its tallest chip")
    func rowHeightIsTheTallest() {
        let rows = FlowLayout.arrange(
            sizes: [chip(40, 30), chip(40, 52)], maxWidth: 400, spacing: 8
        )
        #expect(rows.count == 1)
        #expect(rows[0].height == 52)
    }

    @Test("Nothing in, nothing out")
    func emptyIsEmpty() {
        #expect(FlowLayout.arrange(sizes: [], maxWidth: 300, spacing: 8).isEmpty)
    }
}
