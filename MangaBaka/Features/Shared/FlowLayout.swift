import SwiftUI

/// Lays subviews out in a row, wrapping onto the next line when they run out of
/// width.
///
/// Needed because an `HStack` of chips that refuse to compress makes its parent
/// wider than the screen, which silently drags every sibling out of alignment —
/// on the detail screen that clipped the first and last letter off every line
/// of the description.
struct FlowLayout: Layout {
    var spacing: CGFloat = Metrics.gapChips
    var lineSpacing: CGFloat = Metrics.gapChips

    /// The measured size of every subview, taken once per layout pass.
    ///
    /// `cache: inout ()` before: `sizeThatFits` and `placeSubviews` each
    /// called `arrange`, which asked every subview for its size, and
    /// `placeSubviews` then asked each one *again* while placing it — four
    /// measurements per chip per pass, where `Layout` gives you a cache for
    /// exactly this. A chip's `sizeThatFits` is a text measurement, so this is
    /// the tag groups on the series page and the filter strips re-measuring
    /// their labels whenever anything above them changes height.
    struct Cache {
        var sizes: [CGSize]
    }

    func makeCache(subviews: Subviews) -> Cache {
        Cache(sizes: Self.measure(subviews))
    }

    func updateCache(_ cache: inout Cache, subviews: Subviews) {
        cache.sizes = Self.measure(subviews)
    }

    private static func measure(_ subviews: Subviews) -> [CGSize] {
        subviews.map { $0.sizeThatFits(.unspecified) }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let rows = Self.arrange(
            sizes: cache.sizes, maxWidth: maxWidth, spacing: spacing
        )
        let height = rows.reduce(CGFloat.zero) { $0 + $1.height } +
            lineSpacing * CGFloat(max(rows.count - 1, 0))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: min(width, maxWidth), height: height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Cache
    ) {
        let rows = Self.arrange(
            sizes: cache.sizes, maxWidth: bounds.width, spacing: spacing
        )
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for index in row.indices {
                // A single item wider than the container used to hang off the
                // edge. At large text sizes that is ordinary, not exotic — one
                // long publisher name is enough — so it is capped and left to
                // truncate inside its own bounds. Capped here against the same
                // measured size `arrange` wrapped on, rather than a fresh
                // `sizeThatFits` that could disagree with it.
                var size = cache.sizes[index]
                size.width = min(size.width, bounds.width)
                subviews[index].place(
                    at: CGPoint(x: x, y: y),
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    /// One line of the flow. Internal so `FlowLayoutTests` can assert which
    /// chip landed on which line rather than rendering anything.
    struct Row: Equatable {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    /// The wrapping rule, over measured sizes rather than over live subviews,
    /// so it is pure and testable.
    nonisolated static func arrange(
        sizes: [CGSize], maxWidth: CGFloat, spacing: CGFloat
    ) -> [Row] {
        var rows: [Row] = []
        var current = Row()

        for index in sizes.indices {
            var size = sizes[index]
            size.width = min(size.width, maxWidth)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > maxWidth, !current.indices.isEmpty {
                rows.append(current)
                current = Row()
                current.indices = [index]
                current.width = size.width
                current.height = size.height
            } else {
                current.indices.append(index)
                current.width = needed
                current.height = max(current.height, size.height)
            }
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
