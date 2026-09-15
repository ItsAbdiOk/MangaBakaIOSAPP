import SwiftUI

/// The gallery's other covers, small, along the bottom — the cue that there
/// is more than the one on screen.
///
/// Asked for by Abdi (2026-09-15): opening the gallery on its front cover
/// showed one card and "1 of 17" in the bar, and he waited for the rest to
/// load rather than swiping. The strip is the fan's promise kept: every
/// cover visible at once, the current one lit, a tap to jump. Thumbnails
/// arrive in the volumes row's stagger, so a strip of seventeen assembles
/// rather than appears — and a cover landing late (`appendLateCovers`)
/// joins the end the same way.
struct CoverFilmstrip: View {
    let covers: [Cover]
    @Binding var selection: Int?

    /// Kept separate from `selection` so the strip follows the pager
    /// without the pager following the strip's own scroll.
    @State private var scrolledThumb: Int?

    private static let thumbWidth: CGFloat = 34
    private static let radius: CGFloat = 6

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 8) {
                ForEach(Array(covers.enumerated()), id: \.offset) { index, cover in
                    Button {
                        Motion.run(.snappy) { selection = index }
                    } label: {
                        CoverImage(cover: cover, width: Self.thumbWidth, radius: Self.radius)
                            .overlay {
                                RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
                                    .strokeBorder(
                                        Palette.accent, lineWidth: selection == index ? 2 : 0
                                    )
                            }
                            .opacity(selection == index ? 1 : 0.6)
                            .animation(Motion.reduced(Motion.snappy), value: selection)
                    }
                    .buttonStyle(.press)
                    .id(index)
                    .arrives(index: index)
                    .accessibilityLabel("Cover \(index + 1) of \(covers.count)")
                }
            }
            .padding(.horizontal, Metrics.gutter)
            .scrollTargetLayout()
        }
        .scrollIndicators(.hidden)
        .scrollPosition(id: $scrolledThumb, anchor: .center)
        .frame(height: Self.thumbWidth / Metrics.coverAspect + 12)
        .onChange(of: selection, initial: true) {
            Motion.run(.snappy) { scrolledThumb = selection }
        }
    }
}
