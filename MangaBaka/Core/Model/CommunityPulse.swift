import Foundation

/// What everyone else has been doing here this week.
///
/// `/v0/frontpage/community-pulse` is the only endpoint that says MangaBaka is
/// a community-maintained database rather than a catalogue that appeared from
/// nowhere. Verified live on 2026-09-11.
///
/// Deliberately narrow. The response also carries moderation figures —
/// duplicate sets reviewed, edits in the last seven days — and those are not
/// decoded: Abdi asked for the database's pulse, not a leaderboard, and a
/// contribution count on a screen nobody contributes from is vanity.
struct CommunityPulse: Codable, Equatable, Sendable {
    /// Doubles, all six: the schema types every figure as `number`, and
    /// `chapters_read_count` is measured to arrive fractional. `Int` throws
    /// on 290.0, and a throw here hid the whole card. Rounded where shown.
    let activeSeriesCount: Double
    let activeSeriesCountPrevWeek: Double
    let registeredUserCount: Double
    let registeredUserCountPrevWeek: Double
    let chaptersReadCount: Double
    let chaptersReadCountPrevWeek: Double

    /// One fact, ready to render: what it counts, how many, and the change.
    struct Figure: Identifiable, Equatable, Sendable {
        let id: String
        /// "53,975,689"
        let value: String
        /// "chapters read"
        let label: String
        /// "+3,012,062 this week", or nil when the week did not move.
        let change: String?
    }

    /// The three that mean something to a reader, largest first.
    ///
    /// Chapters lead because it is the only one that is about reading. Series
    /// and readers are about the place.
    var figures: [Figure] {
        [
            figure(
                id: "chapters",
                now: chaptersReadCount,
                then: chaptersReadCountPrevWeek,
                label: "chapters read here"
            ),
            figure(
                id: "series",
                now: activeSeriesCount,
                then: activeSeriesCountPrevWeek,
                label: "series in the database"
            ),
            figure(
                id: "readers",
                now: registeredUserCount,
                then: registeredUserCountPrevWeek,
                label: "people keeping libraries"
            )
        ]
    }

    private func figure(id: String, now: Double, then: Double, label: String) -> Figure {
        // The API returns chapters as a fractional double — 53975689.25981874,
        // because a part-read chapter counts as a fraction. Nobody wants to see
        // a quarter of a chapter, so it is rounded here rather than formatted
        // away, and the delta is computed from the rounded values so the
        // arithmetic on screen adds up.
        let current = now.rounded()
        let previous = then.rounded()
        // `Int(current - previous)` traps the same way `Int(current)` does —
        // both operands are decoded `Double`s off the wire (see the struct
        // comment) and the subtraction is just as capable of landing outside
        // Int's range. `Int(wholeOrClamped:)` is the guard already applied to
        // `current` two lines down; this is the same guard on the difference.
        let difference = Int(wholeOrClamped: current - previous)
        return Figure(
            id: id,
            value: Int(wholeOrClamped: current).formatted(),
            label: label,
            change: difference > 0 ? "+\(difference.formatted()) this week" : nil
        )
    }

    /// Where the reader sits in the chapters figure.
    ///
    /// The point of the whole surface. A number like 53,975,689 says nothing
    /// on its own; "you are 4,210 of them" turns it into a place the reader is
    /// actually standing in.
    ///
    /// - Returns: nil when the reader has read nothing, because "you are 0 of
    ///   53 million" is not a welcome.
    ///
    /// **"chapters", not "them".** Walked on the simulator 2026-09-14: this
    /// line rendered at the foot of the card, directly under the last figure,
    /// as "27,195 of them are yours" beneath "19,735 people keeping
    /// libraries" — a subset larger than the set it claimed to be part of.
    /// The number was never wrong; the pronoun was three rows from its
    /// antecedent (the chapters figure, which leads the card) and picked up
    /// the nearest one instead. Both halves of that are fixed: the noun is
    /// said outright here, and `CommunityPulseCard` now draws the line under
    /// the chapters row rather than under the whole card, so proximity and
    /// wording agree.
    func readerShare(chaptersRead: Int) -> String? {
        guard chaptersRead > 0, chaptersReadCount > 0 else { return nil }
        return "\(chaptersRead.formatted()) of those chapters are yours"
    }

    /// Which figure `readerShare` belongs beneath. The share is computed from
    /// `chaptersRead` against `chaptersReadCount`, so it attaches to the
    /// chapters row and to no other; named rather than spelled as a literal
    /// at the view's call site so the two cannot drift apart.
    nonisolated static let readerShareFigureID = "chapters"
}
