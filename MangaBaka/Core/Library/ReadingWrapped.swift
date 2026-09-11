import Foundation

/// The reader's year, and the parts of their taste that are actually theirs.
///
/// **The rule this file is built on: a statistic is only interesting if it
/// could have come out differently.** "Your top tag is Action" is not a fact
/// about the reader, it is a fact about manga — Action is on tens of thousands
/// of series and it would top almost anyone's list. What distinguishes one
/// reader from another is where their library departs from the database, and
/// the API hands us the baseline to measure that against: every tag carries a
/// `seriesCount`, which is how many series in the whole catalogue have it.
///
/// Everything here is computed on the device from data the app already holds.
/// No endpoint answers any of it, and none of it leaves the phone.
///
/// Every figure carries the size of the sample it was drawn from, because a
/// verdict on 9 rated series and a verdict on 400 are different claims and the
/// screen has to be able to say which it is making.
enum ReadingWrapped {
    /// The entries the reader has actually opened. Plan-to-read and
    /// considering are ambition, not habit — `verdicts` and the taste ledger
    /// leave them out for the same reason, and every statistic here whose
    /// caption says "read" has to as well. Four of them did not, so a reader
    /// with a 400-entry backlog was told "the people you read most" were
    /// authors they had never read.
    static func readAtAll(_ entries: [LibraryEntry]) -> [LibraryEntry] {
        entries.filter { $0.state != .planToRead && $0.state != .considering }
    }

    /// A rating of exactly zero is "unrated" to at least one client that
    /// writes 0 rather than null. `verdicts` guards the same field the same
    /// way; without it ten such entries made the reader a savage critic of
    /// series they had never rated.
    static func rating(of entry: LibraryEntry) -> Double? {
        guard let rating = entry.rating, rating > 0 else { return nil }
        return rating
    }

    // MARK: - Signature tags

    /// A tag the reader reads far more than the database would predict.
    struct Signature: Identifiable, Equatable, Sendable {
        let tag: String
        /// How many of the reader's series carry it.
        let mine: Int
        /// What share of the reader's tagged library that is.
        let myShare: Double
        /// What share of the whole catalogue carries it.
        let worldShare: Double

        var id: String { tag }

        /// How many times more often this appears in the reader's library than
        /// in the database. 12.0 means twelve times.
        var lift: Double { worldShare > 0 ? myShare / worldShare : 0 }
    }

    /// The smallest number of series a tag can appear on and still be read as
    /// a preference.
    ///
    /// **A guess, and a deliberately cautious one.** Three series sharing a tag
    /// in a library of hundreds is comfortably inside coincidence; the number
    /// is chosen to keep a one-off binge from being described as a personality.
    /// Nothing derived it.
    static let minimumForSignature = 5

    /// How much more often than the database a tag has to appear before it
    /// says anything.
    ///
    /// **A guess.** Reading something 1.2 times more than average is noise —
    /// it is the kind of number that differs between two random halves of the
    /// same library. Twice is the point where a reader would recognise the
    /// claim as being about them. Nothing derived it.
    static let minimumLift = 2.0

    /// `activeSeriesCount` as the community pulse reported it on 2026-09-11.
    /// The fallback denominator when the live pulse has not arrived; dated so
    /// the next reader knows how stale it is.
    static let catalogueSizeOn20260911 = 304_108

    /// Tags the reader reads disproportionately, strongest first.
    ///
    /// - Parameter catalogueSize: how many series the database holds, for the
    ///   world-share denominator. `/v0/frontpage/community-pulse` reports it;
    ///   pass what it said rather than a constant, because it moves every week.
    static func signatures(
        in entries: [LibraryEntry],
        catalogueSize: Int,
        limit: Int = 6
    ) -> [Signature] {
        let tagged = readAtAll(entries).filter { !($0.series?.richTags.isEmpty ?? true) }
        guard tagged.count >= minimumForSignature, catalogueSize > 0 else { return [] }

        var mine: [String: Int] = [:]
        var worldCount: [String: Int] = [:]
        for entry in tagged {
            // A tag counts once per series, however many times it appears.
            var seen: Set<String> = []
            for tag in entry.series?.richTags ?? [] {
                // Spoiler tags are excluded outright. A wrapped screen that
                // announces "you read a lot of Character Death" has spoiled
                // something for whoever is looking over the reader's shoulder.
                guard tag.isSpoiler != true else { continue }
                guard seen.insert(tag.name).inserted else { continue }
                mine[tag.name, default: 0] += 1
                if let count = tag.seriesCount, count > 0 {
                    worldCount[tag.name] = count
                }
            }
        }

        let total = Double(tagged.count)
        return mine.compactMap { name, count -> Signature? in
            guard count >= minimumForSignature, let world = worldCount[name] else { return nil }
            let worldShare = Double(world) / Double(catalogueSize)
            guard worldShare > 0 else { return nil }
            return Signature(
                tag: name,
                mine: count,
                myShare: Double(count) / total,
                worldShare: worldShare
            )
        }
        .filter { $0.lift >= minimumLift }
        .sorted { $0.lift > $1.lift }
        .prefix(limit)
        .reduce(into: []) { $0.append($1) }
    }

    // MARK: - Where you disagree with everyone

    /// One series the reader and the crowd see differently.
    struct Disagreement: Identifiable, Equatable, Sendable {
        let entry: LibraryEntry
        /// The reader's rating minus the crowd's, on the API's 0-100 scale.
        /// Positive means the reader liked it more.
        let gap: Double

        var id: Int { entry.seriesId }
        var series: Series? { entry.series }
        /// "+2.4" — the gap on the 0-10 scale the app shows ratings in.
        var displayGap: String {
            String(format: "%+.1f", gap / 10)
        }
    }

    /// The fewest ratings that can support a claim about someone's taste.
    ///
    /// **A guess.** Ten is the point at which a mean stops swinging wildly on
    /// one more entry, not a threshold anything derived.
    static let minimumForCriticGap = 10

    /// How far the reader's ratings sit from the crowd's, on the 0-100 scale.
    ///
    /// Negative means a harsher critic than average. Nil when too few series
    /// have both ratings to say anything — which is the honest answer, not
    /// zero.
    static func criticGap(in entries: [LibraryEntry]) -> (gap: Double, sample: Int)? {
        let gaps = entries.compactMap { entry -> Double? in
            guard let mine = rating(of: entry), let crowd = entry.series?.rating else { return nil }
            return mine - crowd
        }
        guard gaps.count >= minimumForCriticGap else { return nil }
        return (gaps.reduce(0, +) / Double(gaps.count), gaps.count)
    }

    /// The series where the reader is furthest from everyone else.
    ///
    /// - Parameter liked: true for the reader's overrated picks, false for the
    ///   ones they alone disliked.
    static func disagreements(
        in entries: [LibraryEntry],
        liked: Bool,
        limit: Int = 3
    ) -> [Disagreement] {
        entries
            .compactMap { entry -> Disagreement? in
                guard let mine = rating(of: entry), let crowd = entry.series?.rating else { return nil }
                let gap = mine - crowd
                guard liked ? gap > 0 : gap < 0 else { return nil }
                return Disagreement(entry: entry, gap: gap)
            }
            .sorted { liked ? $0.gap > $1.gap : $0.gap < $1.gap }
            .prefix(limit)
            .reduce(into: []) { $0.append($1) }
    }
}
