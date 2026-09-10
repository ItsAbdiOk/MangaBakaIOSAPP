import Foundation

/// How a library of a thousand entries is ordered.
///
/// Grouping by state is deliberately absent: the filter already does that, and
/// two mechanisms for one job is how they drift apart.
enum LibrarySort: String, CaseIterable, Identifiable, Sendable {
    case recentlyUpdated
    case title
    case rating
    case dateAdded

    var id: String { rawValue }

    var label: String {
        switch self {
        case .recentlyUpdated: "Recently updated"
        case .title: "Title"
        case .rating: "Rating"
        case .dateAdded: "Date added"
        }
    }

    /// Ordering, with a stable tiebreak so the list does not reshuffle itself
    /// between launches when two entries compare equal — which they constantly
    /// do on rating, and always do on a library with no dates.
    var comparator: (LibraryEntry, LibraryEntry) -> Bool {
        switch self {
        case .recentlyUpdated:
            { left, right in
                let leftDate = left.finishDate ?? left.startDate
                let rightDate = right.finishDate ?? right.startDate
                switch (leftDate, rightDate) {
                case let (left?, right?) where left != right: return left > right
                // An entry with no date is not newer than one with a date. It
                // goes last rather than to the top, which is where nil sorted
                // before this was written down.
                case (_?, nil): return true
                case (nil, _?): return false
                default: return left.seriesId > right.seriesId
                }
            }
        case .title:
            { left, right in
                let leftTitle = left.sortTitle
                let rightTitle = right.sortTitle
                if leftTitle != rightTitle {
                    return leftTitle.localizedCaseInsensitiveCompare(rightTitle) == .orderedAscending
                }
                return left.seriesId < right.seriesId
            }
        case .rating:
            { left, right in
                let leftRating = left.rating ?? -1
                let rightRating = right.rating ?? -1
                if leftRating != rightRating { return leftRating > rightRating }
                return left.seriesId > right.seriesId
            }
        case .dateAdded:
            // The API sends no "added" date, so this is the closest honest
            // stand-in: entry ids ascend with creation. Named for what a reader
            // means rather than for the field it uses.
            { $0.id > $1.id }
        }
    }
}

extension LibraryEntry {
    /// The title this entry sorts under, ignoring a leading article.
    ///
    /// "The Greatest Estate Developer" belongs under G, not under T. Sorting on
    /// the raw title puts a quarter of an English-language library under "The".
    var sortTitle: String {
        let title = series?.displayTitle ?? ""
        for article in ["the ", "a ", "an "] where title.lowercased().hasPrefix(article) {
            return String(title.dropFirst(article.count))
        }
        return title
    }

    /// The letter this entry files under in a jump index.
    var indexLetter: String {
        guard let first = sortTitle.first, first.isLetter else { return "#" }
        return String(first).uppercased()
    }
}
