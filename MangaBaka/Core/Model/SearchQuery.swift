import Foundation

/// A search or filter request. Only non-nil fields are sent, so an untouched
/// filter never narrows the results by accident.
struct SearchQuery: Sendable, Equatable, Codable {
    var text: String?
    /// manga, novel, manhwa, manhua, oel, other
    var types: [String] = []
    /// releasing, completed, hiatus, cancelled, upcoming, unknown
    var statuses: [String] = []
    /// One of the API's 20 sort orders.
    var sort: String?
    /// Genre values as the API's 46-entry vocabulary spells them
    /// (`slice_of_life`, `romance`). A separate key from `tags` on purpose:
    /// measured 2026-09-13, `tag=slice_of_life` answers 2,017 and
    /// `genre=slice_of_life` 34,220; `tag=romance` 14,065 against
    /// `genre=romance` 100,947. Sent as a genre a tag finds 6-14% of it.
    var genres: [String] = []
    /// Tag names to require. The API takes repeated `tag` keys plus a
    /// `tag_mode` saying whether they are ANDed or ORed.
    var tags: [String] = []
    /// Kept for saved lenses and the offline path, but the wire only ever
    /// says `and`. Measured 2026-09-13: `tag=Isekai&tag=Regression` answers
    /// 164 with no mode, with `tag_mode=or` and with `tag_mode=and`
    /// (`tag=isekai` alone is 7,116, so a working OR would be far larger);
    /// `/v1/series/mix` with the same two tags returns the same 50 ids with
    /// and without `tag_mode=or`. Sending `or` would make a request claim
    /// something the API does not do.
    var tagMode: String?
    /// 0-100 as the API expresses it.
    var minimumRating: Int?
    /// First-publication-year range, inclusive on both ends when set.
    ///
    /// Sent as `published_start_date_lower` / `_upper`, which the schema
    /// says accept a bare `YYYY`. Confirmed live 2026-09-13 against
    /// `/v2/series/search`: `type=manhwa` answers 21,596; the same with
    /// `published_start_date_lower=2020&published_start_date_upper=2020`
    /// answers 1,527. Before that check the fields were offline-only and
    /// the Filters sheet counted a year as active without ever sending it.
    var yearFrom: Int?
    var yearTo: Int?
    /// Pins a `random` sort so page 2 continues page 1's shuffle instead of
    /// reshuffling it. Confirmed live 2026-09-13: `random_seed=0.42&limit=3`
    /// answered ids 512345, 58172, 308177 on two consecutive calls. Set once
    /// per "Surprise me" tap via `freshRandomSeed()`; only sent beside
    /// `sort == "random"`, so a stale seed cannot pin any other sort.
    var randomSeed: Double?
    /// A publisher's name, as `/v1/publishers/search` spells it.
    ///
    /// Verified against the live API on 2026-09-10: `publisher=Seven Seas`
    /// answers 1,265 of 304,096 and every row really is theirs, while a
    /// nonsense publisher answers 0 rather than being ignored.
    var publisher: String?
    /// A creator's name, as the series credits it. The API's `staff`
    /// parameter: `staff=Yoshihiro Togashi` answers 16 series, all his
    /// (verified live 2026-09-11). Behind the author page.
    var staff: String?
    var limit = 30
    /// 1-based, as the API counts. `/v2/series/search` accepts up to page 100.
    var page = 1

    /// Whether this query would narrow anything at all.
    ///
    /// `sort` counts. It used to be excluded, which is what made "Surprise me"
    /// do nothing: it sets `sort = "random"` and nothing else, so the query
    /// still read as empty, `search()` returned before making a request, and
    /// the view kept rendering its idle state. A sort-only query is a real
    /// query — random and trending are both browsing, not filtering.
    var isEmpty: Bool {
        askedText == nil
            && types.isEmpty && statuses.isEmpty && minimumRating == nil
            && sort == nil && tags.isEmpty && genres.isEmpty && (publisher ?? "").isEmpty
            && (staff ?? "").isEmpty && yearFrom == nil && yearTo == nil
    }

    /// What is narrowing the results besides the typed text.
    ///
    /// Written for the empty state, which used to say only "Nothing matched
    /// 'one piece'" — leaving a reader to work out for themselves that a tag
    /// they picked twenty minutes ago was still on. Measured against the live
    /// API on 2026-09-10: `q=one piece` answers 600 series, and the same query
    /// with one leftover tag answers 0.
    var activeFilterCount: Int {
        types.count + statuses.count + tags.count + genres.count
            + (minimumRating == nil ? 0 : 1)
            + ((publisher ?? "").isEmpty ? 0 : 1)
            + ((staff ?? "").isEmpty ? 0 : 1)
            + (yearFrom == nil && yearTo == nil ? 0 : 1)
    }

    /// Everything except the typed text, cleared.
    func clearingFilters() -> SearchQuery {
        var cleared = SearchQuery()
        cleared.text = text
        cleared.limit = limit
        return cleared
    }

    /// Repeated keys where the API wants them; a comma-joined list is rejected
    /// with HTTP 400 for these parameters.
    var queryItems: [URLQueryItem] {
        var items = [URLQueryItem(name: "limit", value: String(limit))]
        if page > 1 { items.append(URLQueryItem(name: "page", value: String(page))) }
        if let text = askedText {
            // `URLComponents` leaves a literal `+` unencoded, and most server
            // stacks read a literal `+` in a query string as a space — a
            // real hazard for a title like "+Anima". NOT A BUG here, checked
            // live 2026-09-13: `q=%2BAnima` and `q=+Anima` both answer id
            // 14619 — `api.mangabaka.org` evidently normalises `+` back to
            // itself for `q` (fuzzy search), rather than decoding it as a
            // space. Left unencoded on purpose; do not "fix" this without a
            // fresh measurement, and see `staff`/`publisher` below, which are
            // exact-match filters and were not checked the same way.
            // Trimmed: `q=one` and `q=one%20` answer the same 4,926 series
            // in the same order (measured 2026-09-13), and the pause after a
            // word used to cost a request for an answer already on screen.
            items.append(URLQueryItem(name: "q", value: text))
        }
        for type in types { items.append(URLQueryItem(name: "type", value: type)) }
        for status in statuses { items.append(URLQueryItem(name: "status", value: status)) }
        // Ids, never names. `/v2/series/search` accepts a tag by name, but
        // it is not the same filter: measured 2026-09-13, `tag=Action` 4,380
        // against `tag=39` 34,704; `tag=Isekai` 7,116 against `tag=94`
        // 9,643; `tag=Romance` 14,065 against `tag=9` 110,242. Whatever the
        // name form matches, it is a fraction of the tag. And v2 has no
        // `genre` key at all (HTTP 400 "Unrecognized key"; only v1 does —
        // `genre=romance` 100,948 there), so a genre goes out as its tag's
        // id too, 9% wider than v1's genre and the nearest v2 offers.
        // A name the bundled taxonomy cannot resolve is sent as-is rather
        // than dropped, so a tag renamed upstream still filters somewhat.
        let wireTags = Self.wireTagIDs(tags: tags, genres: genres)
        for tag in wireTags { items.append(URLQueryItem(name: "tag", value: tag)) }
        // Always `and`, whatever `tagMode` holds — see its doc comment. Only
        // when there is something to combine, or the key is noise.
        if wireTags.count > 1 {
            items.append(URLQueryItem(name: "tag_mode", value: "and"))
        }
        if let sort {
            items.append(URLQueryItem(name: "sort_by", value: sort))
            if sort == "random", let randomSeed {
                items.append(URLQueryItem(name: "random_seed", value: String(randomSeed)))
            }
        }
        if let yearFrom {
            items.append(URLQueryItem(name: "published_start_date_lower", value: String(yearFrom)))
        }
        if let yearTo {
            items.append(URLQueryItem(name: "published_start_date_upper", value: String(yearTo)))
        }
        if let minimumRating {
            items.append(URLQueryItem(name: "rating_lower", value: String(minimumRating)))
        }
        if let staff, !staff.isEmpty {
            items.append(URLQueryItem(name: "staff", value: staff))
        }
        if let publisher, !publisher.isEmpty {
            items.append(URLQueryItem(name: "publisher", value: publisher))
        }
        return items
    }

    /// The fewest characters of text that count as a question. One
    /// character fired a request and the walk saw "30 shown" over titles
    /// with no "a" in them (LW §2, 2026-09-13) — `q=a` is a fuzzy match
    /// the API answers with noise. `RecentSearches.record` had refused
    /// one-character terms since before that, so the two rules disagreed:
    /// a search could run that could never be remembered (E "Minimum
    /// length"). One number, read by both. A guess at where noise ends;
    /// two is the shortest string the walk saw answer sensibly ("on").
    static let minimumTextLength = 2

    /// `text` as a question: trimmed, and nil when blank or under
    /// `minimumTextLength`. The one reading of the text every rule shares —
    /// `isEmpty`, the wire's `q`, and `SearchModel`'s memory of what it
    /// answered — so a one-character field is "no text" everywhere rather
    /// than a request in one place and idle in another.
    var askedText: String? {
        let trimmed = (text ?? "").trimmingCharacters(in: .whitespaces)
        return trimmed.count >= Self.minimumTextLength ? trimmed : nil
    }

    /// A seed the API will accept. The schema says −1…1, but `random_seed=0`
    /// and `random_seed=-0.7` both answered HTTP 503 "A database error
    /// occurred" (2 of 2 tries each, 2026-09-13) while 0.42 and 0.9 worked,
    /// so the range is (0, 1]. Three decimals: enough for a thousand distinct
    /// shuffles, short enough that the URL stays readable in the ledger.
    static func freshRandomSeed() -> Double {
        Double(Int.random(in: 1...1000)) / 1000
    }
}

extension SearchQuery {
    /// Every key optional on the way in. The synthesised decoder demands a
    /// key for a non-optional array even when it has a default, and
    /// `SearchLensStore` decodes with `try?` — so adding `genres` with the
    /// synthesised decoder would have silently wiped every lens saved before
    /// it existed. Any field added here must be decoded `IfPresent`.
    init(from decoder: any Decoder) throws {
        let keyed = try decoder.container(keyedBy: CodingKeys.self)
        text = try keyed.decodeIfPresent(String.self, forKey: .text)
        types = try keyed.decodeIfPresent([String].self, forKey: .types) ?? []
        statuses = try keyed.decodeIfPresent([String].self, forKey: .statuses) ?? []
        sort = try keyed.decodeIfPresent(String.self, forKey: .sort)
        genres = try keyed.decodeIfPresent([String].self, forKey: .genres) ?? []
        tags = try keyed.decodeIfPresent([String].self, forKey: .tags) ?? []
        tagMode = try keyed.decodeIfPresent(String.self, forKey: .tagMode)
        minimumRating = try keyed.decodeIfPresent(Int.self, forKey: .minimumRating)
        yearFrom = try keyed.decodeIfPresent(Int.self, forKey: .yearFrom)
        yearTo = try keyed.decodeIfPresent(Int.self, forKey: .yearTo)
        randomSeed = try keyed.decodeIfPresent(Double.self, forKey: .randomSeed)
        publisher = try keyed.decodeIfPresent(String.self, forKey: .publisher)
        staff = try keyed.decodeIfPresent(String.self, forKey: .staff)
        limit = try keyed.decodeIfPresent(Int.self, forKey: .limit) ?? 30
        page = try keyed.decodeIfPresent(Int.self, forKey: .page) ?? 1
    }
}

extension SearchQuery {
    /// The `tag=` values for the wire: every tag and genre as a bundled
    /// taxonomy id where one resolves, the name itself where none does. Order
    /// is tags then genres, duplicates folded (a genre picked as a tag too is
    /// one filter, not two `tag_mode=and` copies of it).
    nonisolated static func wireTagIDs(tags: [String], genres: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        let values = tags.map { tag in
            OfflineCatalogue.tagIDs(named: [tag]).first.map(String.init) ?? tag
        } + genres.map { genre in
            OfflineCatalogue.tagIDs(forGenres: [genre]).first.map(String.init) ?? genre
        }
        for value in values where seen.insert(value).inserted {
            out.append(value)
        }
        return out
    }
}
