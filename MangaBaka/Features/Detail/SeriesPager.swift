import SwiftUI

/// Swipe sideways between series, from wherever a row pushed one.
///
/// A series page reached from a row — a rising shelf, a related-series strip,
/// the library's own list — remembers what else was in that row. This lets a
/// horizontal swipe from the page step to the next or previous series in the
/// same row, the way a photo viewer steps between photos from an album,
/// instead of forcing a pop-then-tap for every neighbour.
///
/// `items.count <= 1` is not a case this type handles itself — see
/// `RootView+Session.detail(_:path:neighbours:)`, which only wraps a page in
/// `SeriesPager` at all once there is more than one neighbour, so every
/// existing call site (`neighbours` defaulting to `[]`) keeps rendering a
/// plain `SeriesDetailView` with zero behaviour change.
struct SeriesPager<Content: View>: View {
    let items: [Series]
    /// Called once per page that settles on a different series. Not called
    /// for the page the pager opened on: that one the caller already knows
    /// about, having pushed it.
    ///
    /// This replaces a `@Binding var selected: Series` whose one call site
    /// passed `.constant(series)` — so `selected = match` wrote into a
    /// constant and every settle was silently dropped, and `recentlyViewed`
    /// only ever recorded the series that was pushed, never one swiped to.
    /// Nothing broke, which is the problem: the binding invited the next
    /// caller to rely on a write that goes nowhere (item 123).
    let onSettle: ((Series) -> Void)?
    let content: (Series) -> Content

    /// Seeded in `init`, not in `onAppear`. Assigning it after the first
    /// layout meant `items[0]`'s `SeriesDetailView.task` fired its
    /// eight-request `loadCore` (nine on a long series — the number lives in
    /// four places, corrected here 2026-09-15; see the perf review's detail
    /// report) at `userInitiated` for a series the reader never opened, and
    /// the jump to the real one animated through every page between — worst
    /// case a 60-item publisher row opened at its 40th card (item 56).
    @State private var position: Series.ID?

    /// - Parameter selected: the series the push named. Where the pager
    ///   opens, and nothing more — it is not stored, because nothing after the
    ///   first layout needs it.
    init(
        items: [Series],
        selected: Series,
        onSettle: ((Series) -> Void)? = nil,
        @ViewBuilder content: @escaping (Series) -> Content
    ) {
        self.items = items
        self.onSettle = onSettle
        self.content = content
        _position = State(initialValue: selected.id)
    }
    /// Bumped once per page that actually settles on a new series, so
    /// `.haptic(_:onEach:)` fires once per swipe rather than once per frame
    /// of the scroll settling into place.
    @State private var settledCount = 0
    /// True while the drag now in progress started close enough to the
    /// leading edge that the system's own back gesture should win it —
    /// see `allowsPaging(dragStartX:width:)`. Disabling the ScrollView is
    /// what actually lets that gesture through underneath; re-enabled the
    /// moment the touch lifts.
    ///
    /// Flagged for the main session: a native `UIScrollView` pan is not a
    /// SwiftUI `DragGesture`, so this approximates rejecting the leading
    /// 20pt rather than truly ensuring the ScrollView's own recognizer never
    /// sees a touch that starts there. Needs a device or simulator check
    /// against both `EdgeSwipeToDismiss` (sheets, not pushed pages, so no
    /// direct conflict expected) and the system's own interactive-pop edge
    /// swipe (which this page, being pushed, does have).
    @State private var isPagingDisabled = false

    var body: some View {
        GeometryReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(items) { series in
                        content(series)
                            .frame(width: proxy.size.width)
                            .id(series.id)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollDisabled(isPagingDisabled)
            .scrollPosition(id: $position)
            .scrollIndicators(.hidden)
            .simultaneousGesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { value in
                        guard value.translation == .zero else { return }
                        isPagingDisabled = !Self.allowsPaging(
                            dragStartX: value.startLocation.x, width: proxy.size.width
                        )
                    }
                    .onEnded { _ in isPagingDisabled = false }
            )
        }
        // No `onAppear` seed: `init` does it, before the first page's own
        // `.task` can run (item 56). The animation below is kept for the
        // swipes that follow.
        .onChange(of: position) { oldValue, newValue in
            guard let newValue, oldValue != newValue,
                  let match = items.first(where: { $0.id == newValue }) else { return }
            onSettle?(match)
            settledCount += 1
        }
        .haptic(Haptics.selection, onEach: settledCount)
        .animation(Motion.reduced(Motion.settle), value: position)
    }

    /// Whether a drag beginning at `dragStartX`, on a page `width` points
    /// wide, belongs to the pager rather than to the system's own edge-back
    /// gesture. The leading 20pt matches `EdgeSwipeToDismiss`'s own margin —
    /// same reasoning there: a reader swiping in from the edge means "go
    /// back", not "next series", and the two cannot both claim that region.
    ///
    /// `width` is unused today — there is no trailing-edge gesture to protect
    /// the same way on this side — but kept in the signature since a
    /// right-to-left layout (where "back" is the trailing edge, the same
    /// mirroring `EdgeSwipeToDismiss.isFromLeadingEdge` already does) would
    /// need it, and changing this signature later would ripple through every
    /// call site.
    nonisolated static func allowsPaging(dragStartX: CGFloat, width: CGFloat) -> Bool {
        dragStartX >= 20
    }
}
