import SwiftUI

/// A slow highlight passing over a placeholder.
///
/// The app already knows the colours of a cover before it arrives — the API
/// ships a BlurHash with every one — so a loading grid has the right shapes
/// and the right colours. What it did not have was motion: a static blur or
/// a grey block says "broken", the same picture moving says "working". This
/// is that movement. One pass every 1.6 s, a guess: slower read as stuck,
/// faster as nervous. Identity under Reduce Motion.
struct Shimmer: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = -1

    func body(content: Content) -> some View {
        if reduceMotion {
            content
        } else {
            content
                .overlay {
                    LinearGradient(
                        colors: [.clear, .white.opacity(0.10), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .scaleEffect(x: 1.6)
                    .offset(x: phase * 260)
                    .blendMode(.plusLighter)
                    .allowsHitTesting(false)
                }
                .clipped()
                .onAppear {
                    Motion.run(.linear(duration: 1.6).repeatForever(autoreverses: false)) {
                        phase = 1
                    }
                }
        }
    }
}

extension View {
    func shimmering() -> some View { modifier(Shimmer()) }
}

/// The row a screen shows before its covers arrive.
///
/// Skeletons in the real layout rather than a spinner, so nothing jumps when
/// content lands. Per cover, `CoverImage`'s BlurHash takes over the moment
/// the series is known; this is for before that, when there is no series yet.
/// Written once before, deleted as dead code on 2026-09-11, and back now
/// because this time something uses it.
struct CoverSkeletonRow: View {
    var count: Int = 3
    var width: CGFloat = Metrics.coverRowWidth

    var body: some View {
        HStack(alignment: .top, spacing: Metrics.gapCovers) {
            ForEach(0..<count, id: \.self) { index in
                VStack(alignment: .leading, spacing: 8) {
                    RoundedRectangle(cornerRadius: Metrics.radiusCoverRow, style: .continuous)
                        .fill(Palette.imagePlaceholder)
                        .frame(width: width, height: width / Metrics.coverAspect)
                    // Two bars, unequal: a column of identical ones reads as
                    // a rendering artefact rather than as text about to arrive.
                    Capsule().fill(Palette.surface)
                        .frame(width: width * (index.isMultiple(of: 2) ? 0.82 : 0.66), height: 9)
                    Capsule().fill(Palette.surface)
                        .frame(width: width * 0.45, height: 8)
                }
            }
        }
        .padding(.horizontal, Metrics.gutter)
        .shimmering()
        .accessibilityHidden(true)
    }
}

/// The grid Search shows while a request is out, in the results' own shape.
struct CoverSkeletonGrid: View {
    var count: Int = 6
    var width: CGFloat = 111

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: width), spacing: 16)], spacing: 16) {
            ForEach(0..<count, id: \.self) { index in
                VStack(alignment: .leading, spacing: 8) {
                    RoundedRectangle(cornerRadius: Metrics.radiusCoverGrid, style: .continuous)
                        .fill(Palette.imagePlaceholder)
                        .frame(width: width, height: width / Metrics.coverAspect)
                    Capsule().fill(Palette.surface)
                        .frame(width: width * (index.isMultiple(of: 2) ? 0.82 : 0.66), height: 9)
                }
            }
        }
        .shimmering()
        .accessibilityHidden(true)
    }
}
