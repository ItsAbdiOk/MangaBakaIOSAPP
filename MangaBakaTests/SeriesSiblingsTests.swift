import Testing
import Foundation
@testable import MangaBaka

/// `SeriesSiblingRow.rows(for:)` — the derivation behind "Also exists as"
/// (`SeriesSiblingsSection`) — against a fixture first, then against the real
/// bundled Wikidata table the way `WikidataIdentityTests` exercises it.
@Suite("Series siblings")
struct SeriesSiblingsTests {
    // MARK: - Row derivation, against a fixture

    /// Expected to fail before `SeriesSiblingRow` existed with:
    /// `Cannot find 'SeriesSiblingRow' in scope` — there was no row type or
    /// derivation to call. With `.other` not skipped it fails on
    /// `#expect(rows.count == 2)` (three rows, not two); with the title
    /// fallback wrong it fails on the light novel's `#expect(rows[1].title
    /// == "薬屋のひとりごと")`.
    @Test("maps manga and light novel, skips .other, keeps a sibling with no MangaBaka id")
    func rowsFromFixture() throws {
        let manga = try Self.identity(
            qid: 1, format: "manga", mangaBakaID: 222, englishTitle: "The Apothecary Diaries"
        )
        // No English title on file — the row must fall back to the native
        // one, never a romanisation.
        let lightNovel = try Self.identity(
            qid: 2, format: "lightNovel", nativeTitle: "薬屋のひとりごと"
        )
        // Wikidata knows this item and calls it neither manga nor prose (an
        // anime adaptation, say) — must not produce a row at all.
        let other = try Self.identity(qid: 3, format: "other", englishTitle: "Some Anime")

        let rows = SeriesSiblingRow.rows(for: [manga, lightNovel, other])

        #expect(rows.count == 2, "`.other` must be skipped")

        #expect(rows[0].formatLabel == "Manga")
        #expect(rows[0].title == "The Apothecary Diaries")
        #expect(rows[0].mangaBakaID == 222)

        #expect(rows[1].formatLabel == "Light novel")
        #expect(rows[1].title == "薬屋のひとりごと")
        #expect(
            rows[1].mangaBakaID == nil,
            "an AniList/MangaUpdates-only sibling must still render as a row, just captioned"
        )
    }

    /// The two rows a sim walk showed in romaji on 2026-09-14, from the real
    /// table: Q106090657 and Q133462142. Fails before `displayTitle` with the
    /// first expectation reading the "Kusuriya no Hitorigoto…" label.
    @Test("a romanised English label gives way to the native title")
    func romanisationFallsBackToNative() throws {
        let romanised = try Self.identity(
            qid: 106_090_657, format: "manga",
            englishTitle: "Kusuriya no Hitorigoto: Mao Mao no Kōkyū Nazotoki Techō",
            nativeTitle: "薬屋のひとりごと～猫猫の後宮謎解き手帳～"
        )
        let english = try Self.identity(
            qid: 48_751_907, format: "lightNovel",
            englishTitle: "The Apothecary Diaries", nativeTitle: "薬屋のひとりごと"
        )
        let rows = SeriesSiblingRow.rows(for: [romanised, english])
        #expect(rows[0].title == "薬屋のひとりごと～猫猫の後宮謎解き手帳～")
        #expect(rows[1].title == "The Apothecary Diaries")
        #expect(SeriesSiblingRow.isRomanisation("Xiaolan Kaisōroku"))
        #expect(!SeriesSiblingRow.isRomanisation("Delicious in Dungeon"))
    }

    /// The `.other` bucket alone, so a regression that stops skipping it
    /// fails here even if `rowsFromFixture`'s count assertion were loosened
    /// later.
    @Test(".other never becomes a row")
    func otherIsAlwaysSkipped() throws {
        let other = try Self.identity(qid: 4, format: "other", englishTitle: "A Film")
        #expect(SeriesSiblingRow.rows(for: [other]).isEmpty)
    }

    /// A sibling with neither an English nor a native title has nothing to
    /// show and must not become a blank row.
    @Test("a sibling with no title of any kind is dropped")
    func titlelessSiblingIsDropped() throws {
        let untitled = try Self.identity(qid: 5, format: "manga")
        #expect(SeriesSiblingRow.rows(for: [untitled]).isEmpty)
    }

    // MARK: - Against the real bundled table

    /// The Apothecary Diaries, the same series `WikidataIdentityTests`
    /// exercises: manga (MangaBaka id 222), light novel and novel siblings.
    ///
    /// Expected to fail before `WikidataIdentityTable.siblings(for:)` was
    /// wired to `SeriesSiblingRow.rows(for:)` with: `Cannot find
    /// 'SeriesSiblingRow' in scope`, the same as the fixture test above — this
    /// one additionally proves the real table's `format` values decode to the
    /// labels this file expects, which a fixture alone cannot.
    @Test("The Apothecary Diaries' manga page lists the light novel and the novel, not itself")
    func apothecarySiblingsRow() async throws {
        let table = Self.table()
        let series = SeriesFactory.make(id: 222, title: "The Apothecary Diaries")
        let siblings = await table.siblings(for: series)
        let rows = SeriesSiblingRow.rows(for: siblings)

        #expect(rows.contains { $0.formatLabel == "Light novel" })
        #expect(rows.contains { $0.formatLabel == "Novel" })
        #expect(!rows.contains { $0.mangaBakaID == 222 }, "must not list the manga page itself")
    }

    // MARK: - Fixtures

    private final class BundleMarker {}

    /// The bundled resource, found in the test bundle when the resource is
    /// copied there and in `Bundle.main` otherwise — the same two-step
    /// `WikidataIdentityTests.table()` uses.
    private static func table() -> WikidataIdentityTable {
        let testBundle = Bundle(for: BundleMarker.self)
        let hasResource = testBundle.url(
            forResource: "WikidataIdentity", withExtension: "json.gz"
        ) != nil
        return WikidataIdentityTable(bundle: hasResource ? testBundle : .main)
    }

    /// Builds one `WikidataIdentity` row by decoding the export's own wire
    /// shape, since the type has no memberwise initialiser — only
    /// `init(from:)`, decoded off `CodingKeys`' single-letter keys (`q`, `f`,
    /// `mb`, `en`, `na`, …). Mirrors how `WikidataIdentityTable.load()`
    /// itself decodes every row.
    private static func identity(
        qid: Int, format: String, mangaBakaID: Int? = nil,
        englishTitle: String? = nil, nativeTitle: String? = nil
    ) throws -> WikidataIdentity {
        var wire: [String: Any] = ["q": qid, "f": format]
        // Subscript-assigning an `Int?`/`String?` straight into a `[String:
        // Any]` dictionary wraps a `nil` as `Any.some(.none)` instead of
        // omitting the key — the classic Swift optional-into-Any pitfall —
        // so each field is added only `if let`.
        if let mangaBakaID { wire["mb"] = mangaBakaID }
        if let englishTitle { wire["en"] = englishTitle }
        if let nativeTitle { wire["na"] = nativeTitle }
        let data = try JSONSerialization.data(withJSONObject: wire)
        return try JSONDecoder().decode(WikidataIdentity.self, from: data)
    }
}
