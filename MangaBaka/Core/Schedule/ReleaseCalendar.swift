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
    /// The window measured 246 works (`UpcomingWork.swift`), sorted by date
    /// ascending, so a cap drops the furthest-out dates first. Six pages of
    /// fifty is 300: past the measured window with room for it to grow, and
    /// the last page is usually short so it costs what it holds. (This was
    /// four pages of fifty under a comment that did the arithmetic with a
    /// page size of twenty: 200 of 246, and the 46 lost were the ones a
    /// reader would be waiting longest for.)
    private static let pages = 6
    private static let perPage = 50

    private var cached: [UpcomingWork]?
    private var cachedAt: Date?
    private let clock: any Clock

    /// The most recent `upcoming()` failure, or nil once an ask succeeds.
    /// `mine(seriesIDs:)` stays `[UpcomingWork]` — batch 2's `AnnouncedSection`
    /// needs no shape change to keep compiling — so this is how a caller of
    /// `mine` still reaches the reason after an empty result: read this
    /// right after awaiting `mine`, on the same actor hop.
    private(set) var lastFailure: APIError?

    init(client: APIClient, clock: any Clock = SystemClock()) {
        self.client = client
        self.clock = clock
    }

    /// Everything announced in the API's own window, oldest date first.
    ///
    /// Returns `Fetched` rather than a bare array (gap 97) so a caller —
    /// `AnnouncedSection`/`ScheduleModel`, batch 5 — can tell "asked and
    /// MangaBaka had nothing announced" from "asked and failed", the same
    /// distinction the rest of this failure review draws everywhere else.
    /// Before this, a failed page returned `[]` indistinguishably from a
    /// quiet week, and `AnnouncedSection` read that as "nothing announced"
    /// (gap 97's other half).
    func upcoming() async -> Fetched<[UpcomingWork]> {
        if let cached, let cachedAt {
            return .loaded(cached, fetchedAt: cachedAt, isPartial: false)
        }

        var all: [UpcomingWork] = []
        var failure: APIError?
        for page in 1...Self.pages {
            let query = [
                URLQueryItem(name: "limit", value: String(Self.perPage)),
                URLQueryItem(name: "page", value: String(page))
            ]
            do {
                let batch: [UpcomingWork] = try await client.get("/v1/works/upcoming", query: query)
                all.append(contentsOf: batch)
                if batch.count < Self.perPage { break }
            } catch {
                failure = error
                break
            }
        }

        // Dated first, in date order. A work with no date is not upcoming in
        // any useful sense and goes last rather than to the top, where a nil
        // sorted before this was written down.
        let sorted = all.sorted { left, right in
            switch (left.date, right.date) {
            case let (leftDate?, rightDate?): leftDate < rightDate
            case (_?, nil): true
            case (nil, _?): false
            default: (left.title ?? "") < (right.title ?? "")
            }
        }

        if let failure {
            // Only a complete answer is ever cached — a failed page used to
            // cache whatever had arrived (an empty calendar, if it was the
            // first page) for the whole process, and the Schedule screen
            // showed no announced dates until relaunch. `stale: nil` here:
            // there is nothing earlier cached either, since `cached` is only
            // ever set on a full success below — a genuinely stale value to
            // fall back on would need a longer-lived cache than this actor
            // keeps, which nothing has asked for yet.
            lastFailure = failure
            return .failed(failure, stale: nil)
        }
        lastFailure = nil
        let fetchedAt = clock.now
        cached = sorted
        cachedAt = fetchedAt
        return .loaded(sorted, fetchedAt: fetchedAt, isPartial: false)
    }

    /// Only the works for series the reader has in their library.
    func mine(seriesIDs: Set<Int>) async -> [UpcomingWork] {
        guard !seriesIDs.isEmpty else { return [] }
        return (await upcoming().value ?? []).filter { work in
            guard let id = work.seriesId else { return false }
            return seriesIDs.contains(id)
        }
    }
}
