import SwiftUI

/// A series cover, sized and loaded the way the API intends.
///
/// The API supplies pre-scaled variants and the cover's intrinsic dimensions
/// specifically so a client can reserve the right aspect ratio before the
/// image arrives. Using them is what stops a scrolling feed jumping.
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

    var body: some View {
        // The API's own ratio when it gave one, else 2:3, which every cover is.
        let ratio = cover.aspectRatio ?? Metrics.coverAspect

        AsyncImage(url: cover.url(forHeight: height, scale: displayScale)) { phase in
            switch phase {
            case let .success(image):
                image.resizable().scaledToFill()
            case .failure:
                // A broken image must not break the layout: keep the frame.
                Palette.imagePlaceholder
                    .overlay(
                        Image(systemName: "photo")
                            .foregroundStyle(Palette.textQuaternary)
                    )
            default:
                // The API ships a BlurHash with every cover, so the placeholder
                // can carry the artwork's real colours. A loading grid then
                // looks like the grid it is about to become, rather than a wall
                // of grey.
                if let blur = blurPlaceholder {
                    Image(uiImage: blur).resizable()
                } else {
                    Palette.imagePlaceholder
                }
            }
        }
        .frame(width: width, height: width / ratio)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .shadow(color: .black.opacity(0.5), radius: 10, y: 8)
        .accessibilityLabel(accessibilityText)
    }
}

/// A cover with its title beneath, as used in every horizontal row.
struct CoverCard: View {
    let series: Series
    var width: CGFloat = Metrics.coverRowWidth
    var radius: CGFloat = Metrics.radiusCoverRow
    var meta: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CoverImage(
                cover: series.cover,
                width: width,
                radius: radius,
                accessibilityText: series.displayTitle ?? "Untitled series"
            )

            // A series can legitimately have no titles at all.
            Text(series.displayTitle ?? "Untitled series")
                .typeCardTitle()
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 7)

            if let meta {
                Text(meta)
                    .typeGridMeta()
                    .foregroundStyle(Palette.textTertiary)
                    .lineLimit(1)
                    .padding(.top, 2)
            }
        }
        .frame(width: width, alignment: .leading)
    }
}
