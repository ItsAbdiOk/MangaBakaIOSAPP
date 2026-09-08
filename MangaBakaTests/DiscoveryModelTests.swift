import Foundation
import Testing
@testable import MangaBaka

/// A repository stub, so these tests exercise the view model's state machine
/// rather than SQLite or HTTP. Cache behaviour is covered in
/// `SeriesRepositoryTests`.
/// Deliberately not lock-based: `NSLock` cannot be held across an `await`, and
/// these tests drive the stub from one task at a time, so a plain box is both
/// correct here and simpler to read.
private final class StubRepository: SeriesRepositoryProtocol, @unchecked Sendable {
    private var result: FeedResult
    private(set) var callCount = 0
    private(set) var lastForceRefresh: Bool?

    init(result: FeedResult) { self.result = result }

    func feed(_ feed: FeedKind, forceRefresh: Bool) async -> FeedResult {
        callCount += 1
        lastForceRefresh = forceRefresh
        return result
    }
}

@Suite("Discovery state transitions")
struct DiscoveryModelTests {
    private func series(_ ids: [Int]) -> [Series] {
        ids.map { id in
            Series(
                id: id, state: "active", mergedWith: nil,
                titles: [SeriesTitle(language: "en", traits: ["official"],
                                     title: "S\(id)", isPrimary: true)],
                cover: Cover(raw: nil, x150: nil, x250: nil, x350: nil,
                             blurhash: nil, width: 200, height: 300),
                description: nil, authors: nil, artists: nil,
                status: nil, rating: nil, type: nil, contentRating: nil
            )
        }
    }

    @Test("Starts idle")
    func startsIdle() async {
        let model = await DiscoveryModel(
            repository: StubRepository(result: FeedResult(series: [], origin: .network))
        )
        #expect(await model.state == .idle)
    }

    @Test("A successful load shows content with no staleness banner")
    func loadsContent() async {
        let stub = StubRepository(result: FeedResult(series: series([1, 2]), origin: .network))
        let model = await DiscoveryModel(repository: stub)
        await model.load()

        #expect(await model.state == .loaded(series([1, 2]), staleReason: nil))
    }

    /// The train case: the network failed but cached content exists, so the
    /// reader keeps their content and gets an explanation rather than an error.
    @Test("Stale content is shown with a reason, not an error page")
    func staleContentIsShown() async {
        let stub = StubRepository(
            result: FeedResult(series: series([1]), origin: .staleAfter(.offline))
        )
        let model = await DiscoveryModel(repository: stub)
        await model.load()

        guard case let .loaded(shown, staleReason) = await model.state else {
            Issue.record("Expected .loaded, got \(await model.state)")
            return
        }
        #expect(shown.map(\.id) == [1])
        #expect(staleReason == APIError.offline.userFacingMessage)
    }

    /// Only a failure with nothing to show should block the screen.
    @Test("A failure with nothing cached shows an error")
    func blockingFailure() async {
        let stub = StubRepository(
            result: FeedResult(series: [], origin: .staleAfter(.offline))
        )
        let model = await DiscoveryModel(repository: stub)
        await model.load()

        #expect(await model.state == .failed(message: APIError.offline.userFacingMessage))
    }

    @Test("An empty feed is loaded-but-empty, not an error")
    func emptyFeedIsNotAnError() async {
        let stub = StubRepository(result: FeedResult(series: [], origin: .network))
        let model = await DiscoveryModel(repository: stub)
        await model.load()

        #expect(await model.state == .loaded([], staleReason: nil))
    }

    @Test("Pull to refresh asks the repository to bypass its cache")
    func forceRefreshIsPassedThrough() async {
        let stub = StubRepository(result: FeedResult(series: series([1]), origin: .network))
        let model = await DiscoveryModel(repository: stub)

        await model.load()
        #expect(stub.lastForceRefresh == false)

        await model.load(forceRefresh: true)
        #expect(stub.lastForceRefresh == true)
    }
}
