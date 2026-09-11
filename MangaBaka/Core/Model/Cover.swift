import Foundation

/// Cover artwork, with everything needed to render it without layout shift.
///
/// The API supplies a BlurHash placeholder and the intrinsic pixel dimensions
/// specifically so a client can reserve the correct aspect ratio before the
/// image arrives. Using them is what keeps a scrolling feed from jumping.
struct Cover: Codable, Equatable, Sendable, Hashable {
    /// Original, unscaled image.
    let raw: URL?
    /// Pre-scaled variants at 1x device pixel ratio, by height in points.
    let x150: URL?
    let x250: URL?
    let x350: URL?
    /// BlurHash string for the placeholder shown while the image loads.
    let blurhash: String?
    let width: Double?
    let height: Double?

    // MARK: - Decoding two different shapes

    /// The same cover comes back two different ways depending on the endpoint,
    /// and the published spec describes only one of them.
    ///
    /// `/v2/series/*` returns each variant as a plain URL string. `/v1/my/*`
    /// returns each as an object — `raw` carrying `{url, width, height,
    /// blurhash, ...}` and each scaled variant carrying `{x1, x2, x3}`. Verified
    /// against both live endpoints on 2026-09-09.
    ///
    /// This was not a cosmetic difference. `Cover` only understood the v2
    /// shape, so every `/v1/my/library` response failed to decode, `library()`
    /// swallowed the error through a `try?` and returned nothing, and the swipe
    /// stack quietly fell back to a random queue for a reader with 937 series
    /// on the site. Nothing looked broken; the app had simply stopped using
    /// their taste.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // Depth is not part of the shape: a variant is either a string or an
        // object, and both forms appear for the same field.
        func variant(_ key: CodingKeys) throws -> (url: URL?, detail: RawDetail?) {
            if let string = try? container.decodeIfPresent(URL.self, forKey: key) {
                return (string, nil)
            }
            if let detail = try? container.decodeIfPresent(RawDetail.self, forKey: key) {
                return (detail.resolvedURL, detail)
            }
            return (nil, nil)
        }

        let rawVariant = try variant(.raw)
        raw = rawVariant.url
        x150 = try variant(.x150).url
        x250 = try variant(.x250).url
        x350 = try variant(.x350).url

        // The v2 shape carries these beside the variants; the v1 shape nests
        // them inside `raw`. Prefer whichever is actually present.
        blurhash = try container.decodeIfPresent(String.self, forKey: .blurhash)
            ?? rawVariant.detail?.blurhash
        width = try container.decodeIfPresent(Double.self, forKey: .width)
            ?? rawVariant.detail?.width
        height = try container.decodeIfPresent(Double.self, forKey: .height)
            ?? rawVariant.detail?.height
    }

    /// The object form of a variant. `url` is how `raw` spells it; `x1`/`x2`
    /// are how a scaled variant spells its device-pixel-ratio renderings.
    private struct RawDetail: Decodable {
        let url: URL?
        let x1: URL?
        let x2: URL?
        let x3: URL?
        let blurhash: String?
        let width: Double?
        let height: Double?

        /// Always the 1x rendering, so `url(forHeight:scale:)` can keep doing
        /// the @1 -> @2 substitution it does for the v2 shape. Picking x2 here
        /// would silently double every image request on a 3x screen.
        var resolvedURL: URL? { url ?? x1 }
    }

    /// Memberwise, because the custom `init(from:)` replaces the synthesised
    /// one and every test fixture builds a cover directly.
    init(
        raw: URL?, x150: URL?, x250: URL?, x350: URL?,
        blurhash: String?, width: Double?, height: Double?
    ) {
        self.raw = raw
        self.x150 = x150
        self.x250 = x250
        self.x350 = x350
        self.blurhash = blurhash
        self.width = width
        self.height = height
    }

    /// Intrinsic aspect ratio, for reserving space before the image loads.
    /// `nil` when the API did not supply usable dimensions.
    var aspectRatio: Double? {
        guard let width, let height, width > 0, height > 0 else { return nil }
        return width / height
    }

    /// The smallest rendering that covers the pixels actually drawn.
    ///
    /// The API documents that `@1` in the URL can be swapped for `@2` or `@3`
    /// to request a higher device-pixel-ratio rendering, so nine renderings
    /// exist: three heights by three ratios. This used to pick the height by
    /// points and then apply the screen's ratio regardless, which fetched
    /// 450 px for a 78 pt thumbnail drawing 234 px — 3.7x the pixels — and
    /// 350 px for a 400 pt hero on a 1x screen, which is blurry. Now the
    /// target is in pixels and the cheapest rendering that reaches it wins.
    func url(forHeight height: Double, scale: Double) -> URL? {
        let needed = height * max(scale, 1)
        var smallestSufficient: (url: URL, pixels: Double)?
        var largest: (url: URL, pixels: Double)?

        for (base, points) in [(x150, 150.0), (x250, 250.0), (x350, 350.0)] {
            guard let base else { continue }
            for ratio in 1...3 {
                let pixels = points * Double(ratio)
                let url = ratio == 1 ? base : Self.rendering(of: base, atRatio: ratio)
                if pixels >= needed, pixels < (smallestSufficient?.pixels ?? .infinity) {
                    smallestSufficient = (url, pixels)
                }
                if pixels > (largest?.pixels ?? 0) {
                    largest = (url, pixels)
                }
            }
        }
        return smallestSufficient?.url ?? largest?.url ?? raw
    }

    private static func rendering(of base: URL, atRatio ratio: Int) -> URL {
        let swapped = base.absoluteString.replacingOccurrences(of: "@1", with: "@\(ratio)")
        return URL(string: swapped) ?? base
    }
}

extension Cover {
    /// A cover with no artwork behind it.
    ///
    /// For a volume whose edition carries no image — which happens, and is not
    /// an error. `CoverImage` already draws its own placeholder for a nil URL,
    /// so the row keeps its shape instead of collapsing.
    static let empty = Cover(
        raw: nil, x150: nil, x250: nil, x350: nil,
        blurhash: nil, width: nil, height: nil
    )
}
