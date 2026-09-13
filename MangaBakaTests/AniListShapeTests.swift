import Foundation
import Testing
@testable import MangaBaka

/// AniList's own response shape, decoded. Written from their published schema
/// rather than from a response, because the API is disabled — see
/// `CharacterSourceTests`.
///
/// Split out of `CharacterSourceTests.swift` when the union-of-two-sources
/// feature (2026-09-13) pushed that file over the 400-line lint cap — this
/// suite and `TrackerIDTests` below test pure decoding/formatting and have no
/// dependency on `CharacterService`'s network behaviour, so they cost nothing
/// to separate.
@Suite("AniList response shape")
struct AniListShapeTests {
    private func decode(_ json: String) -> AniListClient.Response {
        guard let decoded = try? JSONDecoder()
            .decode(AniListClient.Response.self, from: Data(json.utf8))
        else {
            fatalError("AniList fixture no longer decodes: \(json)")
        }
        return decoded
    }

    /// `Media` is capitalised in a GraphQL response and would otherwise decode
    /// as absent — the same trap as the library's capitalised `Series` key,
    /// which cost this app a silent decode failure once already.
    @Test("The capitalised Media key is decoded")
    func capitalisedMediaKey() {
        let response = decode("""
        {"data":{"Media":{"characters":{"edges":[
          {"role":"MAIN","node":{"id":1,"name":{"full":"A"},
           "image":{"large":"https://s4.anilist.co/x.png","medium":null}}}]}}}}
        """)
        #expect(response.data?.media?.characters?.edges?.count == 1)
    }

    /// AniList shouts its roles. The app compares against "Main".
    @Test("Roles are normalised to the app's casing")
    func roleCasing() {
        let response = decode("""
        {"data":{"Media":{"characters":{"edges":[
          {"role":"MAIN","node":{"id":1,"name":{"full":"A"},
           "image":{"large":"https://s4.anilist.co/x.png","medium":null}}},
          {"role":"SUPPORTING","node":{"id":2,"name":{"full":"B"},
           "image":{"large":"https://s4.anilist.co/y.png","medium":null}}}]}}}}
        """)
        let cast = AniListClient.cast(from: response, limit: 20)
        #expect(cast.map(\.role) == ["Main", "Supporting"])
        #expect(cast[0].isMain)
        #expect(!cast[1].isMain)
    }

    /// AniList substitutes a default silhouette rather than a null image, the
    /// same defect Shikimori's `missing_x96.jpg` produces.
    @Test("The default silhouette is not a portrait")
    func placeholderDropped() {
        let response = decode("""
        {"data":{"Media":{"characters":{"edges":[
          {"role":"MAIN","node":{"id":1,"name":{"full":"Faceless"},
           "image":{"large":"https://s4.anilist.co/file/anilistcdn/character/large/default.jpg",
                    "medium":null}}}]}}}}
        """)
        #expect(AniListClient.cast(from: response, limit: 20).isEmpty)
    }

    @Test("The placeholder is recognised by its path", arguments: [
        ("https://s4.anilist.co/file/anilistcdn/character/large/default.jpg", true),
        ("https://s4.anilist.co/file/anilistcdn/character/large/b88-x.png", false)
    ])
    func placeholderDetection(_ url: String, _ expected: Bool) {
        #expect(AniListClient.isPlaceholderPortrait(url) == expected)
    }

    /// AniList already sorts by [ROLE, RELEVANCE], so the app must not
    /// re-sort — doing so would discard their relevance ordering, which is
    /// better than anything the app can compute.
    @Test("AniList's own order is preserved")
    func orderPreserved() {
        let response = decode("""
        {"data":{"Media":{"characters":{"edges":[
          {"role":"MAIN","node":{"id":1,"name":{"full":"First"},
           "image":{"large":"https://s4.anilist.co/a.png","medium":null}}},
          {"role":"MAIN","node":{"id":2,"name":{"full":"Second"},
           "image":{"large":"https://s4.anilist.co/b.png","medium":null}}}]}}}}
        """)
        #expect(AniListClient.cast(from: response, limit: 20).map(\.name) == ["First", "Second"])
    }

    /// The query has to ask for MANGA. Without the type filter AniList matches
    /// an anime with the same id and returns its cast.
    @Test("The query is scoped to manga and sorted by role")
    func querySpecifics() {
        #expect(AniListClient.query.contains("type: MANGA"))
        #expect(AniListClient.query.contains("sort: [ROLE, RELEVANCE]"))
    }

    // MARK: Birthday formatting

    /// Before the fix (docs/reviews/third-parties.md finding 14, 2026-09-13),
    /// the birthday was hand-joined as "\(monthName) \(day)" — always the
    /// English "month day" order. Expected to fail before the fix with:
    /// "4 mars" != "mars 4" — a French phone reads day-before-month.
    @Test("A French locale orders the day before the month")
    func frenchLocaleOrdersDayFirst() {
        let date = AniListClient.ProfileDate(year: nil, month: 3, day: 4)
        let formatted = AniListClient.formattedBirthday(date, locale: Locale(identifier: "fr_FR"))
        #expect(formatted == "4 mars")
    }

    /// Control: the same date in English keeps the "month day" order the app
    /// has always shown, so the French case above is proving locale-awareness
    /// was added, not that formatting broke generally.
    @Test("An English locale keeps the month before the day")
    func englishLocaleOrdersMonthFirst() {
        let date = AniListClient.ProfileDate(year: nil, month: 3, day: 4)
        let formatted = AniListClient.formattedBirthday(date, locale: Locale(identifier: "en_US"))
        #expect(formatted == "March 4")
    }

    /// A month with no day — a birthday AniList knows only approximately —
    /// still has to print something, with no day number attached.
    @Test("A month with no day prints the month alone")
    func monthAloneWithNoDay() {
        let date = AniListClient.ProfileDate(year: nil, month: 3, day: nil)
        let formatted = AniListClient.formattedBirthday(date, locale: Locale(identifier: "en_US"))
        #expect(formatted == "March")
    }

    @Test("No month at all prints nothing")
    func noMonthPrintsNothing() {
        let yearOnly = AniListClient.ProfileDate(year: 1999, month: nil, day: nil)
        #expect(AniListClient.formattedBirthday(yearOnly) == nil)
        #expect(AniListClient.formattedBirthday(nil) == nil)
    }
}

/// The ids come out of MangaBaka's own `source` block, where every tracker id
/// is normalised to a string whatever shape it arrived in.
@Suite("Tracker ids")
struct TrackerIDTests {
    @Test("AniList and Shikimori ids are read from the source block")
    func readsIDs() throws {
        let series = try Fixture.decoder().decode(Series.self, from: Data("""
        {"id": 1, "state": "active", "cover": {},
         "source": {"anilist": {"id": 105398}, "shikimori": {"id": 121496}}}
        """.utf8))
        #expect(series.aniListID == 105_398)
        #expect(series.shikimoriID == 121_496)
    }

    /// `anime_planet` sends "solo-leveling". A non-numeric id is not an id this
    /// can use, and must read as absent rather than crashing or coercing.
    @Test("A non-numeric tracker id reads as absent")
    func nonNumericID() throws {
        let series = try Fixture.decoder().decode(Series.self, from: Data("""
        {"id": 1, "state": "active", "cover": {},
         "source": {"anilist": {"id": "not-a-number"}}}
        """.utf8))
        #expect(series.aniListID == nil)
    }

    @Test("A series with no source block has no ids")
    func noSource() {
        let series = SeriesFactory.make(id: 1)
        #expect(series.aniListID == nil)
        #expect(series.shikimoriID == nil)
    }
}
