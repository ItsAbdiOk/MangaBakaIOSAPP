import Foundation

/// What kind of work a series is, as Wikidata's `P31` (instance of) says.
///
/// This is the field the app has been missing. The Apothecary Diaries is three
/// separately typed Wikidata items — `Q106090656` the manga series,
/// `Q48751907` the light novel series, `Q106090452` the novel series — so the
/// answer comes from a structured statement rather than from guessing at a
/// title suffix. Measured 2026-09-14: Open Library's `form:` subject tags, the
/// only other candidate, were absent on 21 of 37 Apothecary docs and on every
/// Solo Leveling doc sampled (`docs/sources/bibliographic.md`).
enum WikidataFormat: String, Sendable, Codable, CaseIterable {
    case manga
    case lightNovel
    case novel
    /// Webtoon, manhwa and webcomic collapse here. What the volumes shelf
    /// needs to know is "this never had a print run", not the country of
    /// origin, and the app's library is majority manhwa
    /// (`docs/sources/datasets.md` §6).
    case webtoon
    /// Wikidata knows the item and does not call it any of the above — an
    /// anime series, a film, a video game. Deliberately distinct from "not in
    /// the table at all", which is `nil`: one is an answer, the other is
    /// silence.
    case other

    /// Whether a shelf of comics should be willing to show this.
    ///
    /// The bug this table exists to prevent: an untagged light novel filling a
    /// comic shelf. `other` is excluded too — a video game is not a comic
    /// either.
    var isComic: Bool { self == .manga || self == .webtoon }

    /// Whether this is prose, i.e. the thing a comic shelf must not show.
    var isProse: Bool { self == .lightNovel || self == .novel }
}

/// One row of the bundled Wikidata identity table: a work, what format it is,
/// its English and original-language titles, and the other formats of the same
/// story.
///
/// **This carries no volume release dates and never will.** Measured
/// 2026-09-14: Wikidata has per-volume dates for 171 of 18,202 manga series
/// (under 1 %) and per-volume ISBNs for none of the five test series. Volume
/// dates come from MangaBaka's own `/v1/series/{id}/works`, which returned a
/// date and an ISBN on 100 % of works for 5 of 5 test series. If you are here
/// looking for a release date, you are in the wrong file — see
/// `docs/sources/datasets.md` §2, which records the query that killed the idea.
struct WikidataIdentity: Sendable, Equatable, Decodable {
    /// The numeric part of the QID: 106090656 for `Q106090656`. Stored as an
    /// integer because the "Q" is the same 9,000 times over.
    let qid: Int
    let format: WikidataFormat
    /// The raw `P31` value, e.g. `Q74262765` ("manhwa series"). Kept so a
    /// caller can see the distinction `format` flattened away, and so a
    /// mis-bucketed type is diagnosable without re-running the generator.
    let typeQID: String?

    // The join keys. MangaBaka's `/v1/series/{id}` hands back AniList and
    // MangaUpdates ids in its `source` object, so every join here is on an
    // exact id — there is no title matching anywhere in this file, which is
    // the only reason the table can be trusted at all.
    let mangaBakaID: Int?
    let aniListID: Int?
    /// MangaUpdates' base-36 id, as a string — the same shape
    /// `Series.mangaUpdatesID` carries.
    let mangaUpdatesID: String?
    let myAnimeListID: Int?

    /// Wikidata's `P2635` (number of parts). A total, not a list, and often
    /// stale for an ongoing series. Present for roughly a quarter of rows.
    let volumeCount: Int?

    /// The English title.
    let englishTitle: String?
    /// The title in the work's own original language, chosen by `P407`
    /// (language of work) rather than by whichever label happens to exist —
    /// an item can carry a Japanese label for a Korean work, and many do.
    let nativeTitle: String?
    /// `"ja"`, `"ko"` or `"zh"`. Nil when the work's original language is
    /// English or something the table does not carry a title for.
    let nativeLanguage: String?

    /// Every other work in the same adaptation component: the light novel this
    /// manga is based on, the manga that novel became. Transitive, because the
    /// Apothecary manga's only direct edge is to the light novel and the novel
    /// is one hop further out.
    let siblingQIDs: [Int]

    /// The export's single-letter keys. 9,000-odd rows means every repeated
    /// key name costs real bytes, gzipped or not — the same reasoning
    /// `OfflineIndexEntry` records.
    private enum CodingKeys: String, CodingKey {
        case qid = "q", format = "f", typeQID = "ty", mangaBakaID = "mb"
        case aniListID = "al", mangaUpdatesID = "mu", myAnimeListID = "ml"
        case volumeCount = "n", englishTitle = "en", nativeTitle = "na"
        case nativeLanguage = "nl", siblingQIDs = "sb"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        qid = try container.decode(Int.self, forKey: .qid)
        // An unknown bucket decodes to `.other` rather than throwing. A
        // generator that learns a new P31 value must not be able to make the
        // whole table unreadable on an old build.
        let rawFormat = try container.decode(String.self, forKey: .format)
        format = WikidataFormat(rawValue: rawFormat) ?? .other
        typeQID = try container.decodeIfPresent(String.self, forKey: .typeQID)
        mangaBakaID = try container.decodeIfPresent(Int.self, forKey: .mangaBakaID)
        aniListID = try container.decodeIfPresent(Int.self, forKey: .aniListID)
        mangaUpdatesID = try container.decodeIfPresent(String.self, forKey: .mangaUpdatesID)
        myAnimeListID = try container.decodeIfPresent(Int.self, forKey: .myAnimeListID)
        volumeCount = try container.decodeIfPresent(Int.self, forKey: .volumeCount)
        englishTitle = try container.decodeIfPresent(String.self, forKey: .englishTitle)
        nativeTitle = try container.decodeIfPresent(String.self, forKey: .nativeTitle)
        nativeLanguage = try container.decodeIfPresent(String.self, forKey: .nativeLanguage)
        siblingQIDs = try container.decodeIfPresent([Int].self, forKey: .siblingQIDs) ?? []
    }
}

/// The counts the generator measured at build time and wrote into the file.
///
/// Shipped deliberately rather than recomputed: the point of this table is
/// that the code reading it knows how far it reaches. A table that matches 30 %
/// is useful when the caller knows it is 30 %; one that implies it matches
/// everything is the failure this project keeps finding.
struct WikidataCoverage: Sendable, Equatable, Decodable {
    let rows: Int
    let withMangaBakaID: Int
    let withAniListID: Int
    let withMangaUpdatesID: Int
    let withSiblings: Int
    let withEnglishTitle: Int
    let withNativeTitle: Int
    let manga: Int
    let lightNovel: Int
    let novel: Int
    let webtoon: Int
    let other: Int
}
