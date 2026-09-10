import SwiftUI

/// The synopsis, clamped to eight lines, tap anywhere on it to open or close.
///
/// MangaBaka descriptions are not one paragraph. A real one carries the
/// publisher's blurb, a source line, then a second blurb from a different
/// publisher and another source line — around forty lines on a phone, which put
/// the tags, the cast and every onward row a long scroll below the fold. The
/// synopsis is worth reading; it is not worth burying the rest of the page.
struct DetailSynopsis: View {
    let text: AttributedString

    @State private var isExpanded = false
    @State private var clampedHeight: CGFloat = 0
    @State private var fullHeight: CGFloat = 0

    static let collapsedLines = 8

    /// Whether the clamp actually cut anything.
    ///
    /// Measured, not guessed from a character count: the same text is a
    /// different number of lines at a different text size, on a different
    /// width, in a different language. The tolerance is for the sub-point
    /// differences that fall out of text layout — without it a synopsis that
    /// exactly fills eight lines offers a "View more" that reveals nothing.
    private var isTruncated: Bool { fullHeight > clampedHeight + 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(text)
                .typeBody()
                .foregroundStyle(Palette.textBody)
                .lineLimit(isExpanded ? nil : Self.collapsedLines)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background { clampedProbe }
                .background(alignment: .top) { fullProbe }

            if isTruncated {
                HStack(spacing: 5) {
                    Text(isExpanded ? "View less" : "View more")
                        .typeChip()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .foregroundStyle(Palette.accent)
            }
        }
        .padding(.horizontal, Metrics.gutter)
        // The whole block is the control, not just the label under it. Reaching
        // for a small word after reading eight lines of text is the wrong
        // gesture; the text is what you are already looking at.
        .contentShape(Rectangle())
        .onTapGesture {
            guard isTruncated || isExpanded else { return }
            withAnimation(.snappy(duration: 0.24)) { isExpanded.toggle() }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isTruncated || isExpanded ? .isButton : [])
        .accessibilityHint(
            isTruncated || isExpanded
                ? (isExpanded ? "Shows less of the description" : "Shows the whole description")
                : ""
        )
    }

    /// How tall the text is as displayed.
    private var clampedProbe: some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear { clampedHeight = proxy.size.height }
                .onChange(of: proxy.size.height) { _, height in clampedHeight = height }
        }
    }

    /// How tall the same text would be with no clamp.
    ///
    /// A second copy of the text, hidden, laid out at the same width with no
    /// line limit. Its own background reports its height, which is the part
    /// that matters: a `GeometryReader` placed in the *visible* text's
    /// background reports the clamped frame, so an earlier version of this
    /// compared a measurement against itself and concluded nothing was ever
    /// truncated — the "View more" button never appeared on any series.
    private var fullProbe: some View {
        Text(text)
            .typeBody()
            .fixedSize(horizontal: false, vertical: true)
            .hidden()
            .background {
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { fullHeight = proxy.size.height }
                        .onChange(of: proxy.size.height) { _, height in fullHeight = height }
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
