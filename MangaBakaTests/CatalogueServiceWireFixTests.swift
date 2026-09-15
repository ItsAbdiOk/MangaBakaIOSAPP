import Testing
import Foundation
@testable import MangaBaka

/// `CatalogueService.tags(limit:)`: a smaller ask completing while a bigger
/// one is still in flight used to wipe the bigger ask's registration, so a
/// third caller found nothing to join and started a duplicate `/v1/tags`
/// request — wire review W15/P15, 2026-09-15.
@Suite("CatalogueService tag-fetch join after W15", .serialized)
struct CatalogueServiceWireFixTests {
    private let baseURL = URL(string: "https://api.example.invalid").unsafeTestURL

    private func makeService() -> CatalogueService {
        CatalogueService(client: APIClient(
            baseURL: baseURL,
            session: URLProtocolStub.makeSession(),
            tokenProvider: UnauthenticatedTokenProvider()
        ))
    }

    nonisolated private static let tagBody = Data(#"{"status":200,"data":[{"id":1,"name":"Action"}]}"#.utf8)

    /// Fails on the pre-fix code with 3 requests instead of 2: caller A's
    /// (limit 200) completion called `tagsInFlight = nil` unconditionally,
    /// which erased caller B's (limit 500) own registration while B's
    /// request was still out — the exact window a third 500-caller can land
    /// in. A `DispatchSemaphore` holds the 500 response open rather than a
    /// fixed sleep, so the ordering this test needs (200 lands, *then* a
    /// third caller arrives, *then* 500 lands) is deterministic rather than
    /// a race against real timing.
    @Test("A bigger fetch's registration survives a smaller one completing first")
    func biggerFetchSurvivesSmallerCompletingFirst() async {
        let releaseBig = DispatchSemaphore(value: 0)
        URLProtocolStub.setHandler { request in
            if request.url?.absoluteString.contains("limit=500") == true {
                // Held open until this test has confirmed the 200 leg
                // landed and started a third caller — see below.
                _ = releaseBig.wait(timeout: .now() + .seconds(2))
            }
            return .respond(.init(body: Self.tagBody))
        }
        defer { URLProtocolStub.reset() }

        let service = makeService()
        async let small = service.tags(limit: 200)
        async let big = service.tags(limit: 500)

        // The 200 leg's handler is never gated, so this completes without
        // waiting on `releaseBig` — while `big` is still blocked inside its
        // own handler on a different request thread.
        _ = await small

        // A third caller, while `big` is still out. Post-fix this joins
        // `big`'s in-flight task; pre-fix, `small`'s completion already
        // cleared the registration `big` set, so this starts a third
        // request.
        async let third = service.tags(limit: 500)

        releaseBig.signal()
        _ = await big
        _ = await third

        #expect(URLProtocolStub.requests.count == 2)
    }

    /// The control: with no overlap at all (each ask completes before the
    /// next starts), every distinct limit is still its own request — this
    /// test is not accidentally passing by joining everything into one.
    @Test("Sequential asks at different limits are not wrongly joined")
    func sequentialAsksAreNotJoined() async {
        URLProtocolStub.setHandler { _ in .respond(.init(body: Self.tagBody)) }
        defer { URLProtocolStub.reset() }

        let service = makeService()
        _ = await service.tags(limit: 200)
        _ = await service.tags(limit: 500)
        #expect(URLProtocolStub.requests.count == 2)
    }
}
