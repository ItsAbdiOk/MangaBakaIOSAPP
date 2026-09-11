import Foundation

/// What the reader's own library says about them.
///
/// Everything here is computed on the device from data the app already has. No
/// endpoint answers any of these questions, and no catalogue could: they are
/// about one person's reading rather than about the books.
///
/// Deliberately a set of pure functions over `[LibraryEntry]` rather than a
/// screen's model. The judgements in here — what counts as "behind", what
/// counts as "nearly finished" — are the part worth testing, and they should
/// not need a view to exercise.
enum ReadingInsights {
    // MARK: - Where you stopped

    /// A series you were reading and have fallen behind on.
    struct Behind: Identifiable, Equatable, Sendable {
        let entry: LibraryEntry
        /// Chapters published since you stopped.
        let waiting: Int

        var id: Int { entry.seriesId }
        var series: Series? { entry.series }
    }

    /// Series with unread chapters waiting, most waiting first.
    ///
    /// **The schedule inverted.** The app tells you what is coming; nothing
    /// told you what is already there. For most readers the second list is
    /// longer and more useful — a release you are waiting for is one chapter, a
    /// series you drifted away from is forty.
    ///
    /// - Parameter minimum: how many chapters have to be waiting before it is
    ///   worth mentioning. One is noise: a weekly series is one behind for six
    ///   days out of seven and that is not a state anyone needs telling about.
    static func waiting(in entries: [LibraryEntry], minimum: Int = 2) -> [Behind] {
        entries
            .filter { $0.state == .reading || $0.state == .rereading || $0.state == .paused }
            .compactMap { entry -> Behind? in
                // You cannot have stopped something you never started. Without
                // this the list ranks the longest series in the library rather
                // than the ones the reader drifted away from: on a real 939
                // series library, five of the eight top rows read "ch 0".
                guard let waiting = chaptersLeft(for: entry), waiting >= minimum else { return nil }
                return Behind(entry: entry, waiting: waiting)
            }
            .sorted { $0.waiting > $1.waiting }
    }

    /// Series that have ENDED and you stopped just short of the end.
    ///
    /// The most annoying way to lose a story: it finished, nobody told you, and
    /// the last few chapters are sitting there. Narrow on purpose — a series
    /// you abandoned forty chapters from the end is a different feeling, and
    /// belongs in `waiting`.
    ///
    /// - Parameter within: how close to the end still counts as "nearly".
    static func nearlyFinished(in entries: [LibraryEntry], within: Int = 12) -> [Behind] {
        entries
            .filter { $0.state == .reading || $0.state == .rereading || $0.state == .paused }
            .filter { $0.series?.status?.lowercased() == "completed" }
            .compactMap { entry -> Behind? in
                guard let left = chaptersLeft(for: entry), left <= within else { return nil }
                return Behind(entry: entry, waiting: left)
            }
            .sorted { $0.waiting < $1.waiting }
    }

    /// Unread chapters for a series the reader has actually started.
    ///
    /// Nil where there is no chapter count to subtract from, where the series
    /// was never opened, or where there is nothing left. `waiting` and
    /// `nearlyFinished` ask the same question of the same numbers and differ
    /// only in how big an answer they want, so the arithmetic lives once.
    private static func chaptersLeft(for entry: LibraryEntry) -> Int? {
        guard let total = entry.series?.totalChapters, total > 0 else { return nil }
        guard let read = entry.progressChapter, read > 0 else { return nil }
        let left = Int(total - read)
        return left > 0 ? left : nil
    }

    // MARK: - How much you have read

    /// Chapters finished, across everything.
    ///
    /// A completed series counts its whole run even where the reader never set
    /// a progress number — finishing something and not ticking the last box is
    /// the ordinary case, and counting it as zero would make the total absurd.
    static func chaptersRead(in entries: [LibraryEntry]) -> Int {
        entries.reduce(0) { $0 + Int(chaptersCounted(for: $1)) }
    }

    /// How many chapters one entry contributes to a total.
    ///
    /// One place, because `chaptersRead` and `hoursRead` each derived the
    /// completed-series rule themselves and would have drifted apart the first
    /// time one of them was corrected.
    static func chaptersCounted(for entry: LibraryEntry) -> Double {
        let progress = entry.progressChapter ?? 0
        guard entry.state == .completed else { return progress }
        return max(progress, entry.series?.totalChapters ?? 0)
    }

    /// Roughly how long that took, in hours.
    ///
    /// **A stated guess, not a measurement.** Nobody records reading time, so
    /// this is chapters times a per-format estimate: a manhwa chapter is a
    /// short vertical scroll and a manga chapter is a longer sitting. The
    /// numbers below are from published averages and reader surveys rather than
    /// from anything this app observed, and the screen says "about" wherever it
    /// shows them.
    static func hoursRead(in entries: [LibraryEntry]) -> Double {
        let minutes = entries.reduce(0.0) { total, entry in
            total + chaptersCounted(for: entry) * minutesPerChapter(entry.series?.type)
        }
        return minutes / 60
    }

    /// Minutes for one chapter of a given format.
    static func minutesPerChapter(_ type: String?) -> Double {
        switch type?.lowercased() {
        // A vertical-scroll chapter is short: 40-70 panels read in one motion.
        case "manhwa", "manhua": 6
        // A prose chapter is the long one, and the most variable.
        case "novel": 20
        // A tankōbon chapter is 18-20 pages.
        default: 11
        }
    }

    // MARK: - What you actually like

    /// One tag, and how the reader treats series carrying it.
    struct TagVerdict: Identifiable, Equatable, Sendable {
        let name: String
        /// Series carrying this tag that the reader has read at all.
        let read: Int
        /// Of those, how many were finished rather than dropped.
        let finished: Int
        let dropped: Int
        /// Average rating out of 5, where the reader rated any of them.
        let rating: Double?

        var id: String { name }

        /// How often a series with this tag survives to the end.
        ///
        /// Nil when the reader has neither finished nor dropped one — a shelf
        /// full of things they are still reading says nothing about whether
        /// they will finish them.
        var completionRate: Double? {
            let decided = finished + dropped
            guard decided > 0 else { return nil }
            return Double(finished) / Double(decided)
        }
    }

    /// What the reader finishes and what they abandon, by tag.
    ///
    /// **The strongest signal in the library, and nothing uses it.** Nearly half
    /// of this reader's 939 entries are dropped, which is a judgement on 429
    /// series that no catalogue has and no recommender is told about.
    ///
    /// Only counts entries whose series arrived with tags. That is not all of
    /// them — see `TasteLedger` — so the screen reports the sample size rather
    /// than presenting a verdict on a library it has only partly seen.
    ///
    /// - Parameter minimum: how many read series a tag needs before it is worth
    ///   a verdict. Two is a coincidence; three is the smallest number that can
    ///   be called a pattern without embarrassment.
    static func verdicts(in entries: [LibraryEntry], minimum: Int = 3) -> [TagVerdict] {
        struct Tally {
            var read = 0
            var finished = 0
            var dropped = 0
            var ratings: [Double] = []
        }

        var byTag: [String: Tally] = [:]
        for entry in entries {
            // Plan-to-read and considering say nothing: the reader has not read
            // them, so they are evidence of intent rather than of taste.
            guard entry.state != .planToRead, entry.state != .considering else { continue }
            guard let tags = entry.series?.richTags, !tags.isEmpty else { continue }

            for tag in tags {
                var tally = byTag[tag.name] ?? Tally()
                tally.read += 1
                if entry.state == .completed { tally.finished += 1 }
                if entry.state == .dropped { tally.dropped += 1 }
                if let rating = entry.rating, rating > 0 { tally.ratings.append(rating / 20) }
                byTag[tag.name] = tally
            }
        }

        return byTag
            .filter { $0.value.read >= minimum }
            .map { name, tally in
                TagVerdict(
                    name: name,
                    read: tally.read,
                    finished: tally.finished,
                    dropped: tally.dropped,
                    rating: tally.ratings.isEmpty
                        ? nil
                        : tally.ratings.reduce(0, +) / Double(tally.ratings.count)
                )
            }
            .sorted { $0.read > $1.read }
    }

    /// How many of the reader's series the verdicts could actually see.
    ///
    /// Reported next to them, because a verdict drawn from 87 of 939 series is
    /// a different claim from one drawn from all of them, and the reader cannot
    /// tell which they are looking at.
    static func sampleSize(in entries: [LibraryEntry]) -> (seen: Int, total: Int) {
        let usable = entries.filter { $0.series?.richTags.isEmpty == false }
        return (usable.count, entries.count)
    }
}
