import Foundation

/// "Back to it": who qualifies for a nudge about a series they were reading
/// and have not opened in a while, when there is something new waiting.
///
/// A pure rule over the library, the same shape `ReadingInsights` uses —
/// tested with a fixed clock rather than through `UNUserNotificationCenter`.
/// Spacing candidates across days, capping them per week, remembering which
/// series already fired, and turning a candidate into an actual local
/// notification are `ReleaseReminders.backToIt`'s job (mirroring how it
/// already owns that for its own two library nudges, `catchUp`); this type
/// only decides who is eligible and what the notification should say.
enum ReadingNudges {
    /// One series worth nudging about, ranked by how much is waiting.
    struct Candidate: Identifiable, Equatable, Sendable {
        let seriesID: Int
        let title: String
        /// The sentence for the notification body — already worded for 1 vs
        /// N chapters, so the caller does not have to re-derive the grammar.
        let line: String
        let chaptersWaiting: Int
        var id: Int { seriesID }
    }

    /// A guess: three weeks. Long enough that an ordinary release gap —
    /// weekly, even monthly — does not trip it; short enough that this still
    /// reads as "you left off here" rather than a series the reader forgot
    /// they ever started. No usage data backs this number.
    static let staleAfter: TimeInterval = 60 * 60 * 24 * 21

    /// A guess: a series nudged in the last 30 days is not nudged again, so
    /// ignoring one does not get it repeated every time the app reschedules.
    static let repeatBlock: TimeInterval = 60 * 60 * 24 * 30

    /// A guess: at most three candidates a week. Paired with
    /// `ReleaseReminders.backToIt` spacing them one a day, so the count also
    /// keeps this to one notification a day — a nudge every single morning
    /// about a different series is still a notification a day, and one a day
    /// is the frequency that gets a permission turned off.
    static let maxPerWeek = 3

    /// Candidates, most chapters waiting first. Neither the day/week cap nor
    /// the 30-day repeat block is applied here — both need to know what was
    /// already scheduled, which is persisted state this pure function does
    /// not hold; see `ReleaseReminders.backToIt`.
    ///
    /// - Parameters:
    ///   - lastOpened: when `HistoryStore` last saw the reader open this
    ///     series. Nil when history has nothing for it, in which case the
    ///     entry's own `startDate` stands in — a coarser signal ("started
    ///     reading it then", not "last touched it then") but the only date
    ///     the library itself carries. A series with neither is never
    ///     nudged: there is nothing to measure staleness from, and guessing
    ///     at it would be worse than staying quiet.
    ///   - latestKnownChapter: the newest chapter a release feed or schedule
    ///     already knows about for this series, which can be ahead of the
    ///     library's own `totalChapters` when MangaBaka has not catalogued
    ///     it yet. Injected so this stays pure and testable; nil falls back
    ///     to `totalChapters`.
    static func candidates(
        in entries: [LibraryEntry],
        now: Date,
        lastOpened: (Int) -> Date?,
        latestKnownChapter: (Int) -> Double? = { _ in nil }
    ) -> [Candidate] {
        entries
            // Reading only, not paused. `ReadingInsights.waiting` treats a
            // pause the same as reading because it is asking about the
            // backlog; this is asking whether to interrupt someone, and a
            // pause is the reader already having made that call themselves.
            .filter { $0.state == .reading }
            .compactMap { entry -> Candidate? in
                let seriesID = entry.seriesId
                guard let opened = lastOpened(seriesID) ?? entry.startDate,
                      now.timeIntervalSince(opened) >= staleAfter
                else { return nil }

                guard let known = latestKnownChapter(seriesID) ?? entry.series?.totalChapters,
                      let read = entry.progressChapter,
                      known > read
                else { return nil }

                let waiting = Int((known - read).rounded(.down))
                guard waiting > 0 else { return nil }

                let title = entry.series?.displayTitle ?? "a series you were reading"
                let chapter = LibraryEditSheet.chapterText(read)
                let line = waiting == 1
                    ? "You left \(title) at ch. \(chapter) — 1 more is out"
                    : "You left \(title) at ch. \(chapter) — \(waiting) more are out"
                return Candidate(seriesID: seriesID, title: title, line: line, chaptersWaiting: waiting)
            }
            .sorted { $0.chaptersWaiting > $1.chaptersWaiting }
    }
}
