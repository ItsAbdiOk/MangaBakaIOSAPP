import SwiftUI

/// A series cover, at one fixed size.
///
/// The frame is always 2:3 so a row or grid of covers is uniform. The API's
/// pre-scaled variants are still used to pick the right download for that
/// size, and the reported intrinsic ratio still decides how artwork that is
/// not 2:3 gets cropped into it.
struct CoverImage: View {
    let cover: Cover
    let width: CGFloat
    var radius: CGFloat = Metrics.radiusCoverRow
    /// What VoiceOver reads. Cover art carries the title visually, so without
    /// this a reader using VoiceOver hears nothing at all.
    var accessibilityText: String = "Cover art"
    /// Called once after the real artwork (not the BlurHash) has finished
    /// loading, whether that came from cache or the network. Rows use this to
    /// chain their own arrival to the cover's rather than guessing at a delay.
    var onLoaded: (() -> Void)?

    @Environment(\.displayScale) private var displayScale

    private var height: CGFloat { width / Metrics.coverAspect }

    /// Decoded once per cover. Cheap (a 32x32 image) but not free, so it is not
    /// recomputed on every layout pass.
    private var blurPlaceholder: UIImage? {
        guard let hash = cover.blurhash else { return nil }
        return BlurHashCache.shared.image(for: hash)
    }

    @State private var loaded: UIImage?
    /// Whether the real image should be visible. Kept separate from `loaded`
    /// so the two can disagree on purpose: the image can already be decoded
    /// and waiting one runloop tick before `appearsSoftly(when:)` is allowed
    /// to animate it in — see `load()`.
    @State private var isReady = false

    private var url: URL? { cover.url(forHeight: height, scale: displayScale) }

    var body: some View {
        ZStack {
            background
            if let loaded {
                Image(uiImage: loaded)
                    .resizable()
                    .scaledToFill()
                    // Cover art is a photograph, not UI: Smart Invert must
                    // leave it alone. Nothing in the app opted out before, so
                    // a reader using it saw every cover as a negative.
                    .accessibilityIgnoresInvertColors()
                    // The gloss arrives with the artwork it belongs to, not
                    // the placeholder underneath — folded into the same
                    // `appearsSoftly` fade rather than its own, so the two
                    // can never drift out of sync.
                    .overlay { CoverGloss(radius: radius) }
                    .appearsSoftly(when: isReady)
            }
        }
        .modifier(CoverFrame(width: width, height: height, radius: radius))
        // The label the property has always documented, finally applied.
        // `accessibilityText` was declared, commented ("without this a
        // reader using VoiceOver hears nothing at all"), and passed in at
        // every call site — and never reached the view. Every bare
        // CoverImage, which is what the swipe stack, the detail hero and
        // the mix seed slots all draw, announced nothing. Found by
        // Periphery reporting the property as assigned and never read.
        //
        // A card that wraps this in its own accessibility element still
        // wins, so nothing is read twice.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(.isImage)
        // Keyed on the URL so a recycled row loads its new cover rather
        // than keeping the old one. `.task` also re-runs when the view
        // reappears, which is what makes a failed cover retry on scroll-back
        // instead of staying broken for the life of the screen.
        .task(id: url) {
            await load()
        }
    }

    @ViewBuilder
    private var background: some View {
        // The API ships a BlurHash with every cover, so the placeholder can
        // carry the artwork's real colours. A loading grid then looks like
        // the grid it is about to become rather than a wall of grey. No
        // gloss here — see the doc comment on `body`.
        if let blur = blurPlaceholder {
            Image(uiImage: blur)
                .resizable()
                .accessibilityIgnoresInvertColors()
        } else {
            Palette.imagePlaceholder
        }
    }

    /// Loads the cover and decides whether its arrival should cross-fade over
    /// the placeholder or simply appear.
    ///
    /// The state is reset before the fetch, not only after it. Keying the
    /// task decides when the load runs; it does not touch `loaded`, so a view
    /// that kept its identity across a cover change — the stack's card,
    /// handed a new series every swipe — drew the old artwork for a whole
    /// round trip and skipped the BlurHash placeholder that exists for
    /// exactly that gap.
    private func load() async {
        isReady = false
        let cached = CoverStore.shared.cached(url)
        loaded = cached
        guard cached == nil else {
            // Already in memory: appearing at once is correct here, not a
            // shortcut. A fade on a cache hit while scrolling reads as
            // flicker, not polish — see `shouldFade(loadDuration:)`.
            isReady = true
            onLoaded?()
            return
        }

        let start = Date()
        guard let image = await CoverStore.shared.image(for: url) else { return }
        loaded = image
        onLoaded?()

        guard Self.shouldFade(loadDuration: Date().timeIntervalSince(start)) else {
            isReady = true
            return
        }
        // Deferred a tick so the placeholder-only frame above this actually
        // commits before `isReady` flips — setting both in the same pass
        // would let the image arrive already fully visible, with nothing for
        // `appearsSoftly` to cross-fade from.
        Task { @MainActor in
            isReady = true
        }
    }

    /// The line between "arrived instantly" and "arrived, and should be seen
    /// arriving". `cacheHitThreshold` is A GUESS: one frame at 60Hz, about
    /// 16ms, is roughly the fastest a round trip through `CoverStore.image`
    /// can go without the caller ever perceiving a gap — and it is exactly
    /// what happens when `URLCache` answers the request instead of the
    /// network, without `CoverImage` needing to know that happened. Below the
    /// threshold, fading in would read as a flicker mid-scroll; at or above
    /// it, the placeholder was genuinely on screen first and the fade reads
    /// as the cover arriving rather than a glitch.
    nonisolated static let cacheHitThreshold: TimeInterval = 0.016

    /// Pure so it can be tested without a device or a network: the reader's
    /// eye is standing in for a fixed number, and the number is a guess.
    nonisolated static func shouldFade(loadDuration: TimeInterval) -> Bool {
        loadDuration >= cacheHitThreshold
    }
}

/// The frame every cover shares: size, corner and shadow. No gloss here — the
/// gloss belongs to the artwork, not the frame around it, so it lives on the
/// image layer in `CoverImage.body` and fades in with it instead of showing
/// over a placeholder that has not loaded yet.
private struct CoverFrame: ViewModifier {
    let width: CGFloat
    let height: CGFloat
    let radius: CGFloat

    func body(content: Content) -> some View {
        content
        // Every cover in a row is the same size, always.
        //
        // This used to frame each cover at the API's own reported ratio
        // (`cover.aspectRatio`), which is right for a single image and wrong
        // for a grid: MangaBaka's dimensions are per-scan, so a row of covers
        // came out visibly ragged — different heights, titles on different
        // baselines. The intrinsic ratio still decides how the artwork is
        // cropped (scaledToFill, below), it just no longer decides the frame.
        .frame(width: width, height: height)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .shadow(color: .black.opacity(0.5), radius: 10, y: 8)
    }
}

/// The sheen that makes a cover read as a pane of glass over the artwork.
///
/// Two gradients and a hairline, nothing that samples the pixels behind it:
/// no blur, no material, so it costs the same on sixty cards as on one and
/// needs no frame-time measurement (Abdi, 2026-09-11: "just shiny, glossy
/// like a glass pane", not the 3D effect). A diagonal highlight from the top
/// left that fades out before the middle, a faint lift along the top edge
/// where light would catch the pane, and a half-point edge so the pane has
/// a rim against the ground. The opacities are GUESSES, tuned by eye on the
/// 16 Pro simulator against the Discover rows.
struct CoverGloss: View {
    let radius: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        shape
            .fill(
                LinearGradient(
                    stops: [
                        .init(color: .white.opacity(0.42), location: 0),
                        .init(color: .white.opacity(0.10), location: 0.38),
                        .init(color: .clear, location: 0.6)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            // The rim light is a stroke of the shape itself, fading out down
            // the sides, so it bends round the corners. It was a straight
            // 2pt line inset by 0.6 × radius, which cut across the curve and
            // stuck out as a white bar on every cover (Abdi, 2026-09-13).
            .overlay {
                shape.strokeBorder(
                    LinearGradient(
                        stops: [
                            .init(color: .white.opacity(0.6), location: 0),
                            .init(color: .white.opacity(0.35), location: 0.12),
                            .init(color: .white.opacity(0.35), location: 1)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1
                )
            }
            .clipShape(shape)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// A cover with its title beneath, as used in every horizontal row and in
/// the three-across grids.
struct CoverCard: View {
    /// Where the card sits, which decides what bigger text does to it.
    enum Sizing {
        /// A horizontal row: the card widens 1.5× at accessibility sizes,
        /// because a row has the width to spare and a fixed card only
        /// wrapped the title further until it ran under the tab bar.
        case row
        /// A grid column: `width` is already the column's width, and the
        /// grid answered bigger text by dropping a column (`CoverGridLayout`).
        /// Widening here too is what put three 166pt cards in 357pt (R F4).
        case gridColumn
    }

    let series: Series
    var width: CGFloat = Metrics.coverRowWidth
    var radius: CGFloat = Metrics.radiusCoverRow
    var meta: String?
    var sizing: Sizing = .row
    /// Save / Mark read / Open on a hold, in the same menu as "Copy cover"
    /// — one long-press, one menu (R F3). Nil at every call site but Search
    /// today, and the menu then carries only the copy.
    var quickActions: CoverQuickActions.Actions?

    @Environment(\.dynamicTypeSize) private var typeSize

    /// At accessibility text sizes a two-line clamp truncates almost every
    /// title. Allowing more lines costs vertical space, which a horizontal row
    /// has to spare, and keeps titles readable rather than merely present.
    private var titleLineLimit: Int {
        typeSize.isAccessibilitySize ? 4 : 2
    }

    private var scaledWidth: CGFloat {
        Self.scaledWidth(width, sizing: sizing, isAccessibilitySize: typeSize.isAccessibilitySize)
    }

    /// Pure, so the widening rule has a test that asserts a number rather
    /// than grepping this file for the word `scaledWidth` — which is what
    /// `cardsWidenWithText` did while the grid overflowed.
    nonisolated static func scaledWidth(
        _ width: CGFloat, sizing: Sizing, isAccessibilitySize: Bool
    ) -> CGFloat {
        switch sizing {
        case .row: isAccessibilitySize ? width * 1.5 : width
        case .gridColumn: width
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CoverImage(
                cover: series.cover,
                width: scaledWidth,
                radius: radius,
                accessibilityText: series.displayTitle ?? "Untitled series"
            )
            // Hold any cover in a row or a grid and copy the artwork. On the
            // card rather than on `CoverImage` itself, because `CoverImage` is
            // also what the swipe stack draws its cards with, and a context
            // menu there competes with the drag for the same press.
            .copyableArtwork(
                series.cover.raw ?? series.cover.x350, noun: "cover", quickActions: quickActions
            )

            // A series can legitimately have no titles at all.
            Text(series.displayTitle ?? "Untitled series")
                .typeCardTitle()
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(titleLineLimit)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 7)

            if let meta {
                Text(meta)
                    .typeGridMeta()
                    .foregroundStyle(Palette.textMuted)
                    .lineLimit(1)
                    .padding(.top, 2)
            }
        }
        .frame(width: scaledWidth, alignment: .leading)
        // One element rather than three: VoiceOver should announce a card as a
        // single thing to tap, not read cover, title and meta separately. No
        // `.isButton` trait here: every call site wraps this in a `Button`,
        // which carries the trait itself (R minor).
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        let title = series.displayTitle ?? "Untitled series"
        guard let meta else { return title }
        return "\(title), \(meta)"
    }
}

/// The grid of covers Search, Mix and Publisher share: three across, two at
/// accessibility text sizes, each card as wide as its column.
///
/// Measures its own width once laid out and hands every cell the column
/// width it should draw at, so no screen writes a card width down — the
/// literal `111` lived in four files and was right for one phone (R F11).
/// Before the first measurement lands the reference phone's width stands
/// in, so the frame before layout is the old, nearly-right one rather than
/// a zero-width column.
struct CoverGrid<Item: Identifiable, Cell: View>: View {
    let items: [Item]
    /// Between rows. 16 is what the three grids used, unchanged.
    var rowSpacing: CGFloat = 16
    @ViewBuilder let cell: (_ index: Int, _ item: Item, _ layout: CoverGridLayout) -> Cell

    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var measuredWidth: CGFloat?

    private var layout: CoverGridLayout {
        CoverGridLayout.resolve(
            availableWidth: measuredWidth ?? (Metrics.referenceScreenWidth - 2 * Metrics.gutter),
            isAccessibilitySize: typeSize.isAccessibilitySize
        )
    }

    var body: some View {
        let resolved = layout
        LazyVGrid(
            columns: Array(
                repeating: GridItem(.flexible(), spacing: Metrics.gapCovers),
                count: resolved.columns
            ),
            alignment: .leading,
            spacing: rowSpacing
        ) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                cell(index, item, resolved)
            }
        }
        // Measured inside the gutter, so `availableWidth` is what the columns
        // actually divide.
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { measuredWidth = $0 }
        .padding(.horizontal, Metrics.gutter)
    }
}
