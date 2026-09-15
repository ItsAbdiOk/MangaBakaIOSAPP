import Foundation

/// The onward paths from a series. Every field is independently optional: a
/// series with no news is ordinary, and one failing endpoint must not empty
/// the rest of the screen.
struct SeriesExtras: Sendable, Equatable, Codable {
    var links: [SeriesLink] = []
    var news: [NewsItem] = []
    var relationships: [SeriesRelationship] = []
    /// Tags, and a year, from `/v1/series/{id}`.
    ///
    /// Measured against the live API on 2026-09-09: v2 returns neither, on the
    /// feed endpoints *or* on `/v2/series/{id}` — its keys are identical in
    /// both, and `tags` and `year` are not among them. v1 carries `tags`,
    /// `genres` and `year`. So the series page's tag row and its "Started"
    /// stat are only ever populated from v1, and a series page built from a
    /// feed's own copy shows neither.
    var tags: [String] = []
    /// The same tags with their group, weight, spoiler flag and implications —
    /// see `SeriesTag`. v1's flat `tags` is kept only as a fallback for a
    /// series whose payload has no `tags_v2`.
    var richTags: [SeriesTag] = []
    /// Published editions — see `SeriesEdition`.
    var editions: [SeriesEdition] = []
    /// Published volumes, with every edition of each gathered onto one — see
    /// `SeriesWork.Volume`.
    var volumes: [SeriesWork.Volume] = []
    /// How many printings `/works` holds for the series, against however
    /// many `volumes` was built from — see `SeriesRepository.fetchWorks`.
    /// Nil on a row cached before this existed.
    var worksTotal: Int?
    var year: Int?
    /// The whole v1 series, not just the two fields above.
    ///
    /// A series page is built from whatever copy of the series the reader
    /// arrived with, and those copies are not equal. The swipe stack's queue
    /// carries v2 payloads, which have no description, no chapter count, no
    /// status and no `source` — so "More info" from the stack showed a page
    /// with no synopsis, no length, and no next-chapter estimate, because the
    /// estimate needs the MangaUpdates id that lives in `source`. The v1 series
    /// was already being fetched here for its tags; everything else it carried
    /// was thrown away. Kept now, and merged in by `Series.filling(gapsFrom:)`.
    var full: Series?
    /// Set when at least one of the six concurrent legs `fetchExtras` runs
    /// failed — cancellation excluded, since nobody left waiting on this
    /// answer needs to be told it didn't finish (`APIError.cancelled`).
    ///
    /// Excluded from `Codable` on purpose: `extras(for:)` refuses to persist a
    /// result this is set on (gap 9), so a cached row never actually carries
    /// one, and giving `APIError` a `Codable` conformance it does not
    /// otherwise need — just so a value nothing writes to disk can round-trip
    /// through JSON — is not worth doing.
    var failure: APIError?
    /// The below-the-fold legs that did not answer when this row was
    /// fetched, so a cached partial answer knows what to ask for again.
    /// Empty for a whole answer and for every row cached before 2026-09-15
    /// (review perf PS "missing 2": five good legs and one 429 used to be
    /// thrown away, and the re-open paid all eight again — a throttle made
    /// the next throttle likelier).
    var missingLegs: Set<Leg> = []

    enum Leg: String, Codable, Sendable {
        case news, relationships, editions, worksLastPage
        /// A hero leg. A row missing this is never cached — `volumes` would
        /// read as "none" for six hours — so it only ever appears on a fresh
        /// answer, to say why the shelf is empty.
        case worksFirstPage
    }

    /// Whether this answer may be written to the detail cache: the record
    /// itself arrived, and so did the first works page.
    var isCacheable: Bool { full != nil && !missingLegs.contains(.worksFirstPage) }

    enum CodingKeys: String, CodingKey {
        case links, news, relationships, tags, richTags, editions, volumes, worksTotal, year, full
        case missingLegs
    }

    /// `missingLegs` is optional on the wire so a row written before the key
    /// existed still decodes (review perf PS3's shape, applied here).
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        links = try container.decodeIfPresent([SeriesLink].self, forKey: .links) ?? []
        news = try container.decodeIfPresent([NewsItem].self, forKey: .news) ?? []
        relationships = try container.decodeIfPresent([SeriesRelationship].self, forKey: .relationships) ?? []
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        richTags = try container.decodeIfPresent([SeriesTag].self, forKey: .richTags) ?? []
        editions = try container.decodeIfPresent([SeriesEdition].self, forKey: .editions) ?? []
        volumes = try container.decodeIfPresent([SeriesWork.Volume].self, forKey: .volumes) ?? []
        worksTotal = try container.decodeIfPresent(Int.self, forKey: .worksTotal)
        year = try container.decodeIfPresent(Int.self, forKey: .year)
        full = try container.decodeIfPresent(Series.self, forKey: .full)
        missingLegs = try container.decodeIfPresent(Set<Leg>.self, forKey: .missingLegs) ?? []
    }

    init(
        links: [SeriesLink] = [], news: [NewsItem] = [], relationships: [SeriesRelationship] = [],
        tags: [String] = [], richTags: [SeriesTag] = [], editions: [SeriesEdition] = [],
        volumes: [SeriesWork.Volume] = [], worksTotal: Int? = nil, year: Int? = nil,
        full: Series? = nil, failure: APIError? = nil, missingLegs: Set<Leg> = []
    ) {
        self.links = links
        self.news = news
        self.relationships = relationships
        self.tags = tags
        self.richTags = richTags
        self.editions = editions
        self.volumes = volumes
        self.worksTotal = worksTotal
        self.year = year
        self.full = full
        self.failure = failure
        self.missingLegs = missingLegs
    }
}
