import Foundation

/// What is actually coming out, as opposed to what is likely to.
///
/// The Schedule screen is built on cadence: how often a series has published
/// before, turned into a guess about the next chapter. This is the other half —
/// volumes with dates their publishers have announced. A guess is worth having
/// when there is nothing better; when a date exists, the guess should get out
/// of the way.
///
/// Narrowed to the reader's own library, because the unfiltered list is 246
/// works in a month and almost none of them are yours. Without a library it
/// still answers "what is coming", which is a browsable thing rather than a
/// personal one, and the screen says which of the two it is showing.
actor ReleaseCalendar {
    private let client: APIClient
    /// One page is twenty; the window is a few hundred. Four pages covers the
    /// month without walking a list nobody will read to the end of.
    private static let pages = 4
    private static let perPage = 50

    private var cached: [UpcomingWork]?

    init(client: APIClient) {
        self.client = client
    }

    /// Everything announced in the API's own window, oldest date first.
    func upcoming() async -> [UpcomingWork] {
        if let cached { return cached }

        var all: [UpcomingWork] = []
        for page in 1...Self.pages {
            let query = [
                URLQueryItem(name: "limit", value: String(Self.perPage)),
                URLQueryItem(name: "page", value: String(page))
            ]
            guard let batch: [UpcomingWork] = try? await client.get(
                "/v1/works/upcoming", query: query
            ), !batch.isEmpty else { break }
            all.append(contentsOf: batch)
            if batch.count < Self.perPage { break }
        }

        // Dated first, in date order. A work with no date is not upcoming in
        // any useful sense and goes last rather than to the top, where a nil
        // sorted before this was written down.
        cached = all.sorted { left, right in
            switch (left.date, right.date) {
            case let (leftDate?, rightDate?): leftDate < rightDate
            case (_?, nil): true
            case (nil, _?): false
            default: (left.title ?? "") < (right.title ?? "")
            }
        }
        return cached ?? []
    }

    /// Only the works for series the reader has in their library.
    func mine(seriesIDs: Set<Int>) async -> [UpcomingWork] {
        guard !seriesIDs.isEmpty else { return [] }
        return await upcoming().filter { work in
            guard let id = work.seriesId else { return false }
            return seriesIDs.contains(id)
        }
    }
}
