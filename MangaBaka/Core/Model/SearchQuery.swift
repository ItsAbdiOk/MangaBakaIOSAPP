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
            && sort == nil && tags.isEmpty
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
        return items
    }
}
