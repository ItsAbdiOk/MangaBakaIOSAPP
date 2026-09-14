import Foundation
import Testing
@testable import MangaBaka

/// A shared link, parsed to whichever tracker's id it names — before any
/// lookup turns that id into a MangaBaka series (`OpenSharedURLIntent`).
///
/// Expected to fail before `SharedURLResolver.swift` existed with: `Cannot
/// find 'SharedURLResolver' in scope` — there was no parser for anything but
/// mangabaka.org links (`SeriesWebLink`) anywhere in the app.
@Suite("Shared URL resolver")
struct SharedURLResolverTests {
    /// 15 real link shapes: trailing slashes, query strings, `www.`, http vs
    /// https and title slugs after the id all have to survive, and an
    /// AniList *anime* link must not be read as a manga id (see the last
    /// four rows).
    private static let fixtures: [(url: String, target: SharedURLTarget?)] = [
        ("https://mangabaka.org/manhwa/3397/Solo-Leveling", .mangaBaka(id: 3397)),
        ("https://mangabaka.org/3397", .mangaBaka(id: 3397)),
        ("https://www.mangabaka.org/manhwa/3397/", .mangaBaka(id: 3397)),
        ("https://anilist.co/manga/30013/One-Piece", .aniList(id: 30013)),
        ("http://www.anilist.co/manga/30013", .aniList(id: 30013)),
        ("https://myanimelist.net/manga/13/One-Piece", .myAnimeList(id: 13)),
        ("https://myanimelist.net/manga/13", .myAnimeList(id: 13)),
        ("https://www.mangaupdates.com/series/o1c1lqx/one-piece", .mangaUpdates(id: "o1c1lqx")),
        ("https://mangaupdates.com/series/o1c1lqx?ref=share", .mangaUpdates(id: "o1c1lqx")),
        ("https://mangadex.org/title/a1c7c817-4e59-43b7-9365-09675a149a6f/one-piece",
         .mangaDex(uuid: "a1c7c817-4e59-43b7-9365-09675a149a6f")),
        ("https://mangadex.org/title/a1c7c817-4e59-43b7-9365-09675a149a6f",
         .mangaDex(uuid: "a1c7c817-4e59-43b7-9365-09675a149a6f")),
        // Must all be nil.
        ("https://anilist.co/anime/101922/Attack-on-Titan", nil),
        ("https://myanimelist.net/anime/16498/Shingeki-no-Kyojin", nil),
        ("https://example.com/manga/30013", nil),
        ("https://mangaupdates.com/groups/123", nil)
    ]

    @Test("15 real link shapes resolve to the tracker id they name, or nil")
    func resolves() throws {
        for fixture in Self.fixtures {
            let url = try #require(URL(string: fixture.url), Comment(rawValue: fixture.url))
            #expect(SharedURLResolver.target(from: url) == fixture.target, Comment(rawValue: fixture.url))
        }
    }

    @Test("Exactly 4 of the 15 fixtures are nil")
    func nilCount() {
        #expect(Self.fixtures.filter { $0.target == nil }.count == 4)
        #expect(Self.fixtures.count == 15)
    }
}
