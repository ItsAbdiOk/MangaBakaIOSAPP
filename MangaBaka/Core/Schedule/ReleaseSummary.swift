import Foundation

/// What a release section can honestly say, given whatever the feed gave up.
///
/// Publisher platforms hand back wildly different amounts of history: Webtoons'
/// RSS carries up to twenty timestamped episodes, a GigaViewer magazine feed
/// filtered to one series exposes only that series' rows, some feeds answer
/// with one entry, some fail or return none at all. The detail screen has one
/// release section and must show the strongest claim the data supports — never
/// pad a thin feed into a false rhythm, and never render an empty box when
/// there is nothing honest to say.
enum ReleaseSummary: Equatable, Sendable {
    /// Nothing usable arrived. The view removes the section rather than show it
    /// empty.
    case none
    /// Exactly one episode: a date exists, but one point cannot suggest a gap,
    /// let alone a rhythm.
    case lastSeen(latest: Date, number: Int?)
    /// Two or more episodes, but fewer than `Cadence.estimate` needs to speak —
    /// listable, with no schedule attached.
    case recent([ReleaseEntry])
    /// Enough history for `Cadence` to state a schedule.
    case rhythm(Cadence, latest: ReleaseEntry?)
    /// A season finished. Distinct from `rhythm` on purpose: "Season 1 ended on
    /// 28 August" and "overdue since August" are opposite claims, and a
    /// gap-based estimate cannot tell a finished run from a stalled one — only
    /// the finale marker can. See `ReleaseFeed.endedSeason`.
    case seasonEnded(season: Int?, on: Date)

    /// True only for `.none`, so a view can write `if !summary.isEmpty`.
    var isEmpty: Bool {
        if case .none = self { return true }
        return false
    }

    /// Below this fraction of the series' known chapter count, the feed's
    /// highest number is read as the oldest-first shape (see below) rather
    /// than trusted as current. **A guess**: True Beauty's 8-entry feed tops
    /// out at 3% of its 230 chapters, so 50% has a wide margin either way —
    /// nothing here fits it against a corpus of both feed shapes.
    private static let oldestFirstThreshold = 0.5

    /// Decides which of the above the feed supports.
    ///
    /// - A nil feed, a feed with no entries, or a feed whose entries are all
    ///   non-episodes (afterwords, notices) all collapse to `.none`: there is
    ///   no episode date to show, only entries that would render as an empty
    ///   list.
    /// - A feed whose highest episode number sits far below the series' own
    ///   known chapter count is not "the twenty most recent" — it is the
    ///   *oldest* few. Measured live 2026-09-13: True Beauty (completed,
    ///   ~230 episodes) answers with "Episode 0"–"Episode 7" from 2018, and
    ///   without this check that reads as a confident weekly rhythm for a
    ///   series that ended years ago. `knownChapterCount` is optional because
    ///   not every caller has it (tests, series with no catalogue count yet);
    ///   without it this check simply does not fire.
    /// - A finished season is checked before anything gap-based, because it
    ///   outranks a rhythm claim rather than sitting alongside it — see the
    ///   case comment above.
    /// - One episode is `.lastSeen`. Two or more go to `Cadence.estimate`;
    ///   its own minimums (`Cadence.minimumDates`, `minimumGaps`) decide
    ///   whether that is enough for a schedule. When it says no, that is
    ///   `.recent`, not `.none` — the episodes themselves are still real and
    ///   worth listing.
    static func summarise(_ feed: ReleaseFeed?, knownChapterCount: Double? = nil) -> ReleaseSummary {
        guard let feed else { return .none }
        let episodes = feed.episodes
        guard !episodes.isEmpty else { return .none }

        if let knownChapterCount, knownChapterCount > 0,
           let highest = feed.latestEpisodeNumber,
           Double(highest) < knownChapterCount * oldestFirstThreshold {
            return .none
        }

        // Checked first: a finished season is not a gap to estimate over, it
        // is the reason the gap exists. Keyed on `finaleEndedAt`, not
        // `endedSeason` (R8/P8): a finale whose title carries no season
        // number still ended, and used to fall through to the gap-based
        // estimate below, which called it "overdue" instead.
        if let endedOn = feed.finaleEndedAt {
            return .seasonEnded(season: feed.endedSeason, on: endedOn)
        }

        guard episodes.count > 1 else {
            let only = episodes[0]
            return .lastSeen(latest: only.published, number: only.number)
        }

        if let cadence = Cadence.estimate(from: feed.releaseDates) {
            // `max(by:)` rather than `episodes.first`: nothing in `ReleaseFeed`
            // guarantees feed order survived parsing newest-first, and the
            // published date is the one fact this type can trust directly.
            let latest = episodes.max { $0.published < $1.published }
            return .rhythm(cadence, latest: latest)
        }

        return .recent(episodes)
    }
}
