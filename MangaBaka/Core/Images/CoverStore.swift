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
    ///
    /// **96 MB is about 28 covers, not 300.** This comment used to say 300, on
    /// the arithmetic that the store charges 320 KB per cover — "the encoded
    /// size, not the decoded one". It does not: `approximateBytes` below is
    /// `cgImage.bytesPerRow * height`, and its own comment says so, in this
    /// file, about this number (work-list 50). A 256×384 pt cover at @3x is
    /// 768×1152 px at four bytes a pixel ≈ 3.4 MB decoded, so 96 MB buys
    /// ~28 of them.
    ///
    /// The decoded cost is the one kept, because decoded bitmaps are what is
    /// actually resident: charging the encoded size would keep the limit's
    /// number and lose its meaning — 300 covers held decoded is ~1 GB, which
    /// is a jetsam, not a cache.
    ///
    /// So **96 MB is the guess**, not 300, and on this arithmetic it is
    /// smaller than one Discover grid plus the series page behind it — i.e.
    /// the store may be evicting covers the reader is still scrolling past,
    /// and `NSCache` eviction is silent, so `image(for:)` refetches them.
    /// NOT MEASURED. What settles it is an `NSCacheDelegate` eviction count
    /// over one 60-cover Discover fling (review P2): if that is above zero on
    /// a single screen, raise the limit. Raising it before that number exists
    /// would be trading the reader's memory for a guess.
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

        // `fetch` is nonisolated, so awaiting it hops off the main actor and
        // the work below happens on the cooperative pool. That hop is the whole
        // point — see `fetch`.
        let task = Task<UIImage?, Never> { [session] in
            await Signposts.measure("Cover fetch") {
                await Self.fetch(url, session: session)
            }
        }

        inFlight[url] = task
        let image = await task.value
        inFlight[url] = nil

        if let image {
            cache.setObject(image, forKey: url as NSURL, cost: image.approximateBytes)
        }
        return image
    }

    /// Warms the cache for covers that are about to scroll into view.
    ///
    /// A row only started fetching art once a cover was already on screen, so
    /// the first thing a reader saw when they scrolled was a placeholder. This
    /// asks for them early and throws the result away — the point is the cache
    /// entry, and a duplicate request is deduped by `image(for:)` anyway.
    /// How many speculative covers may be in flight at once.
    ///
    /// **A guess.** Six is "about one row of a Discover grid ahead", chosen so
    /// that prefetching cannot out-number the covers already on screen. What
    /// would settle it is the concurrent-request count during one fling, which
    /// needs a device.
    private static let prefetchWidth = 6

    func prefetch(_ urls: [URL?]) {
        // Work-list 51: this used to start one unstructured, default-priority
        // `Task` per URL. A grid handing it 40-60 URLs therefore started 40-60
        // concurrent `URLSession.data` calls, each of which then decodes and
        // `byPreparingForDisplay`s on the cooperative pool — competing with
        // the scroll that asked for them, which is the exact problem `fetch`'s
        // `nonisolated` was introduced to solve. Covers are not on the
        // rate-limited API, so this spends no request budget; it is the app's
        // largest byte consumer and it is speculative by definition, so it
        // runs bounded and at `.utility`, losing to what is already visible.
        let wanted = urls.compactMap { $0 }.filter {
            cache.object(forKey: $0 as NSURL) == nil && inFlight[$0] == nil
        }
        guard !wanted.isEmpty else { return }
        Task(priority: .utility) { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                var running = 0
                for url in wanted {
                    if running >= Self.prefetchWidth {
                        await group.next()
                        running -= 1
                    }
                    group.addTask(priority: .utility) { _ = await self?.image(for: url) }
                    running += 1
                }
            }
        }
    }

    /// Downloads and decodes, off the main actor.
    ///
    /// `nonisolated` is load-bearing and was a real bug: this type is
    /// `@MainActor`, so an unstructured `Task` created inside it inherited that
    /// isolation and `UIImage(data:)` ran on the main thread. Every cover that
    /// scrolled into view was decoded in competition with the scroll that
    /// revealed it.
    ///
    /// `byPreparingForDisplay` matters for the same reason at the other end:
    /// `UIImage(data:)` only holds the encoded bytes, and the bitmap is decoded
    /// lazily on the thread that first draws it — which is always the main one.
    /// Preparing it here moves that work off the main thread too. When it fails
    /// (it is documented as able to return nil) the undecoded image is still a
    /// correct answer, just a slower one.
    nonisolated private static func fetch(_ url: URL, session: URLSession) async -> UIImage? {
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
                // Counted before decoding: what crossed the wire is the
                // number that matters to someone on a metered connection.
                //
                // This line was written once already and silently did not
                // apply, which is why the first real measurement reported
                // "zero KB of cover art" on a screen visibly full of it. An
                // instrument that reads zero is worse than no instrument.
                await NetworkLedger.shared.recordImage(bytes: data.count)
                return await image.byPreparingForDisplay() ?? image
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
}

private extension UIImage {
    /// What this costs the cache. `cgImage` bytes rather than the encoded size,
    /// because a decoded image is what is actually being held.
    var approximateBytes: Int {
        guard let cgImage else { return 1 }
        return cgImage.bytesPerRow * cgImage.height
    }
}
