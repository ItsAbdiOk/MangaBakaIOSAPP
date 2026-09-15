import Testing
import Foundation
@testable import MangaBaka

/// `CommunityPulseService.load()` had no in-flight guard: two Discover
/// appearances inside one round trip fired two
/// `/v0/frontpage/community-pulse` requests — wire review W16/P16,
/// 2026-09-15.
@Suite("CommunityPulseService load in-flight guard after W16", .serialized)
@MainActor
struct CommunityPulseServiceWireFixTests {
    private let baseURL = URL(string: "https://api.example.invalid").unsafeTestURL

    nonisolated private static let pulseBody = Data("""
    {"active_series_count": 1, "active_series_count_prev_week": 1,
     "registered_user_count": 1, "registered_user_count_prev_week": 1,
     "chapters_read_count": 1, "chapters_read_count_prev_week": 1}
    """.utf8)

    private func makeService() -> CommunityPulseService {
        CommunityPulseService(
            client: APIClient(
                baseURL: baseURL,
                session: URLProtocolStub.makeSession(),
                tokenProvider: UnauthenticatedTokenProvider()
            ),
            clock: TestClock()
        )
    }

    /// Fails on the pre-fix code with 2 requests: nothing stopped a second
    /// `load()` from firing its own fetch while the first was still out.
    /// The two calls are made from `@MainActor` code with no `await`
    /// between them, so — MainActor being a single serial executor — the
    /// first call is guaranteed to run synchronously up to its own
    /// suspension point (`await task.value` post-fix, `await
    /// client.getRoot(...)` pre-fix) before the second gets a turn; no
    /// artificial delay is needed to force the ordering this test depends
    /// on.
    @Test("Two concurrent load() calls make only one request")
    func concurrentLoadsShareOneRequest() async {
        URLProtocolStub.setHandler { _ in .respond(.init(body: Self.pulseBody)) }
        defer { URLProtocolStub.reset() }

        let service = makeService()
        async let first: Void = service.load()
        async let second: Void = service.load()
        _ = await (first, second)

        #expect(URLProtocolStub.requests.count == 1)
        #expect(service.pulse != nil)
    }

    /// The control: once `pulse` is already set, a later `load()` is a
    /// no-op regardless of the in-flight guard — unaffected by this fix.
    @Test("A load() after success does not re-request")
    func loadAfterSuccessDoesNotRefetch() async {
        URLProtocolStub.setHandler { _ in .respond(.init(body: Self.pulseBody)) }
        defer { URLProtocolStub.reset() }

        let service = makeService()
        await service.load()
        await service.load()
        #expect(URLProtocolStub.requests.count == 1)
    }
}
