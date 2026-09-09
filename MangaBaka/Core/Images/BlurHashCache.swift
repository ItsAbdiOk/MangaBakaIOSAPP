import UIKit

/// Decoded BlurHash placeholders, kept in memory.
///
/// Decoding is cheap but not free, and the same cover reappears constantly —
/// across rows, on the detail screen, in search results. Without a cache the
/// same hash is decoded on every layout pass of every scroll frame.
///
/// `NSCache` rather than a dictionary so the system can evict under pressure:
/// these are placeholders, and losing one costs a re-decode, not correctness.
final class BlurHashCache: @unchecked Sendable {
    static let shared = BlurHashCache()

    private let cache = NSCache<NSString, UIImage>()

    private init() {
        // Roughly a few hundred 32x32 placeholders. Generous for a feed, small
        // enough to be invisible in the app's footprint.
        cache.countLimit = 400
    }

    func image(for hash: String) -> UIImage? {
        let key = hash as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let decoded = BlurHash.image(from: hash) else { return nil }
        cache.setObject(decoded, forKey: key)
        return decoded
    }
}
