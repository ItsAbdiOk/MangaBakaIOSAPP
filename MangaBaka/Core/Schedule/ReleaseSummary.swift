import Foundation

/// What a release section can honestly say, given whatever the feed gave up.
///
/// Publisher platforms hand back wildly different amounts of history: Webtoons'
/// RSS carries up to twenty timestamped episodes, a paywalled Naver series
/// exposes three, some feeds answer with one entry, some fail or return none at
/// all. The detail screen has one release section and must show the strongest
/// claim the data supports — never pad a thin feed into a false rhythm, and
/// never render an empty box when there is nothing honest to say.
enum ReleaseSummary: Equatable, Sendable {
    /// Nothing usable arrived. The view removes the section rather than show it
    /// empty.
    case none
    /// Exactly one episode: a date exists, but one point cannot suggest a gap,
    /// let alone a rhythm.
    case lastSeen(latest: Date, number: Int?)
    /// Two or more episodes, but fewer than `Cadence.estimate` needs to speak —
    /// listable, with no schedule attached.
    case recent([WebtoonsEntry])
    /// Enough history for `Cadence` to state a schedule.
    case rhythm(Cadence, latest: WebtoonsEntry?)
    /// A season finished. Distinct from `rhythm` on purpose: "Season 1 ended on
    /// 28 August" and "overdue since August" are opposite claims, and a
    /// gap-based estimate cannot tell a finished run from a stalled one — only
    /// the finale marker can. See `WebtoonsFeed.endedSeason`.
    case seasonEnded(season: Int?, on: Date)

    /// True only for `.none`, so a view can write `if !summary.isEmpty`.
    var isEmpty: Bool {
        if case .none = self { return true }
        return false
    }

    /// Decides which of the above the feed supports.
    ///
    /// - A nil feed, a feed with no entries, or a feed whose entries are all
    ///   non-episodes (afterwords, notices) all collapse to `.none`: there is
    ///   no episode date to show, only entries that would render as an empty
    ///   list.
    /// - A finished season is checked before anything gap-based, because it
    ///   outranks a rhythm claim rather than sitting alongside it — see the
    ///   case comment above.
    /// - One episode is `.lastSeen`. Two or more go to `Cadence.estimate`;
    ///   its own minimums (`Cadence.minimumDates`, `minimumGaps`) decide
    ///   whether that is enough for a schedule. When it says no, that is
    ///   `.recent`, not `.none` — the episodes themselves are still real and
    ///   worth listing.
    static func summarise(_ feed: WebtoonsFeed?) -> ReleaseSummary {
        guard let feed else { return .none }
        let episodes = feed.episodes
        guard !episodes.isEmpty else { return .none }

        // Checked first: a finished season is not a gap to estimate over, it
        // is the reason the gap exists.
        if let season = feed.endedSeason, let endedOn = feed.lastEpisodeAt {
            return .seasonEnded(season: season, on: endedOn)
        }

        guard episodes.count > 1 else {
            let only = episodes[0]
            return .lastSeen(latest: only.published, number: only.number)
        }

        if let cadence = Cadence.estimate(from: feed.releaseDates) {
            // `max(by:)` rather than `episodes.first`: nothing in `WebtoonsFeed`
            // guarantees feed order survived parsing newest-first, and the
            // published date is the one fact this type can trust directly.
            let latest = episodes.max { $0.published < $1.published }
            return .rhythm(cadence, latest: latest)
        }

        return .recent(episodes)
    }
}
