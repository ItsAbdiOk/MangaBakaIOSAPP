import Foundation
import Testing
@testable import MangaBaka

/// `NetworkLedger.record`'s `failed` flag, as seen from `APIClient.perform`.
///
/// Its own file rather than appended to `APIClientTests.swift`, which is
/// already past the lint's 400-line file-length warning.
///
/// Services-audit finding: `perform` used to compute `failed` as "not in
/// 200..<300", which marks a 304 as a failure — but a 304 is `get`'s own
/// success path (see `APIClient.Conditional`, `APIClientConditionalGetTests`)
/// and the ledger exists to answer "is the API healthy", which a run of
/// perfectly healthy "nothing changed" answers must not poison.
@Suite("NetworkLedger records only real failures", .serialized)
struct APIClientLedgerTests {
    private let baseURL = URL(string: "https://api.example.invalid").unsafeTestURL

    private func makeClient() -> APIClient {
        APIClient(
            baseURL: baseURL,
            session: URLProtocolStub.makeSession(),
            tokenProvider: UnauthenticatedTokenProvider()
        )
    }

    /// Expected to fail before the fix: `failed` was
    /// `!(200..<300).contains(statusCode)`, which is `true` for 304 — so this
    /// assertion would have read the entry's `failures` as `before + 1`
    /// instead of `before`.
    @Test("A 304 is not recorded as a failure")
    func notModifiedIsNotAFailure() async throws {
        let path = "/ledger-304-\(UUID().uuidString)"
        URLProtocolStub.setHandler { _ in .respond(.init(statusCode: 304, body: Data())) }
        defer { URLProtocolStub.reset() }

        let key = NetworkLedger.shape(path)
        let before = await NetworkLedger.shared.byPath[key]?.failures ?? 0

        let result: APIClient.Conditional<[Int]> = try await makeClient().get(
            path, ifModifiedSince: "Sun, 13 Sep 2026 13:56:53 GMT"
        )
        guard case .notModified = result else {
            Issue.record("Expected .notModified, got \(result)")
            return
        }

        let after = await NetworkLedger.shared.byPath[key]?.failures ?? 0
        #expect(after == before, "A 304 is a success path, not a failure")
    }

    /// Control: an actual server error on the same path really is counted, so
    /// the assertion above is not passing because nothing is ever recorded as
    /// a failure at all.
    @Test("Control — a 500 is still recorded as a failure")
    func serverErrorIsStillAFailure() async throws {
        let path = "/ledger-500-\(UUID().uuidString)"
        URLProtocolStub.setHandler { _ in
            .respond(.init(statusCode: 500, body: Data(#"{"status":500}"#.utf8)))
        }
        defer { URLProtocolStub.reset() }

        let key = NetworkLedger.shape(path)
        let before = await NetworkLedger.shared.byPath[key]?.failures ?? 0

        await #expect(throws: APIError.self) {
            let _: [Int] = try await makeClient().get(path)
        }

        let after = await NetworkLedger.shared.byPath[key]?.failures ?? 0
        #expect(after == before + 1, "A real server error must still count as a failure")
    }
}
