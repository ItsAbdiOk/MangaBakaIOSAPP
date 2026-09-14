import Testing
import Foundation
@testable import MangaBaka

/// `WikidataIdentityTable` against the **real bundled table**, the way
/// `TagTaxonomyTests` exercises the real taxonomy. A stub would prove the
/// decoder compiles; only the shipped bytes prove the app can tell a light
/// novel from a manga, which is the whole reason the file exists.
///
/// Built 2026-09-14 by `scripts/generate-wikidata-identity.py`: 8,816 rows,
/// 451 KB gzipped.
@Suite("Wikidata identity table")
struct WikidataIdentityTests {
    private final class BundleMarker {}

    /// The bundled resource, found in the test bundle when the resource is
    /// copied there and in `Bundle.main` otherwise — the same two-step
    /// `OfflineCatalogueTests` and `TagTaxonomyTests` use.
    private static func table() -> WikidataIdentityTable {
        let testBundle = Bundle(for: BundleMarker.self)
        let hasResource = testBundle.url(
            forResource: "WikidataIdentity", withExtension: "json.gz"
        ) != nil
        return WikidataIdentityTable(bundle: hasResource ? testBundle : .main)
    }

    // MARK: - The bug this exists to prevent

    /// **The Apothecary Diaries.** Three works, one title, three formats — and
    /// this app has already shipped one bug where untagged light novels filled
    /// a comic shelf.
    ///
    /// Expected to fail before `WikidataIdentity.swift` and the bundled table
    /// existed with: `Cannot find 'WikidataIdentityTable' in scope` — there was
    /// no source of format truth in the app at all. With the table present but
    /// its `P31` bucketing wrong, it fails on the first `#expect` as
    /// `Expectation failed: (manga) == (.lightNovel)`.
    @Test("The Apothecary Diaries is three separately typed works")
    func apothecaryDiariesIsThreeWorks() async throws {
        let table = Self.table()

        let manga = try #require(await table.identity(qid: 106_090_656), "Q106090656, the manga series")
        let lightNovel = try #require(
            await table.identity(qid: 48_751_907), "Q48751907, the light novel series"
        )
        let novel = try #require(await table.identity(qid: 106_090_452), "Q106090452, the novel series")

        #expect(manga.format == .manga)
        #expect(lightNovel.format == .lightNovel)
        #expect(novel.format == .novel)

        // The shelf question, asked the way the shelf asks it.
        #expect(manga.format.isComic)
        #expect(!lightNovel.format.isComic, "a light novel must never pass a comic shelf's filter")
        #expect(lightNovel.format.isProse)
        #expect(!novel.format.isComic)
    }

    @Test("the three Apothecary works know about each other")
    func apothecarySiblingsAreLinked() async throws {
        let table = Self.table()
        let manga = try #require(await table.identity(qid: 106_090_656))
        let siblingQIDs = Set(await table.siblings(of: manga).map(\.qid))

        // Transitive on purpose: the manga's only direct P144 edge is to the
        // light novel. The novel is one hop further and a reader asking "what
        // else is this story" wants it.
        #expect(siblingQIDs.contains(48_751_907), "the light novel it is based on")
        #expect(siblingQIDs.contains(106_090_452), "the novel the light novel came from")

        let formats = Set(await table.siblings(of: manga).map(\.format))
        #expect(formats.contains(.lightNovel))
        #expect(formats.contains(.novel))
    }

    /// The join the app actually performs: a `Series` off MangaBaka's API,
    /// resolved by id, landing on the manga item and not on its light novel
    /// twin. Series 222 is The Apothecary Diaries in MangaBaka.
    @Test("a MangaBaka series resolves to the manga item, not its light novel twin")
    func mangaBakaSeriesResolvesToTheManga() async throws {
        let table = Self.table()
        let series = SeriesFactory.make(id: 222, title: "The Apothecary Diaries")
        let identity = try #require(await table.identity(for: series))
        #expect(identity.qid == 106_090_656)
        #expect(identity.format == .manga)
        #expect(await table.format(for: series) == .manga)
    }

    /// The same join by AniList id, which is how 8,178 of the 8,816 rows are
    /// reachable — MangaBaka hands the AniList id back in its `source` object,
    /// so this is an exact id join with no title matching anywhere.
    @Test("a series with only an AniList id still resolves")
    func aniListJoinWorks() async throws {
        let table = Self.table()
        // Q20016948, Delicious in Dungeon, AniList 86082. Deliberately given a
        // MangaBaka id the table cannot know (0) so only the AniList leg can
        // answer.
        let series = SeriesFactory.make(
            id: 0,
            title: "Delicious in Dungeon",
            source: ["anilist": Series.TrackerEntry(id: "86082", rating: nil, ratingNormalized: nil)]
        )
        let identity = try #require(await table.identity(for: series))
        #expect(identity.qid == 20_016_948)
        #expect(identity.format == .manga)
        #expect(identity.nativeTitle == "ダンジョン飯")
        #expect(identity.nativeLanguage == "ja")
    }

    // MARK: - Honesty about reach

    /// A series the table has never heard of answers `nil`, and `nil` is not
    /// "not a comic". Measured 2026-09-14 over a uniform random draw of 60 of
    /// the offline index's 19,300 series: 25 % matched. A caller that reads a
    /// miss as a negative hides three quarters of the catalogue.
    @Test("an unknown series answers nil rather than a format")
    func unknownSeriesIsNil() async {
        let table = Self.table()
        let series = SeriesFactory.make(id: 999_999_999, title: "Not A Real Series")
        #expect(await table.identity(for: series) == nil)
        #expect(await table.format(for: series) == nil)
    }

    /// The build-time counts ship with the file so the reading code knows how
    /// far it reaches. Floors, not equalities — the table is regenerated per
    /// release and Wikidata grows.
    @Test("coverage counts ship with the table and are plausible")
    func coverageIsShipped() async throws {
        let table = Self.table()
        let coverage = try #require(await table.coverage())
        #expect(coverage.rows > 7_000, "8,816 on 2026-09-14")
        #expect(coverage.withAniListID > 6_000, "8,178 on 2026-09-14 — the main join leg")
        #expect(coverage.withMangaUpdatesID > 3_000, "4,001 on 2026-09-14")
        #expect(coverage.manga > 5_000, "7,218 on 2026-09-14")
        #expect(coverage.lightNovel > 700, "1,027 on 2026-09-14 — the bucket the shelf bug is about")
        // `await` hoisted: it cannot sit to the right of `==`.
        let rowCount = await table.rowCount()
        #expect(coverage.rows == rowCount)
        // Rows that fit none of the four formats should stay a rounding error.
        // 18 of 8,816 on 2026-09-14; a jump means a P31 value the generator's
        // census missed.
        #expect(coverage.other < coverage.rows / 100)
    }

    @Test("the export carries its own build date")
    func buildDateIsPresent() async throws {
        let built = try #require(await Self.table().builtDate())
        #expect(built.count == 10, "ISO date, e.g. 2026-09-14, got \(built)")
    }

    // MARK: - Structural guards

    /// Every sibling QID resolves to a real row. A dangling sibling would show
    /// the reader "this story also exists as …" and then have nothing to name,
    /// the same failure `TagTaxonomyTests.parentIdsResolve` guards against.
    @Test("every sibling reference in the whole table resolves to a row")
    func siblingsResolve() throws {
        let rows = try Self.rawRows()
        let present = Set(rows.compactMap { $0["q"] as? Int })
        let dangling = rows.flatMap { row -> [(Int, Int)] in
            guard let qid = row["q"] as? Int, let siblings = row["sb"] as? [Int] else { return [] }
            return siblings.filter { !present.contains($0) }.map { (qid, $0) }
        }
        // 0 of 2,293 rows with siblings on 2026-09-14. A dangling sibling would
        // show the reader "this story also exists as …" and have nothing to
        // name it with — the failure `TagTaxonomyTests.parentIdsResolve`
        // guards against on the taxonomy side.
        #expect(dangling.isEmpty, "dangling siblings: \(dangling.prefix(5))")
    }

    /// **This table is not a volume-date source and must never become one.**
    /// Measured 2026-09-14: Wikidata has per-volume dates for 171 of 18,202
    /// manga series and per-volume ISBNs for none of the five test series
    /// (`docs/sources/datasets.md` §2). Volume dates come from MangaBaka's own
    /// `/v1/series/{id}/works`.
    ///
    /// This reads the shipped bytes rather than the Swift type, because the
    /// way this goes wrong is somebody adding a date column to the generator
    /// and only later teaching the app to read it.
    @Test("no row carries a release date or an ISBN")
    func notAVolumeDateSource() throws {
        let document = try Self.rawDocument()
        #expect(document["notAVolumeDateSource"] != nil, "the file's own warning was removed")

        let rows = try #require(document["rows"] as? [[String: Any]])
        let keys = Set(rows.prefix(2_000).flatMap(\.keys))
        let known: Set<String> = ["q", "f", "ty", "mb", "al", "mu", "ml", "n", "en", "na", "nl", "sb"]
        let unexpected = keys.subtracting(known).sorted()
        #expect(
            unexpected.isEmpty,
            Comment(rawValue: "unexpected columns \(unexpected) — if one of these is a date "
                + "or an ISBN, read this test's doc comment before going further")
        )
    }

    @Test("the bundled resource stays well under the offline index it sits beside")
    func resourceStaysSmall() throws {
        let url = try #require(Self.resourceURL(), "not in the bundle, which means it would not ship")
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = try #require(attributes[.size] as? Int)
        // 451 KB on 2026-09-14, against OfflineIndex.json.gz's 1.5 MB and the
        // embeddings blob's 7.5 MB. The ceiling is a guard against the table
        // quietly growing a per-volume layer, not a measured limit.
        #expect(size < 1_000_000, "\(size) bytes")
    }

    /// A table whose `version` this reader does not understand must read as an
    /// empty table, not as rows whose fields mean something else — the bug
    /// `OfflineCatalogue` had to be fixed for (review F11).
    @Test("a resource that is not there reads as empty, not as a crash")
    func missingResourceIsEmpty() async {
        let table = WikidataIdentityTable(resourceName: "NoSuchTable", bundle: .main)
        #expect(await table.rowCount() == nil)
        #expect(await table.builtDate() == nil)
        #expect(await table.coverage() == nil)
        #expect(await table.identity(qid: 106_090_656) == nil)
    }

    /// The shipped bytes, read straight rather than through the decoder — the
    /// two tests below are about what is *in the file*, and a decoder that
    /// ignores an unknown column cannot see a column it ignores.
    private enum PackagingFailure: Error {
        /// The resource is not in any bundle, or does not decode — either way
        /// it would not ship, which is what these two tests are checking.
        case unreadable
    }

    private static func rawDocument() throws -> [String: Any] {
        guard let url = resourceURL() else { throw PackagingFailure.unreadable }
        let raw = try Gunzip.decompress(try Data(contentsOf: url))
        guard let document = try JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
            throw PackagingFailure.unreadable
        }
        return document
    }

    private static func rawRows() throws -> [[String: Any]] {
        guard let rows = try rawDocument()["rows"] as? [[String: Any]] else {
            throw PackagingFailure.unreadable
        }
        return rows
    }

    private static func resourceURL() -> URL? {
        Bundle(for: BundleMarker.self).url(forResource: "WikidataIdentity", withExtension: "json.gz")
            ?? Bundle.main.url(forResource: "WikidataIdentity", withExtension: "json.gz")
    }
}
