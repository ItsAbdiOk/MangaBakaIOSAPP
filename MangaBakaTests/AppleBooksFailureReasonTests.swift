import Testing
import Foundation
@testable import MangaBaka

/// Item 60: `AppleBooksClient.volumes` returned `[AppleBooksVolume]?`, so
/// offline, a 429, a 5xx and a decode failure all reached `VolumesSection` as
/// the same `appleUnreachable: Bool` and came out as one unexplained line of
/// text with no retry. The reason was thrown away at the source, where no
/// amount of work on the view could recover it; it now returns
/// `Result<[AppleBooksVolume], APIError>`.
///
/// The rest of the client's suite is `AppleBooksTests`; this is split out
/// only to keep that file inside the 400-line cap.
@Suite("Apple Books failure reasons", .serialized)
struct AppleBooksFailureReasonTests {
    private func makeClient() -> AppleBooksClient {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("applebooks-failure-\(UUID().uuidString)", isDirectory: true)
        return AppleBooksClient(
            session: URLProtocolStub.makeSession(), clock: TestClock(), cacheDirectory: directory
        )
    }

    /// The 429 case specifically, because it is the one `VolumesSection` has
    /// different copy for and the one the client already distinguished
    /// internally before throwing the reason away.
    @Test("A rate limit is reported as a rate limit, not as an unreachable store")
    func rateLimitIsNamed() async {
        URLProtocolStub.setHandler { _ in
            .respond(.init(statusCode: 429, headers: ["Retry-After": "30"]))
        }
        defer { URLProtocolStub.reset() }
        let client = makeClient()
        let series = SeriesFactory.make(id: 3397, title: "Solo Leveling", authors: ["Chu-Gong"])

        let answer = await client.volumes(for: series, country: "gb")
        guard case let .failure(error) = answer else {
            Issue.record("a 429 is a failure, not an empty shelf")
            return
        }
        #expect(error.party == .appleBooks)
        if case .rateLimited = error {} else { Issue.record("expected .rateLimited, got \(error)") }
    }
}

/// Reads the error out of an `AppleBooksClient` answer, for the several tests
/// that only care that it failed. Since item 60 `volumes` returns a `Result`
/// rather than an optional — the reason a 429, a 5xx, a decode failure and
/// being offline used to be indistinguishable on screen.
extension Result where Success == [AppleBooksVolume], Failure == APIError {
    var failureError: APIError? {
        if case let .failure(error) = self { return error }
        return nil
    }
}
