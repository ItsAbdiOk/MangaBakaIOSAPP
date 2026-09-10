import Testing
import Foundation
@testable import MangaBaka

/// Announced release dates, as opposed to estimated ones.
@Suite("Release calendar")
struct ReleaseCalendarTests {
    private func work(_ id: String, series: Int?, date: String?) -> String {
        """
        {
          "id": "\(id)",
          "series_id": \(series.map(String.init) ?? "null"),
          "release_date": \(date.map { "\"\($0)\"" } ?? "null"),
          "sequence_string": "11",
          "pages": 228,
          "collections": [{"title": "A Tale of the Secret Saint"}],
          "links": [{"type": "publisher", "link": "https://example.test/book"}]
        }
        """
    }

    private func calendar(_ works: [String]) -> ReleaseCalendar {
        URLProtocolStub.setHandler { request in
            // Page two onwards is empty, so the pager stops.
            let isFirst = !(request.url?.query?.contains("page=2") ?? false)
            let body = isFirst ? works.joined(separator: ",") : ""
            return .respond(.init(body: Data("""
            {"status": 200, "data": [\(body)]}
            """.utf8)))
        }
        return ReleaseCalendar(client: APIClient(
            baseURL: URL(string: "https://api.example.invalid").unsafeTestURL,
            session: URLProtocolStub.makeSession(),
            tokenProvider: UnauthenticatedTokenProvider()
        ))
    }

    @Test("Dated works come first, in date order")
    func sortsByDate() async throws {
        defer { URLProtocolStub.reset() }
        let calendar = calendar([
            work("c", series: 3, date: "2026-10-01"),
            work("a", series: 1, date: "2026-09-15"),
            // Undated is not upcoming in any useful sense, and used to sort to
            // the very top because nil compared low.
            work("z", series: 9, date: nil),
            work("b", series: 2, date: "2026-09-20")
        ])

        let works = await calendar.upcoming()
        #expect(works.map(\.id) == ["a", "b", "c", "z"])
    }

    @Test("Only the reader's own series are shown")
    func narrowsToTheLibrary() async throws {
        defer { URLProtocolStub.reset() }
        // The unfiltered window is a few hundred works a month and almost none
        // of them are yours; unnarrowed it is a catalogue, not a schedule.
        let calendar = calendar([
            work("mine", series: 42, date: "2026-09-15"),
            work("theirs", series: 99, date: "2026-09-16")
        ])

        let mine = await calendar.mine(seriesIDs: [42])
        #expect(mine.map(\.id) == ["mine"])
    }

    @Test("With no library there is nothing to narrow against, so nothing is shown")
    func noLibraryMeansNoSection() async throws {
        defer { URLProtocolStub.reset() }
        let calendar = calendar([work("a", series: 1, date: "2026-09-15")])

        #expect(await calendar.mine(seriesIDs: []).isEmpty)
    }

    @Test("A release date is a calendar day, not an instant")
    func datesAreParsedInUTC() async throws {
        defer { URLProtocolStub.reset() }
        // Parsed in the device's own zone, "2026-09-15" becomes midnight local,
        // which anywhere west of UTC renders as the 14th.
        let calendar = calendar([work("a", series: 1, date: "2026-09-15")])
        let work = try #require(await calendar.upcoming().first)

        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let date = try #require(work.date)
        #expect(utc.component(.day, from: date) == 15)
        #expect(utc.component(.month, from: date) == 9)
    }

    @Test("A work says only what the API supplied")
    func detailIsHonest() async throws {
        defer { URLProtocolStub.reset() }
        let calendar = calendar([work("a", series: 1, date: "2026-09-15")])
        let work = try #require(await calendar.upcoming().first)

        #expect(work.volume == "Vol. 11")
        #expect(work.title == "A Tale of the Secret Saint")
        #expect(work.publisherLink?.absoluteString == "https://example.test/book")
        #expect(work.price == nil, "no price came back, so none is claimed")
    }
}
