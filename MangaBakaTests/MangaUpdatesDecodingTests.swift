import Foundation
import Testing
@testable import MangaBaka

/// Decoding a MangaUpdates release-search response with rows in it.
///
/// F1 (`docs/reviews/tests.md`, 2026-09-13): every MangaUpdates stub anywhere
/// else in the suite answers `{"results":[]}`, so `results[].record` and the
/// `prefix(limit)` truncation had never seen a row. `Row.record` is
/// non-optional, so a row missing it, or a wrapper key rename, throws
/// `APIError.decoding` for the whole answer — and `ReleaseScheduleService`
/// reads that as "not enough history", silently, for every series on the
/// Schedule tab at once (SUMMARY R7).
///
/// **No live capture was available here** (this review had no network
/// access) — the fixture below is built field-for-field from
/// `docs/schemas/mangaupdates_openapi.json`'s `ReleaseSearchResponseV1` /
/// `ReleaseModelSearchV1`, not a saved response. It is a schema-shape guard,
/// not proof the live endpoint still matches that schema.
///
/// Expected failure before this test existed: there was no test through
/// `releases(seriesNumber:)` with any rows at all, so `Row.record` decoding a
/// populated `results` array had never been exercised — a wrapper mismatch
/// here would have thrown `APIError.decoding` and every existing suite would
/// have stayed green, since they all stub `{"results":[]}`.
@Suite("MangaUpdates release list decoding", .serialized)
struct MangaUpdatesDecodingTests {
    /// Three rows, matching `ReleaseModelSearchV1`'s documented fields
    /// exactly: `id`, `title`, `volume`, `chapter`, `release_date`,
    /// `time_added`. The client only reads `chapter`, `volume`,
    /// `release_date`, so the others are present but not asserted on.
    private let fixture = Data(#"""
    {
      "total_hits": 3,
      "page": 1,
      "per_page": 40,
      "results": [
        {
          "record": {
            "id": 501,
            "title": "Tower of God",
            "volume": "3",
            "chapter": "236",
            "release_date": "2026-09-06",
            "time_added": {"as_rfc3339": "2026-09-06T12:00:00+00:00", "as_string": "September 6th 2026"}
          }
        },
        {
          "record": {
            "id": 502,
            "title": "Tower of God",
            "volume": "3",
            "chapter": "235",
            "release_date": "2026-08-30",
            "time_added": {"as_rfc3339": "2026-08-30T12:00:00+00:00", "as_string": "August 30th 2026"}
          }
        },
        {
          "record": {
            "id": 503,
            "title": "Tower of God",
            "volume": "3",
            "chapter": "c.234 (end)",
            "release_date": "2026-08-23",
            "time_added": {"as_rfc3339": "2026-08-23T12:00:00+00:00", "as_string": "August 23rd 2026"}
          }
        }
      ]
    }
    """#.utf8)

    private func client() -> MangaUpdatesClient {
        MangaUpdatesClient(
            baseURL: URL(string: "https://mu.example.invalid/v1").unsafeTestURL,
            session: URLProtocolStub.makeSession(),
            clock: TestClock()
        )
    }

    @Test("Rows decode through releases(seriesNumber:), newest first, in request order")
    func decodesPopulatedResults() async throws {
        URLProtocolStub.setHandler { _ in .respond(.init(body: fixture)) }
        defer { URLProtocolStub.reset() }

        let releases = try await client().releases(seriesNumber: 12_345)
        #expect(releases.count == 3)
        #expect(releases.map(\.chapter) == ["236", "235", "c.234 (end)"])
        #expect(releases.map(\.volume) == ["3", "3", "3"])
    }

    /// `release_date` is a bare `YYYY-MM-DD`; `date` reads only the first ten
    /// characters as `en_US_POSIX`/GMT, which this proves against a real
    /// schema-shaped value rather than a hand-typed one.
    @Test("release_date parses into a Date")
    func releaseDateParses() async throws {
        URLProtocolStub.setHandler { _ in .respond(.init(body: fixture)) }
        defer { URLProtocolStub.reset() }

        let releases = try await client().releases(seriesNumber: 12_345)
        let first = try #require(releases.first)
        let date = try #require(first.date)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        #expect(components.year == 2026)
        #expect(components.month == 9)
        #expect(components.day == 6)
    }

    /// F17 (`docs/reviews/tests.md`, 2026-09-13): "Extra 3" and "Side Story 2"
    /// are ordinary MangaUpdates chapter strings with the same shape a
    /// leading-digit read mistakes for chapter 3 or 2 — the Afterword/외전
    /// bug, on MangaUpdates' own numbering this time. Expected failure before
    /// the fix: `release.sample?.chapter == 3` for "Extra 3", where this now
    /// asserts `sample == nil`.
    @Test("Non-chapter release text does not become a chapter sample")
    func nonChapterTextRejected() {
        let volumeDate = "2026-08-21"
        func release(chapter: String) -> MangaUpdatesClient.Release {
            MangaUpdatesClient.Release(chapter: chapter, volume: "5", releaseDate: volumeDate)
        }
        #expect(release(chapter: "Extra 3").sample == nil)
        #expect(release(chapter: "Side Story 2").sample == nil)
        #expect(release(chapter: "Omake").sample == nil)
        // The ordinary forms must still work.
        #expect(release(chapter: "57-58").sample?.chapter == 57)
        #expect(release(chapter: "c.12 (end)").sample?.chapter == 12)
    }

    /// `perpage` is not honoured by the live endpoint (per the client's own
    /// comment); `limit` truncates client-side. Proved against a populated
    /// result for the first time — every other test truncates an already
    /// empty array.
    @Test("The limit truncates a populated result")
    func limitTruncatesPopulatedResults() async throws {
        URLProtocolStub.setHandler { _ in .respond(.init(body: fixture)) }
        defer { URLProtocolStub.reset() }

        let releases = try await client().releases(seriesNumber: 12_345, limit: 2)
        #expect(releases.count == 2)
        #expect(releases.map(\.chapter) == ["236", "235"])
    }
}
