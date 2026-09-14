import SwiftUI

/// How far the series page has scrolled, held in a reference type rather than
/// in `SeriesDetailView`'s own `@State`.
///
/// The offset used to be `@State` on the page root, written on every scroll
/// frame. Its only readers are the backdrop's 6pt parallax and the navigation
/// bar's title crossfade — but `@State` on the root invalidates the whole
/// body, so every frame re-ran a Markdown parse of the synopsis,
/// `TagGrouping.groups` over up to 146 tags, two cover sorts, a
/// `VolumeShelf.merge` and ~11 `Series.filling` copies, inside an 8.3 ms
/// budget at 120 Hz (item 54). An `@Observable` class read only by the two
/// views that actually need it means a write here invalidates those two and
/// nothing else: `SeriesDetailView`'s own body never reads a property on it.
///
/// It carries the crossfade too, which `DetailBarTitle` used to derive from a
/// second `onScrollGeometryChange` of its own — one observer on the
/// ScrollView, not two reporting the same number.
@Observable
@MainActor
final class ScrollTracker {
    /// Points travelled from the top, including the content inset.
    var offset: CGFloat = 0
    /// 0 while the hero's own title is fully on screen, 1 once it has
    /// travelled out — see `DetailBarTitle.crossfadeProgress`.
    var crossfade: CGFloat = 0

    /// `CoverGallery` reuses this class for its own single per-frame scroll
    /// write rather than declaring a second `@Observable` type for one
    /// property (item 64) — but its horizontal page fraction (0…`pages.count
    /// - 1`) is a different quantity than `offset`'s vertical points
    /// travelled, so it gets its own name instead of reading wrong on that
    /// screen. `SeriesDetailView`'s tracker never touches this property, and
    /// `CoverGallery`'s never touches `offset` or `crossfade`.
    var pageProgress: Double = 0

    init(pageProgress: Double = 0) {
        self.pageProgress = pageProgress
    }

    /// A named method rather than a closure body: Xcode Cloud's Swift 6.3.3
    /// crashed in the SIL verifier ("OwnershipModelEliminator") on the inline
    /// version of this under whole-module optimisation — build 69,
    /// 2026-09-13 — while the local toolchain compiled it. Same behaviour.
    func update(travelled: CGFloat) {
        offset = travelled
        let progress = DetailBarTitle.crossfadeProgress(travelled: travelled)
        guard progress != crossfade else { return }
        // Item 65 / screens F24 (2026-09-14): this used to wrap the
        // assignment in `withAnimation(Motion.reduced(Motion.glide))`, so a
        // continuous 0…1 value picked up a new animation towards a
        // one-frame-old target on every scroll sample — a transaction paid
        // per frame for a trail the eye never saw. `crossfade` is a plain
        // value now; `DetailBarTitle.showsBarTitle` is the one discontinuity
        // in this handover and is what should animate, if anything does.
        crossfade = progress
    }
}
