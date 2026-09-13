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

/// Decoding a real `GET /v1/series/{id}` answer, for "What it's actually
/// like" — MangaUpdates' vote-weighted categories.
///
/// Fixture: `mangaupdates-berserk.json`, captured live 2026-09-13 from
/// `GET /v1/series/51239621230` (description redacted). 263 categories is
/// the real count on that answer, not a round number picked for the test.
@Suite("MangaUpdates series decoding")
struct MangaUpdatesSeriesDecodingTests {
    @Test("A real series answer decodes all 263 categories")
    func decodesAllCategories() throws {
        let series = try JSONDecoder().decode(
            MangaUpdatesSeries.self, from: Fixture.data("mangaupdates-berserk")
        )
        #expect(series.categories.count == 263)
        #expect(series.seriesID == 51_239_621_230)
        #expect(series.bayesianRating == 8.98)
        #expect(series.ratingVotes == 3727)
        #expect(series.latestChapter == 386)
        #expect(series.licensed == true)
        #expect(series.completed == false)
    }

    /// "Abuse of Power": 33 votes_plus, 1 votes_minus, on the fixture — this
    /// pins the raw vote fields survive decoding untouched, ahead of
    /// `MangaUpdatesCategories.ranked` doing anything with them.
    @Test("Abuse of Power decodes with its real vote split, net 32")
    func abuseOfPowerVotes() throws {
        let series = try JSONDecoder().decode(
            MangaUpdatesSeries.self, from: Fixture.data("mangaupdates-berserk")
        )
        let category = try #require(series.categories.first { $0.category == "Abuse of Power" })
        #expect(category.votesPlus == 33)
        #expect(category.votesMinus == 1)
        #expect(category.votesPlus - category.votesMinus == 32)
    }
}

/// `MangaUpdatesCategories.ranked` — pure, so exercised without any network
/// stub.
@Suite("MangaUpdates category ranking")
struct MangaUpdatesCategoriesRankingTests {
    private func series(_ votes: [MangaUpdatesSeries.CategoryVote]) -> MangaUpdatesSeries {
        MangaUpdatesSeries(
            seriesID: 1,
            categories: votes,
            bayesianRating: nil, ratingVotes: nil, latestChapter: nil, status: nil,
            licensed: nil, completed: nil
        )
    }

    private func vote(_ category: String, _ plus: Int, _ minus: Int) -> MangaUpdatesSeries.CategoryVote {
        MangaUpdatesSeries.CategoryVote(category: category, votesPlus: plus, votesMinus: minus)
    }

    @Test("A category below the minimum vote count is dropped")
    func dropsBelowMinimumVotes() {
        // 2 total votes (1 + 1), below the default minimum of 3.
        let ranked = MangaUpdatesCategories.ranked(series([vote("Rare Tag", 1, 0)]))
        #expect(ranked.isEmpty)
    }

    @Test("A category with a net score of zero or below is dropped")
    func dropsNonPositiveNetScore() {
        // 10 total votes clears the minimum, but the split is even.
        let ranked = MangaUpdatesCategories.ranked(series([vote("Split Opinion", 5, 5)]))
        #expect(ranked.isEmpty)
    }

    @Test("Qualifying categories are sorted by net score, highest first")
    func sortsByNetScore() {
        let ranked = MangaUpdatesCategories.ranked(series([
            vote("Low", 4, 1),
            vote("High", 20, 0),
            vote("Middle", 10, 2)
        ]))
        #expect(ranked.map(\.name) == ["High", "Middle", "Low"])
        #expect(ranked.map(\.score) == [20, 8, 3])
    }

    @Test("The result is capped at the limit")
    func capsAtLimit() {
        let votes = (0..<30).map { vote("Tag \($0)", 10, 0) }
        let ranked = MangaUpdatesCategories.ranked(series(votes), limit: 5)
        #expect(ranked.count == 5)
    }

    @Test("A trailing /s is stripped and internal whitespace is collapsed")
    func normalisesCategoryNames() {
        let ranked = MangaUpdatesCategories.ranked(series([
            vote("Abusive Family Member/s", 10, 0),
            vote("Time  Skip", 10, 0)
        ]))
        #expect(ranked.map(\.name).sorted() == ["Abusive Family Member", "Time Skip"])
    }
}
