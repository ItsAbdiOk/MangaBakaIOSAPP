import Foundation
import os

/// A series as returned by the v2 endpoints.
///
/// Only fields the app currently uses are modelled. Swift's `Decodable`
/// ignores unknown keys, which matters here: the live API returns
/// `canonical_url`, which the published OpenAPI spec does not document
/// (verified 2026-09-08). The spec lags the API, so this type must never
/// assume the spec is exhaustive.
struct Series: Codable, Identifiable, Equatable, Sendable, Hashable {
    private static let logger = Logger(subsystem: "dev.abdirahmanmohamed.mangabaka", category: "decode")

    let id: Int
    /// "active", "merged" or "deleted".
    let state: String
    /// When `state == "merged"`, the ID that replaced this one. The API asks
    /// clients to update stored references to it.
    let mergedWith: Int?
    let titles: [SeriesTitle]?
    let cover: Cover
    let description: String?
    let authors: [String]?
    let artists: [String]?
    /// Publication status, e.g. "releasing", "completed".
    let status: String?
    /// 0-100, or `nil` when unrated.
    let rating: Double?
    let type: String?
    let contentRating: String?
    /// Chapters published so far, when known.
    let totalChapters: Double?
    /// The final volume number, when the series has ended.
    let finalVolume: Double?
    /// Who publishes it, and where. Objects rather than names: each carries a
    /// type ("Original", "English") and sometimes a note about volume counts.
    let publishers: [Publisher]?
    /// Whether an anime adaptation exists, and which chapters it covers.
    /// The mockup derived this from the rating; it is a real field.
    let anime: AnimeAdaptation?
    /// The same fact, from a different shape. `/v2/series/{id}` sends
    /// `anime: {exists: true, start, end}` and no sibling `has_anime`;
    /// `/v1/series/{id}` sends `anime: {start, end}` — no `exists` key at
    /// all — plus a top-level `has_anime: true`. Both captured live against
    /// series 3397 on 2026-09-13. `AnimeAdaptation.exists` alone answers
    /// "no" for every v1 payload, which is every library entry's fill
    /// (`SeriesRepository.swift:683`, `filling(gapsFrom:)` below). See
    /// `hasAnimeAdaptation`.
    let hasAnime: Bool?
    /// The same series on other trackers, with their ratings. Also real —
    /// the mockup faked these as arithmetic offsets from the base rating.
    let source: [String: TrackerEntry]?
    /// First publication year. Present on the v1 endpoints; the v2 lean schema
    /// returns null for it even with `schema=full` (verified 2026-09-09).
    let year: Int?
    /// How many people rated it. The reverse of `year`: present on v2, absent
    /// on v1. Neither endpoint carries both, so the meta line renders whichever
    /// parts it actually has rather than waiting for a complete set.
    let ratingCount: Int?
    /// Tag names, flattened.
    ///
    /// Three shapes across the API: v1 returns an array of plain strings, v2
    /// with `schema=full` returns an array of objects, and the v2 lean schema
    /// omits them. Normalised to names here so a caller does not care which it
    /// was handed.
    let tags: [String]?
    /// `tags_v2`. Everything a tag list needs to be readable rather than a
    /// wall: group, weight, spoiler flag, and what implied what.
    ///
    /// Named for the wire, not for the app: `Series` decodes with
    /// `convertFromSnakeCase` and has no explicit `CodingKeys`, so the property
    /// name is the contract. `richTags` reads it.
    let tagsV2: [SeriesTag]?

    struct Publisher: Codable, Equatable, Sendable, Hashable {
        let name: String
        /// "Original", "English", and similar.
        let type: String?
        /// Free text, often a volume count or completion note.
        let note: String?
    }

    struct AnimeAdaptation: Codable, Equatable, Sendable, Hashable {
        let exists: Bool?
        /// Where the adaptation starts in the manga, as free text.
        let start: String?
        let end: String?
    }

    struct TrackerEntry: Codable, Equatable, Sendable, Hashable {
        /// The tracker's own id, kept as a string.
        ///
        /// It arrives as a string on some trackers and a number on others
        /// (`anime_planet` sends "tsukihime", `anilist` sends 30705), so it is
        /// decoded leniently and normalised to a string. Modelling it as either
        /// concrete type fails on whichever shape was not anticipated — the
        /// same v1/v2 trap that has cost this app three silent decode failures.
        let id: String?
        let rating: Double?
        /// Every tracker uses a different scale; this one is 0-100 throughout,
        /// which is the only way to compare them honestly.
        let ratingNormalized: Double?
    }

    /// Decoded by hand for one reason: three numeric fields come back as
    /// strings on the v1 endpoints and as numbers on v2.
    ///
    /// `/v1/my/library` sends `"total_chapters": "87"`; `/v2/series/{id}` sends
    /// `"total_chapters": 87`. Verified against both on 2026-09-09. The
    /// synthesised decoder throws on whichever shape it was not written for,
    /// and because the library call swallows errors with `try?`, the whole
    /// response silently became an empty list.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        state = try container.decode(String.self, forKey: .state)
        mergedWith = try container.decodeIfPresent(Int.self, forKey: .mergedWith)
        titles = try container.decodeIfPresent([SeriesTitle].self, forKey: .titles)
        cover = try container.decode(Cover.self, forKey: .cover)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        authors = try container.decodeIfPresent([String].self, forKey: .authors)
        artists = try container.decodeIfPresent([String].self, forKey: .artists)
        status = try container.decodeIfPresent(String.self, forKey: .status)
        type = try container.decodeIfPresent(String.self, forKey: .type)
        contentRating = try container.decodeIfPresent(String.self, forKey: .contentRating)
        publishers = try container.decodeIfPresent([Publisher].self, forKey: .publishers)
        anime = try container.decodeIfPresent(AnimeAdaptation.self, forKey: .anime)
        hasAnime = try container.decodeIfPresent(Bool.self, forKey: .hasAnime)
        source = try container.decodeIfPresent([String: TrackerEntry].self, forKey: .source)

        rating = container.lenientDouble(forKey: .rating)
        totalChapters = container.lenientDouble(forKey: .totalChapters)
        finalVolume = container.lenientDouble(forKey: .finalVolume)
        // `Int(_: Double)` traps on anything outside Int's range — a
        // server-controlled `"year": "inf"` or `"rating_count": 1e19` would
        // crash the feed page it appears on for every reader. `Int(exactly:)`
        // returns nil instead, which the model already treats as "unknown".
        year = container.lenientDouble(forKey: .year).flatMap { Int(exactly: $0) }
        ratingCount = container.lenientDouble(forKey: .ratingCount).flatMap { Int(exactly: $0) }
        tags = container.lenientTagNames(forKey: .tags)
        // Absent on v2 entirely, and on any v1 payload that predates it. A
        // series with no rich tags falls back to the flat names.
        //
        // `LossyArray`, not a bespoke lenient decode: element by element, so
        // one malformed tag costs one tag rather than the whole array — a
        // single array under `try?` once let one null name empty all 146 of
        // Solo Leveling's, and the flat fallback list hid that the rich ones
        // had gone. The bespoke version (`lenientElements`) did the same
        // per-element skip but never counted what it dropped, so the exact
        // failure `LossyArray`'s own comment says it exists to prevent — a
        // `tags_v2` shape change going unnoticed — was invisible here. Logged
        // the same way `SeriesRepository+Paging.swift`'s search page does.
        let tagsV2Decode = try container.decodeIfPresent(LossyArray<SeriesTag>.self, forKey: .tagsV2)
        // `id` copied to a local first: interpolating a property of a
        // still-initialising `self` into an autoclosing log message captures
        // `self` in an escaping autoclosure, which a mutating initialiser
        // cannot do.
        let decodedID = id
        if let dropped = tagsV2Decode?.dropped, dropped > 0 {
            Self.logger.error(
                "tags_v2 dropped \(dropped, privacy: .public) rows for series \(decodedID, privacy: .public)"
            )
        }
        tagsV2 = tagsV2Decode?.elements
    }

    /// Memberwise, because the custom `init(from:)` replaces the synthesised
    /// one and the test factory builds series directly.
    init(
        id: Int, state: String, mergedWith: Int?, titles: [SeriesTitle]?, cover: Cover,
        description: String?, authors: [String]?, artists: [String]?, status: String?,
        rating: Double?, type: String?, contentRating: String?, totalChapters: Double?,
        finalVolume: Double?, publishers: [Publisher]?, anime: AnimeAdaptation?,
        source: [String: TrackerEntry]?,
        year: Int? = nil,
        ratingCount: Int? = nil,
        tags: [String]? = nil,
        tagsV2: [SeriesTag]? = nil,
        hasAnime: Bool? = nil
    ) {
        self.id = id
        self.state = state
        self.mergedWith = mergedWith
        self.titles = titles
        self.cover = cover
        self.description = description
        self.authors = authors
        self.artists = artists
        self.status = status
        self.rating = rating
        self.type = type
        self.contentRating = contentRating
        self.totalChapters = totalChapters
        self.finalVolume = finalVolume
        self.publishers = publishers
        self.anime = anime
        self.hasAnime = hasAnime
        self.source = source
        self.year = year
        self.ratingCount = ratingCount
        self.tags = tags
        self.tagsV2 = tagsV2
    }

    /// The rich tags, or none. See `tagsV2`.
    var richTags: [SeriesTag] { tagsV2 ?? [] }

    /// The same series carrying tags it did not arrive with.
    ///
    /// A feed's copy of a series has no `tags_v2` — v2 omits them entirely —
    /// and the series page fetches them separately. This puts the two back
    /// together so the taste profile can count what the reader is actually
    /// looking at.
    func withTags(_ tags: [SeriesTag]) -> Series {
        Series(
            id: id, state: state, mergedWith: mergedWith, titles: titles,
            cover: cover, description: description, authors: authors, artists: artists,
            status: status, rating: rating, type: type, contentRating: contentRating,
            totalChapters: totalChapters, finalVolume: finalVolume,
            publishers: publishers, anime: anime, source: source, year: year,
            ratingCount: ratingCount, tags: self.tags, tagsV2: tags, hasAnime: hasAnime
        )
    }

    /// This series with its gaps filled from a fuller copy of the same series.
    ///
    /// Field by field, and only where this copy has nothing: the copy the
    /// reader is looking at wins wherever it has an answer, so nothing on
    /// screen changes under them when the fuller one arrives. Same id only —
    /// merging two different series would be a silent data corruption, so a
    /// mismatch returns this one untouched.
    func filling(gapsFrom other: Series) -> Series {
        guard other.id == id else { return self }
        return Series(
            id: id,
            state: state,
            mergedWith: mergedWith ?? other.mergedWith,
            titles: (titles?.isEmpty == false) ? titles : other.titles,
            cover: cover.raw == nil && cover.x350 == nil ? other.cover : cover,
            description: description ?? other.description,
            authors: (authors?.isEmpty == false) ? authors : other.authors,
            artists: (artists?.isEmpty == false) ? artists : other.artists,
            status: status ?? other.status,
            rating: rating ?? other.rating,
            type: type ?? other.type,
            contentRating: contentRating ?? other.contentRating,
            totalChapters: totalChapters ?? other.totalChapters,
            finalVolume: finalVolume ?? other.finalVolume,
            publishers: (publishers?.isEmpty == false) ? publishers : other.publishers,
            anime: anime ?? other.anime,
            source: (source?.isEmpty == false) ? source : other.source,
            year: year ?? other.year,
            ratingCount: ratingCount ?? other.ratingCount,
            tags: (tags?.isEmpty == false) ? tags : other.tags,
            tagsV2: (tagsV2?.isEmpty == false) ? tagsV2 : other.tagsV2,
            hasAnime: hasAnime ?? other.hasAnime
        )
    }

    /// The title to show, chosen by `DisplayTitle`. `nil` when the series
    /// carries no titles at all, which the schema permits.
    var displayTitle: String? {
        DisplayTitle.choose(from: titles)
    }

    /// Whether an anime adaptation exists, reconciling the two shapes the
    /// wire sends this fact in.
    ///
    /// `/v2/series/{id}` (schema=full): `anime: {exists: true, start, end}`,
    /// no `has_anime`. `/v1/series/{id}` — the endpoint that fills every
    /// library entry's gaps, `SeriesRepository.swift:683` — sends
    /// `anime: {start, end}` with **no `exists` key** at all, plus a
    /// top-level `has_anime: true`. Both captured live against series 3397,
    /// 2026-09-13. Reading `anime?.exists` alone answered "None listed" for
    /// a series with two anime seasons, on the v1 shape every library entry
    /// gets. `anime?.start != nil` is a last resort for a payload that gives
    /// neither flag but does give a start chapter.
    var hasAnimeAdaptation: Bool {
        anime?.exists == true || hasAnime == true || anime?.start != nil
    }

    /// MangaUpdates' id for this series, if it has one. Base-36, and it must be
    /// decoded before use — see `MangaUpdatesID`.
    var mangaUpdatesID: String? {
        source?["manga_updates"]?.id
    }

    /// The language the series was originally published in, if its titles say.
    ///
    /// Taken from the title marked "native" rather than from a field, because
    /// there is no field: MangaBaka records the language per title, and the
    /// native one is the only reliable statement about the work's own language.
    /// `-Latn` is excluded on purpose, the same rule `DisplayTitle.original`
    /// applies: a romanisation is a reading of the native title, not the
    /// native language itself. Solo Leveling (3397) carries `ko`, `ko-Latn`,
    /// `ja-Latn` and `ja` titles, all tagged `native`, and the API's order is
    /// not documented as stable (`DisplayTitle.swift`'s series-638 finding
    /// already caught it changing once) — if a `ko-Latn native` title ever
    /// sorts first, first-match here used to answer "ko-latn", which then
    /// narrowed `coverLanguages` to `["en", "ko-latn"]` and dropped every
    /// Korean cover, since `hasPrefix` never matches a `-latn` tag against a
    /// bare `ko`.
    var nativeLanguage: String? {
        titles?.first { $0.traits.contains("native") && !$0.language.hasSuffix("-Latn") }?.language
    }

    /// The language a series was originally published in, inferred from its
    /// type when the titles do not say.
    ///
    /// `nativeLanguage` reads the title marked "native", which is the better
    /// answer because it is the series' own data — but plenty of series carry
    /// no native title at all, and a reader still knows perfectly well that a
    /// manhwa is Korean. Only the three types whose language is actually
    /// implied by the word are listed: "oel" is English-original by
    /// definition and "other" says nothing, so both stay nil.
    var impliedLanguage: String? {
        switch type?.lowercased() {
        case "manga": "ja"
        case "manhwa": "ko"
        case "manhua": "zh"
        default: nil
        }
    }

    /// The cover languages worth showing on the series page: English, and the
    /// language the series was drawn in. Nil means show everything.
    ///
    /// Asked for by Abdi (2026-09-12) — the fan at the top of a series page
    /// was showing every edition MangaBaka holds, so a popular series led with
    /// a wall of covers a reader here cannot read. English is the edition most
    /// readers of this app recognise from a shop; the native one is the cover
    /// the book actually had.
    ///
    /// Measured against the live API on 2026-09-12: Solo Leveling (3397) has
    /// 24 covers on `/v1/series/3397/images` — 10 English, 4 Korean, 7 "pt"
    /// and 3 "pt-br". This rule keeps 14 and drops 10, so well over a third of
    /// that fan was Portuguese.
    ///
    /// Novels are exempt, at his ask: they are the type whose editions are
    /// most often the only art there is, so narrowing them risks leaving a
    /// page with nothing to show.
    var coverLanguages: Set<String>? {
        guard type?.lowercased() != "novel" else { return nil }
        guard let own = nativeLanguage ?? impliedLanguage else { return nil }
        return ["en", own.lowercased()]
    }

    /// Whether this series answers to a name the reader typed.
    ///
    /// Every title the series carries, not just the displayed one. A library
    /// search that only matched `displayTitle` could not find a series by the
    /// name the reader actually knows it by — the Korean title, the official
    /// English one, an alternative romanisation — which on a 937-entry library
    /// is the difference between a search and a guess. Authors count too: "show
    /// me everything by this artist" is a real question about your own shelf.
    func matches(_ needle: String) -> Bool {
        let trimmed = needle.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return true }
        if titles?.contains(where: { $0.title.localizedCaseInsensitiveContains(trimmed) }) == true {
            return true
        }
        return authors?.contains { $0.localizedCaseInsensitiveContains(trimmed) } == true
    }

    /// A series whose `state` is "merged" or "deleted" should not be shown in
    /// discovery surfaces; it exists only so stored references can be updated.
    var isDiscoverable: Bool {
        state == "active"
    }
}

private struct NamedTag: Decodable { let name: String? }

private extension KeyedDecodingContainer {
    func lenientTagNames(forKey key: Key) -> [String]? {
        if let names = try? decodeIfPresent([String].self, forKey: key) { return names }
        if let objects = try? decodeIfPresent([NamedTag].self, forKey: key) {
            return objects.compactMap(\.name)
        }
        // The lean v2 schema sends a placeholder string rather than a list.
        return nil
    }

    /// A number the API sends as a number on one endpoint and as a string on
    /// another. Returns nil rather than throwing: an unparsable value means the
    /// field is unknown, which the model already allows for, and throwing here
    /// would discard the entire series over one optional field.
    func lenientDouble(forKey key: Key) -> Double? {
        if let value = try? decodeIfPresent(Double.self, forKey: key) {
            return value.isFinite ? value : nil
        }
        guard let text = try? decodeIfPresent(String.self, forKey: key) else { return nil }
        // `Double("inf")`, `Double("-inf")` and `Double("nan")` all succeed,
        // and a caller turning this into an `Int` would trap on them (see
        // `year`/`ratingCount` above). An unparsable-as-finite value is
        // exactly as unknown as one that fails `Double(text)` outright.
        guard let value = Double(text), value.isFinite else { return nil }
        return value
    }
}

extension Series.TrackerEntry {
    private enum CodingKeys: String, CodingKey { case id, rating, ratingNormalized }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // String on some trackers, number on others. Normalised rather than
        // insisted upon.
        if let text = try? container.decodeIfPresent(String.self, forKey: .id) {
            id = text
        } else if let number = try? container.decodeIfPresent(Int.self, forKey: .id) {
            id = String(number)
        } else {
            id = nil
        }
        rating = try container.decodeIfPresent(Double.self, forKey: .rating)
        ratingNormalized = try container.decodeIfPresent(Double.self, forKey: .ratingNormalized)
    }
}
