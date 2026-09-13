import Foundation
import Testing
@testable import MangaBaka

/// Open Library's cover gap-filler: a 200 is a URL, a 404 is a cached "no",
/// and both spacing and cancellation follow the same pattern already proven
/// on `AppleBooksClient`/`GoogleBooksClient`.
@Suite("Open Library covers", .serialized)
struct OpenLibraryCoversTests {
    private func makeClient(clock: TestClock = TestClock()) -> OpenLibraryCovers {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("openlibrary-tests-\(UUID().uuidString)", isDirectory: true)
        return OpenLibraryCovers(
            session: URLProtocolStub.makeSession(), clock: clock, cacheDirectory: directory
        )
    }

    @Test("A 200 answers with the cover URL, HEAD, default=false")
    func found() async throws {
        URLProtocolStub.setHandler { _ in .respond(.init(statusCode: 200)) }
        defer { URLProtocolStub.reset() }
        let client = makeClient()

        let url = await client.coverURL(isbn: "9781975319434")

        #expect(url?.absoluteString == "https://covers.openlibrary.org/b/isbn/9781975319434-L.jpg?default=false")
        let sent = try #require(URLProtocolStub.requests.first)
        #expect(sent.httpMethod == "HEAD")
    }

    /// TBATE vol. 2: measured live 2026-09-13, no cover uploaded for that
    /// ISBN. Nil, not a thrown error — this is the expected, common case for
    /// a gap-filler, not a failure to surface.
    @Test("A 404 answers nil, and is cached — a second call makes no request")
    func notFoundIsCachedAsNegative() async {
        URLProtocolStub.setHandler { _ in .respond(.init(statusCode: 404)) }
        defer { URLProtocolStub.reset() }
        let client = makeClient()

        let first = await client.coverURL(isbn: "9781975345648")
        #expect(first == nil)
        #expect(URLProtocolStub.requests.count == 1)

        // Second look: even if the stub were now told to answer 200, the
        // cached negative must win — that is the whole point of caching a
        // 404 at all, not just a "no request happened".
        // `setHandler` starts a fresh request log, so "no request" is zero.
        URLProtocolStub.setHandler { _ in .respond(.init(statusCode: 200)) }
        let second = await client.coverURL(isbn: "9781975345648")
        #expect(second == nil)
        #expect(URLProtocolStub.requests.isEmpty, "the negative answer was served from cache")
    }

    @Test("A stale cache entry beyond its cache life is asked again")
    func cacheExpires() async {
        URLProtocolStub.setHandler { _ in .respond(.init(statusCode: 404)) }
        defer { URLProtocolStub.reset() }
        let clock = TestClock()
        let client = makeClient(clock: clock)

        _ = await client.coverURL(isbn: "9781975345648")
        #expect(URLProtocolStub.requests.count == 1)

        clock.advance(by: OpenLibraryCovers.cacheLife + 1)
        // A fresh log from here: the one request below is the re-ask.
        URLProtocolStub.setHandler { _ in .respond(.init(statusCode: 200)) }
        let after = await client.coverURL(isbn: "9781975345648")
        #expect(after != nil)
        #expect(URLProtocolStub.requests.count == 1)
    }

    /// Same shape as `AppleBooksClient`'s spacing/cancellation pair
    /// (gap 28): the slot is claimed before the wait, so two concurrent
    /// callers are spaced by real elapsed time even though `TestClock`
    /// never advances on its own.
    @Test("Two concurrent lookups are spaced by the minimum interval")
    func concurrentLookupsAreSpaced() async throws {
        let arrivals = ArrivalLog()
        URLProtocolStub.setHandler { _ in
            arrivals.record()
            return .respond(.init(statusCode: 200))
        }
        defer { URLProtocolStub.reset() }
        let client = makeClient()

        // A warm-up so the slot is already taken: a cold first caller never
        // waits, and so never exercises the spacing at all.
        _ = await client.coverURL(isbn: "0000000000")
        async let first = client.coverURL(isbn: "1111111111")
        async let second = client.coverURL(isbn: "2222222222")
        _ = await (first, second)

        let gap = try #require(arrivals.lastGap)
        #expect(
            gap >= .seconds(OpenLibraryCovers.minimumInterval - 0.5),
            "requests reached the network \(gap) apart"
        )
    }

    /// Gap-28-shaped: `try? await Task.sleep` alone would swallow
    /// cancellation and fire the request anyway, for an ISBN the shelf no
    /// longer needs. Expected failure before the guard:
    /// `URLProtocolStub.requests.count == 2`, because the cancelled task's
    /// wait still spent the slot it claimed.
    @Test("A cancelled wait for a request slot does not fire the request")
    func cancelledWaitDoesNotFireTheRequest() async {
        URLProtocolStub.setHandler { _ in .respond(.init(statusCode: 200)) }
        defer { URLProtocolStub.reset() }
        let client = makeClient()

        let warm = Task { await client.coverURL(isbn: "0000000000") }
        _ = await warm.value

        let task = Task { await client.coverURL(isbn: "3333333333") }
        task.cancel()
        _ = await task.value

        #expect(URLProtocolStub.requests.count == 1, "only the warm-up request should have been sent")
    }
}

/// Arrival times of the stubbed requests. Copied from
/// `MangaUpdatesSpacingTests`'s `ArrivalLog` rather than shared, since that
/// one is `private` to its file and this suite lives elsewhere.
private final class ArrivalLog: @unchecked Sendable {
    private let lock = NSLock()
    private var times: [ContinuousClock.Instant] = []

    func record() {
        lock.lock(); defer { lock.unlock() }
        times.append(.now)
    }

    var lastGap: Duration? {
        lock.lock(); defer { lock.unlock() }
        guard times.count >= 2 else { return nil }
        return times[times.count - 2].duration(to: times[times.count - 1])
    }
}
