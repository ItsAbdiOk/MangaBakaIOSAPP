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

    /// Intrinsic aspect ratio, for reserving space before the image loads.
    /// `nil` when the API did not supply usable dimensions.
    var aspectRatio: Double? {
        guard let width, let height, width > 0, height > 0 else { return nil }
        return width / height
    }

    /// Best variant for a target height in points, accounting for screen scale.
    ///
    /// The API documents that `@1` in the URL can be swapped for `@2` or `@3`
    /// to request a higher device-pixel-ratio rendering.
    func url(forHeight height: Double, scale: Double) -> URL? {
        let base: URL? = switch height {
        case ..<175: x150
        case ..<300: x250
        default: x350
        }
        guard let base else { return raw }
        guard scale > 1 else { return base }

        let requested = min(Int(scale.rounded()), 3)
        let swapped = base.absoluteString.replacingOccurrences(of: "@1", with: "@\(requested)")
        return URL(string: swapped) ?? base
    }
}
