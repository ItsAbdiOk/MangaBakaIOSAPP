import Foundation
import Testing
@testable import MangaBaka

/// `OpenSharedURLIntent`'s resolution logic, isolated from `perform()` (which
/// needs a live `AppServices` no test here builds — see
/// `AddToLibraryIntentTests`'s own doc for why).
///
/// Runs against the **real bundled Wikidata table**, the same way
/// `WikidataIdentityTests` does: a stub would only prove the lookup compiles,
/// and the point of this test is that a real AniList link actually resolves.
@Suite("Open a shared URL")
struct OpenSharedURLIntentTests {
    private final class BundleMarker {}

    private static func wikidata() -> WikidataIdentityTable {
        let testBundle = Bundle(for: BundleMarker.self)
        let hasResource = testBundle.url(
            forResource: "WikidataIdentity", withExtension: "json.gz"
        ) != nil
        return WikidataIdentityTable(bundle: hasResource ? testBundle : .main)
    }

    /// A mangabaka.org link never needs the table at all — its id already
    /// is the MangaBaka id.
    @Test("A mangabaka.org link resolves without any lookup")
    func mangaBakaNeedsNoLookup() async {
        let id = await OpenSharedURLIntent.seriesID(for: .mangaBaka(id: 3397), wikidata: Self.wikidata())
        #expect(id == 3397)
    }

    /// Solo Leveling, AniList id 105398 — used elsewhere in this codebase's
    /// own fixtures (`WikidataIdentityTests`' Apothecary rows are a
    /// different series; this one is picked because `WikidataIdentityTable`
    /// exposes a public `identity(aniListID:)` to resolve it with, unlike
    /// MangaUpdates or MyAnimeList — see `seriesID`'s own doc comment).
    /// Expected to fail before `seriesID(for:wikidata:)` existed with:
    /// `Cannot find 'seriesID' in scope`.
    @Test("An AniList link resolves through the Wikidata table's public lookup")
    func aniListResolves() async throws {
        let table = Self.wikidata()
        let identity = try #require(
            await table.identity(aniListID: 105_398), "AniList 105398 must be in the bundled table"
        )
        let mangaBakaID = try #require(identity.mangaBakaID)
        let resolved = await OpenSharedURLIntent.seriesID(for: .aniList(id: 105_398), wikidata: table)
        #expect(resolved == mangaBakaID)
    }

    /// The same series through its other two tracker ids. Solo Leveling is
    /// MangaBaka 3397, MyAnimeList 121496 and MangaUpdates `6z1uqw7` in the
    /// bundled table (read straight out of `WikidataIdentity.json.gz` on
    /// 2026-09-14). Fails before `identity(myAnimeListID:)` and
    /// `identity(mangaUpdatesID:)` existed with both `== 3397` expectations
    /// reading `nil == 3397`.
    @Test("MyAnimeList and MangaUpdates links resolve through the id indexes")
    func trackerIDsResolve() async {
        let table = Self.wikidata()
        let myAnimeList = await OpenSharedURLIntent.seriesID(
            for: .myAnimeList(id: 121_496), wikidata: table
        )
        let mangaUpdates = await OpenSharedURLIntent.seriesID(
            for: .mangaUpdates(id: "6z1uqw7"), wikidata: table
        )
        #expect(myAnimeList == 3_397)
        #expect(mangaUpdates == 3_397)
    }

    /// An id the table has never seen, and MangaDex, which no table in this
    /// app carries at all — see `seriesID`'s doc comment.
    @Test("Unknown tracker ids and MangaDex answer nil")
    func unresolvedTrackers() async {
        let table = Self.wikidata()
        let myAnimeList = await OpenSharedURLIntent.seriesID(
            for: .myAnimeList(id: 999_999_999), wikidata: table
        )
        let mangaUpdates = await OpenSharedURLIntent.seriesID(
            for: .mangaUpdates(id: "zzzzzzz"), wikidata: table
        )
        let mangaDex = await OpenSharedURLIntent.seriesID(
            for: .mangaDex(uuid: "a1c7c817-4e59-43b7-9365-09675a149a6f"), wikidata: table
        )
        #expect(myAnimeList == nil)
        #expect(mangaUpdates == nil)
        #expect(mangaDex == nil)
    }

    @Test("Not-found copy never mentions raw ids or technical detail")
    func notFoundCopy() {
        #expect(OpenSharedURLIntent.notFoundDialog(for: .aniList(id: 1)).contains("doesn't have a match"))
        #expect(OpenSharedURLIntent.notFoundDialog(for: .mangaDex(uuid: "x")).contains("MangaDex"))
    }
}
