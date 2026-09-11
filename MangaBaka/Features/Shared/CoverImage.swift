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

    @Environment(\.displayScale) private var displayScale

    private var height: CGFloat { width / Metrics.coverAspect }

    /// Decoded once per cover. Cheap (a 32x32 image) but not free, so it is not
    /// recomputed on every layout pass.
    private var blurPlaceholder: UIImage? {
        guard let hash = cover.blurhash else { return nil }
        return BlurHashCache.shared.image(for: hash)
    }

    @State private var loaded: UIImage?

    private var url: URL? { cover.url(forHeight: height, scale: displayScale) }

    var body: some View {
        content
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
            //
            // The state is reset before the fetch, not only after it. Keying
            // the task decides when the load runs; it does not touch `loaded`,
            // so a view that kept its identity across a cover change — the
            // stack's card, handed a new series every swipe — drew the old
            // artwork for a whole round trip and skipped the BlurHash
            // placeholder that exists for exactly that gap.
            .task(id: url) {
                loaded = CoverStore.shared.cached(url)
                guard loaded == nil else { return }
                loaded = await CoverStore.shared.image(for: url)
            }
    }

    @ViewBuilder
    private var content: some View {
        if let loaded {
            Image(uiImage: loaded)
                .resizable()
                .scaledToFill()
                .modifier(CoverFrame(width: width, height: height, radius: radius))
        } else if let blur = blurPlaceholder {
            // The API ships a BlurHash with every cover, so the placeholder can
            // carry the artwork's real colours. A loading grid then looks like
            // the grid it is about to become rather than a wall of grey.
            Image(uiImage: blur)
                .resizable()
                .modifier(CoverFrame(width: width, height: height, radius: radius))
        } else {
            Palette.imagePlaceholder
                .modifier(CoverFrame(width: width, height: height, radius: radius))
        }
    }
}

/// The frame every cover shares.
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

/// A cover with its title beneath, as used in every horizontal row.
struct CoverCard: View {
    let series: Series
    var width: CGFloat = Metrics.coverRowWidth
    var radius: CGFloat = Metrics.radiusCoverRow
    var meta: String?

    @Environment(\.dynamicTypeSize) private var typeSize

    /// At accessibility text sizes a two-line clamp truncates almost every
    /// title. Allowing more lines costs vertical space, which a horizontal row
    /// has to spare, and keeps titles readable rather than merely present.
    private var titleLineLimit: Int {
        typeSize.isAccessibilitySize ? 4 : 2
    }

    /// Cards widen with the text. Keeping them fixed meant larger type simply
    /// wrapped more inside the same narrow column until the title ran past the
    /// card and disappeared under the floating tab bar.
    private var scaledWidth: CGFloat {
        typeSize.isAccessibilitySize ? width * 1.5 : width
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
            .copyableArtwork(series.cover.raw ?? series.cover.x350, noun: "cover")

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
        // single thing to tap, not read cover, title and meta separately.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(.isButton)
    }

    private var accessibilityLabel: String {
        let title = series.displayTitle ?? "Untitled series"
        guard let meta else { return title }
        return "\(title), \(meta)"
    }
}
