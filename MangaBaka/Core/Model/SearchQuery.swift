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
    /// Tag names to require. The API takes repeated `tag` keys plus a
    /// `tag_mode` saying whether they are ANDed or ORed.
    var tags: [String] = []
    /// "and" or "or". Only sent when there is more than one tag to combine.
    var tagMode: String?
    /// 0-100 as the API expresses it.
    var minimumRating: Int?
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
        (text ?? "").trimmingCharacters(in: .whitespaces).isEmpty
            && types.isEmpty && statuses.isEmpty && minimumRating == nil
            && sort == nil && tags.isEmpty && (publisher ?? "").isEmpty
            && (staff ?? "").isEmpty
    }

    /// What is narrowing the results besides the typed text.
    ///
    /// Written for the empty state, which used to say only "Nothing matched
    /// 'one piece'" — leaving a reader to work out for themselves that a tag
    /// they picked twenty minutes ago was still on. Measured against the live
    /// API on 2026-09-10: `q=one piece` answers 600 series, and the same query
    /// with one leftover tag answers 0.
    var activeFilterCount: Int {
        types.count + statuses.count + tags.count
            + (minimumRating == nil ? 0 : 1)
            + ((publisher ?? "").isEmpty ? 0 : 1)
            + ((staff ?? "").isEmpty ? 0 : 1)
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
        if let text, !text.trimmingCharacters(in: .whitespaces).isEmpty {
            items.append(URLQueryItem(name: "q", value: text))
        }
        for type in types { items.append(URLQueryItem(name: "type", value: type)) }
        for status in statuses { items.append(URLQueryItem(name: "status", value: status)) }
        for tag in tags { items.append(URLQueryItem(name: "tag", value: tag)) }
        if tags.count > 1, let tagMode {
            items.append(URLQueryItem(name: "tag_mode", value: tagMode))
        }
        if let sort { items.append(URLQueryItem(name: "sort_by", value: sort)) }
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
}
