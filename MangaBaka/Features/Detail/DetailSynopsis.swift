import SwiftUI

/// The synopsis, clamped to eight lines with a way to open it.
///
/// MangaBaka descriptions are not one paragraph. A real one carries the
/// publisher's blurb, a source line, then a second blurb from a different
/// publisher and another source line — around forty lines on a phone, which put
/// the tags, credits and every onward row a long scroll below the fold. The
/// synopsis is worth reading; it is not worth burying the rest of the page.
struct DetailSynopsis: View {
    let text: AttributedString

    @State private var isExpanded = false
    /// Whether the text is actually long enough to need the control. A "View
    /// more" under a three-line synopsis is a button that reveals nothing.
    @State private var isTruncated = false

    static let collapsedLines = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(text)
                .typeBody()
                .foregroundStyle(Palette.textBody)
                .lineLimit(isExpanded ? nil : Self.collapsedLines)
                .fixedSize(horizontal: false, vertical: true)
                // Measures the same text unclamped behind the visible one. The
                // heights differ only when the clamp actually cut something, so
                // this reports truncation for the size and width it is really
                // being laid out at rather than guessing from a character count.
                .background {
                    ViewThatFits(in: .vertical) {
                        Text(text)
                            .typeBody()
                            .lineLimit(Self.collapsedLines)
                            .hidden()
                            .onAppear { isTruncated = false }
                        Color.clear
                            .onAppear { isTruncated = true }
                    }
                    .accessibilityHidden(true)
                }

            if isTruncated {
                Button {
                    withAnimation(.snappy(duration: 0.22)) { isExpanded.toggle() }
                } label: {
                    HStack(spacing: 5) {
                        Text(isExpanded ? "View less" : "View more")
                            .typeChip()
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .rotationEffect(.degrees(isExpanded ? 180 : 0))
                    }
                    .foregroundStyle(Palette.accent)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, Metrics.gutter)
    }
}
