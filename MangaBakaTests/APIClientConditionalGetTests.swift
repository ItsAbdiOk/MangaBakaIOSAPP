import Foundation
import Testing
@testable import MangaBaka

/// The conditional-GET half of the client, used by `SeriesRepository.feed`
/// for the feeds' Last-Modified/If-Modified-Since revalidation.
///
/// Split into its own file rather than appended to `APIClientTests.swift`,
/// which was already at the lint's 400-line file-length ceiling.
///
/// MEASURED 2026-09-13 against api.mangabaka.org: feed responses carry no
/// `ETag`, only `Last-Modified` (e.g. "Sun, 13 Sep 2026 13:56:53 GMT") and
/// `cache-control: public, max-age=60`; repeating that value back as
/// `If-Modified-Since` gets a 304 with a zero-byte body.
@Suite("Conditional GET (Last-Modified / If-Modified-Since)", .serialized)
struct APIClientConditionalGetTests {
    private let baseURL = URL(string: "https://api.example.invalid").unsafeTestURL

    private func makeClient() -> APIClient {
        APIClient(
            baseURL: baseURL,
            session: URLProtocolStub.makeSession(),
            tokenProvider: UnauthenticatedTokenProvider()
        )
    }

    /// Control: a 200 must still decode and hand back the payload, plus the
    /// response's own `Last-Modified`, exactly as `get` would for the payload
    /// alone. If this fails, nothing below means anything.
    @Test("Control — a 200 answers .fresh with the payload and Last-Modified")
    func freshCarriesLastModified() async throws {
        URLProtocolStub.setHandler { _ in
            .respond(.init(
                body: Data(#"{"status":200,"data":[1,2,3]}"#.utf8),
                headers: ["Last-Modified": "Sun, 13 Sep 2026 13:56:53 GMT"]
            ))
        }
        defer { URLProtocolStub.reset() }

        let result: APIClient.Conditional<[Int]> = try await makeClient().get(
            "/things", ifModifiedSince: nil
        )
        guard case let .fresh(values, lastModified) = result else {
            Issue.record("Expected .fresh, got \(result)")
            return
        }
        #expect(values == [1, 2, 3])
        #expect(lastModified == "Sun, 13 Sep 2026 13:56:53 GMT")
    }

    /// The whole point: a 304 is a success, never an `APIError` thrown to a
    /// caller that has to unwrap it out of a catch block.
    @Test("304 answers .notModified rather than throwing")
    func notModifiedIsNotAnError() async throws {
        URLProtocolStub.setHandler { _ in .respond(.init(statusCode: 304, body: Data())) }
        defer { URLProtocolStub.reset() }

        let result: APIClient.Conditional<[Int]> = try await makeClient().get(
            "/things", ifModifiedSince: "Sun, 13 Sep 2026 13:56:53 GMT"
        )
        guard case .notModified = result else {
            Issue.record("Expected .notModified, got \(result)")
            return
        }
    }

    /// Verbatim, never reformatted — a re-formatted date can fail the
    /// server's own byte-for-byte comparison and never earn a 304.
    @Test("If-Modified-Since is sent exactly as given")
    func sendsHeaderVerbatim() async throws {
        URLProtocolStub.setHandler { _ in .respond(.init(statusCode: 304)) }
        defer { URLProtocolStub.reset() }

        let header = "Sun, 13 Sep 2026 13:56:53 GMT"
        let _: APIClient.Conditional<[Int]> = try await makeClient().get("/things", ifModifiedSince: header)

        let sent = try #require(URLProtocolStub.requests.first)
        #expect(sent.value(forHTTPHeaderField: "If-Modified-Since") == header)
    }

    /// `ifModifiedSince: nil` is the "nothing cached yet" case, and it must
    /// look exactly like an ordinary unconditional request.
    @Test("A nil ifModifiedSince sends no conditional header at all")
    func nilMeansNoHeader() async throws {
        URLProtocolStub.setHandler { _ in
            .respond(.init(body: Data(#"{"status":200,"data":[]}"#.utf8)))
        }
        defer { URLProtocolStub.reset() }

        let _: APIClient.Conditional<[Int]> = try await makeClient().get("/things", ifModifiedSince: nil)

        let sent = try #require(URLProtocolStub.requests.first)
        #expect(sent.value(forHTTPHeaderField: "If-Modified-Since") == nil)
    }

    /// A 304 goes through the same `perform` as any other request, so it
    /// still counts against the rate limiter's own per-IP/window counters —
    /// but it must never be treated like a 429 and trip the backoff that
    /// exists solely for that status code. A run of "nothing changed"
    /// answers is not a run of failures.
    @Test("Repeated 304s never trip the rate-limit backoff")
    func notModifiedNeverTripsBackoff() async throws {
        URLProtocolStub.setHandler { _ in .respond(.init(statusCode: 304)) }
        defer { URLProtocolStub.reset() }

        let client = makeClient()
        for _ in 0..<5 {
            let result: APIClient.Conditional<[Int]> = try await client.get(
                "/things", ifModifiedSince: "Sun, 13 Sep 2026 13:56:53 GMT"
            )
            guard case .notModified = result else {
                Issue.record("Expected .notModified, got \(result)")
                return
            }
        }
        #expect(
            URLProtocolStub.requests.count == 5,
            "None of the five should have been refused by a backoff a 304 must never trip"
        )
    }
}
