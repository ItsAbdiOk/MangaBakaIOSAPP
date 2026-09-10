import Foundation

/// Which season a series is in, where it has seasons at all.
///
/// MangaUpdates puts a number in a release's `volume` field, and for a webtoon
/// that number is the season — Tower of God's latest releases are `v.3 c.235`,
/// and that is season three, not volume three. Checked against the live
/// endpoint on 2026-09-10.
///
/// **But the field does not say which it means.** Solo Leveling's releases are
/// tagged `v.1`, and Solo Leveling never had seasons; that is a print volume.
/// The API gives one field for two ideas and no way to tell them apart, so this
/// does not guess from the series' type — a manhwa with print volumes would be
/// mislabelled, and telling a reader they are on "Season 1" of something with
/// no seasons is worse than saying nothing.
///
/// What it uses instead is the shape of the release history: **chapter numbers
/// that restart when the volume number goes up**. A series whose chapters run
/// 1…200 across volumes 1, 2 and 3 is being collected into print volumes. A
/// series where chapter 12 appears in volume 2 after chapter 180 appeared in
/// volume 1 has started again, and starting again is what a season is.
enum SeasonReading {
    /// One release, reduced to the two numbers this needs.
    struct Sample: Equatable, Sendable {
        let volume: Int
        let chapter: Double
        let date: Date
    }

    /// How low a later volume has to start before it counts as starting again.
    ///
    /// **A guess, not derived.** A season restarts at chapter 1; the slack is
    /// for the mis-tagged straggler, and 5 is a judgement about how much slack
    /// that needs, made against no dataset. The previous rule — "below half of
    /// the last volume's highest chapter" — was also a guess and a worse one:
    /// a print volume ending at chapter 20 followed by one starting at 9
    /// satisfied it, and the app announced season 2 of a series with no
    /// seasons. Deriving this properly needs a sample of MangaUpdates volume
    /// fields with known ground truth, which we do not have.
    static let restartCeiling: Double = 5

    /// How far the previous volume has to have got before a restart means
    /// anything.
    ///
    /// **Also a guess.** A four-chapter run followed by a chapter 1 is much
    /// more likely to be a wrong volume field than a series that ran a season
    /// and came back. 20 is the shortest run that felt like a season; nothing
    /// measured it.
    static let minimumRun: Double = 20

    /// Whether these releases describe a series with seasons.
    ///
    /// Needs at least two distinct volumes and a genuine restart: a later
    /// volume beginning at the very start of the numbering, after a previous
    /// volume that got far enough for "again" to mean something.
    static func hasSeasons(_ samples: [Sample]) -> Bool {
        let byVolume = Dictionary(grouping: samples, by: \.volume)
        guard byVolume.count > 1 else { return false }

        let volumes = byVolume.keys.sorted()
        for (index, volume) in volumes.enumerated() where index > 0 {
            let previous = byVolume[volumes[index - 1]] ?? []
            let current = byVolume[volume] ?? []
            guard let previousHighest = previous.map(\.chapter).max(),
                  let currentLowest = current.map(\.chapter).min()
            else { continue }
            // Starting again, rather than merely starting lower. Both halves
            // matter: without the ceiling a volume split reads as a season,
            // and without the run length a two-release series does.
            if currentLowest <= Self.restartCeiling, previousHighest >= Self.minimumRun {
                return true
            }
        }
        return false
    }

    /// The season a series is currently releasing, or nil where it has none.
    static func currentSeason(_ samples: [Sample]) -> Int? {
        guard hasSeasons(samples) else { return nil }
        // The newest release, not the highest volume: a straggler from an
        // earlier season posted late should not roll the season back.
        return samples.max { $0.date < $1.date }?.volume
    }

    /// "Season 3 · chapter 235", or just the chapter where there are no
    /// seasons, or nothing where there is no release history.
    static func describe(_ samples: [Sample]) -> String? {
        guard let newest = samples.max(by: { $0.date < $1.date }) else { return nil }
        let chapter = newest.chapter.rounded() == newest.chapter
            ? String(Int(newest.chapter))
            : String(newest.chapter)
        guard currentSeason(samples) != nil else { return "Chapter \(chapter)" }
        return "Season \(newest.volume) · chapter \(chapter)"
    }
}
