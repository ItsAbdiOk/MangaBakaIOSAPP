import SwiftUI
import UIKit

/// Loads cover art, once per URL, and remembers what it got.
///
/// Replaces `AsyncImage`, which has two behaviours that show up as the same
/// user-visible bug: it cancels an in-flight load when its view scrolls out of
/// a lazy stack, and it keeps the resulting `.failure` phase for that view's
/// identity — so a cover that lost its race stays a broken-image icon, and
/// going back to the screen does not fix it because the failure is what was
/// remembered. The CDN was ruled out first: twenty concurrent requests for the
/// same asset all returned 200.
///
/// Three things this does that `AsyncImage` does not:
///
/// - **Dedupes.** The same cover in a row and in a grid is one request.
/// - **Caches successes in memory**, so returning to a screen is instant and
///   scrolling back does not re-decode.
/// - **Retries a failure once**, and never caches one. A cover that failed
///   because the app was backgrounded mid-request gets another go the next time
///   it is on screen, which is the behaviour a reader expects from "scroll away
///   and come back".
@MainActor
@Observable
final class CoverStore {
    static let shared = CoverStore()

    /// Bytes, not entries: cover art varies enormously in size and a count
    /// limit would hold either far too much or far too little.
    private let cache: NSCache<NSURL, UIImage> = {
        let cache = NSCache<NSURL, UIImage>()
        cache.totalCostLimit = 96 * 1024 * 1024
        return cache
    }()

    private var inFlight: [URL: Task<UIImage?, Never>] = [:]
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// A cover already in memory, for a synchronous first render with no flash.
    func cached(_ url: URL?) -> UIImage? {
        guard let url else { return nil }
        return cache.object(forKey: url as NSURL)
    }

    /// Loads a cover, or returns the one already loaded.
    ///
    /// Deliberately not cancelled when the caller goes away: the request is
    /// nearly always about to be needed again, and cancelling it is what left
    /// covers permanently blank in a scrolling list.
    func image(for url: URL?) async -> UIImage? {
        guard let url else { return nil }
        if let cached = cache.object(forKey: url as NSURL) { return cached }
        if let existing = inFlight[url] { return await existing.value }

        let task = Task<UIImage?, Never> { [session] in
            for attempt in 0..<2 {
                do {
                    let (data, response) = try await session.data(from: url)
                    guard let http = response as? HTTPURLResponse,
                          (200..<300).contains(http.statusCode),
                          let image = UIImage(data: data)
                    else {
                        // A 404 is settled; retrying it wastes a request. Any
                        // other status might not be.
                        if (response as? HTTPURLResponse)?.statusCode == 404 { return nil }
                        continue
                    }
                    return image
                } catch {
                    if Task.isCancelled { return nil }
                    // One short pause before the second try: the common failure
                    // is a connection dropped mid-scroll, and an immediate
                    // retry tends to hit the same condition.
                    if attempt == 0 { try? await Task.sleep(for: .milliseconds(400)) }
                }
            }
            return nil
        }

        inFlight[url] = task
        let image = await task.value
        inFlight[url] = nil

        if let image {
            cache.setObject(image, forKey: url as NSURL, cost: image.approximateBytes)
        }
        return image
    }
}

private extension UIImage {
    /// What this costs the cache. `cgImage` bytes rather than the encoded size,
    /// because a decoded image is what is actually being held.
    var approximateBytes: Int {
        guard let cgImage else { return 1 }
        return cgImage.bytesPerRow * cgImage.height
    }
}
