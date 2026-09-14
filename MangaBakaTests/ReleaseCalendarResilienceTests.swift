import Foundation
import Testing
@testable import MangaBaka

/// Item 10 / wire W4: the two ways `/v1/works/upcoming` used to throw away an
/// answer it had already been given.
///
/// This is the charter's flagship defect, in the file it happened in.
/// `UpcomingWork`'s own comment records that `price` was modelled as `String`,
/// that every real response therefore threw, and that the announced-releases
/// section — "the difference between a fact and an estimate" — was empty from
/// the day it was built. The *model* was fixed on 2026-09-11; the
/// *fragility* was not, and one unexpected row in 246 still emptied the
/// Schedule screen's only factual section.
///
/// Its own file rather than `ReleaseCalendarTests` because that suite's
/// `calendar(_:)` helper answers the same body for page 1 and nothing after,
/// and both tests here need the pages to differ.
@Suite("Release calendar resilience", .serialized)
struct ReleaseCalendarResilienceTests {
    private func makeCalendar() -> ReleaseCalendar {
        ReleaseCalendar(client: APIClient(
            baseURL: URL(string: "https://api.example.invalid").unsafeTestURL,
            session: URLProtocolStub.makeSession(),
            tokenProvider: UnauthenticatedTokenProvider()
        ))
    }

    private static func page(_ works: [String]) -> Data {
        Data("{\"status\": 200, \"data\": [\(works.joined(separator: ","))]}".utf8)
    }

    private static func work(_ id: String, date: String) -> String {
        "{\"id\": \"\(id)\", \"series_id\": 1, \"release_date\": \"\(date)\"}"
    }

    /// A row whose `id` is a number where the model declares `String` — one
    /// unexpected shape, the same kind that emptied this section before.
    private static let badRow = "{\"id\": 42, \"series_id\": 1, \"release_date\": \"2026-09-16\"}"

    /// Expected to fail on the old code with a wrong *value*, not a compile
    /// error: `client.get` threw on the whole page, the `catch` set `failure`,
    /// and `upcoming()` returned `.failed(_, stale: nil)` — so `.value` is nil
    /// and the id list reads empty where this wants the one good row.
    @Test("One bad row costs that row, not the page")
    func oneBadRowDoesNotEmptyThePage() async {
        URLProtocolStub.setHandler { _ in
            .respond(.init(body: Self.page([Self.work("a", date: "2026-09-15"), Self.badRow])))
        }
        defer { URLProtocolStub.reset() }

        let fetched = await makeCalendar().upcoming()
        #expect(fetched.value?.map(\.id) == ["a"])
    }

    /// The second half, and the more expensive one: `catch … break` discarded
    /// every page that had already succeeded. A failure on page 2 threw page 1
    /// away as well and the screen showed nothing — the same "an error means
    /// no data" shape `Fetched` exists to stop.
    ///
    /// Expected to fail on the old code by finding `.failed` with `stale: nil`
    /// here, so `value` is nil where this wants page 1's 50 works and
    /// `isPartial` is unreachable.
    @Test("A failed second page keeps the first page's works, marked partial")
    func failedLaterPageKeepsWhatArrived() async {
        // Page 1 must be a full 50 rows or the pager stops before page 2.
        let firstPage = Self.page((0..<50).map { Self.work("p1-\($0)", date: "2026-09-15") })
        URLProtocolStub.setHandler { request in
            let isFirst = !(request.url?.query?.contains("page=2") ?? false)
            return isFirst ? .respond(.init(body: firstPage))
                           : .respond(.init(statusCode: 500))
        }
        defer { URLProtocolStub.reset() }

        let fetched = await makeCalendar().upcoming()
        guard case let .loaded(works, _, isPartial) = fetched else {
            Issue.record("Expected page 1 to survive page 2's failure, got \(fetched)")
            return
        }
        #expect(works.count == 50)
        #expect(isPartial, "the caller must be able to tell this is not the whole window")
    }

    /// The control for both: a clean two-page answer is `.loaded` and *not*
    /// partial, so neither assertion above is passing because `upcoming()` has
    /// started calling every answer partial or dropping every row.
    @Test("Control: a clean answer is complete and drops nothing")
    func cleanAnswerIsComplete() async {
        URLProtocolStub.setHandler { _ in
            .respond(.init(body: Self.page([Self.work("a", date: "2026-09-15"),
                                            Self.work("b", date: "2026-09-16")])))
        }
        defer { URLProtocolStub.reset() }

        let fetched = await makeCalendar().upcoming()
        guard case let .loaded(works, _, isPartial) = fetched else {
            Issue.record("Expected .loaded, got \(fetched)")
            return
        }
        #expect(works.map(\.id) == ["a", "b"])
        #expect(!isPartial)
    }
}
