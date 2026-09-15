import Foundation
import os

/// "Binge a season": series the reader has not touched in a while that have
/// a whole run waiting — a season that finished, a new one that started, or
/// simply a pile of chapters since they stopped.
///
/// Abdi, 2026-09-15: "I have a lot of manga that's currently being read … I'll
/// forget to put it on pause, so paused, reading and on hold should all have
/// 'this season's finished, you should read it' … worst case, if there have
/// been 100 chapters published since wherever I stopped, that's a good place
/// to remind the user."
///
/// Three signals, cheapest last, each a pure function over what the app
/// already holds — no request is made for this row:
/// 1. The publisher's feed (only for a series whose page has been opened —
///    `ReleaseFeedService.cachedFeeds`): a season ended past the reader's
///    own, or a newer season started.
/// 2. (Not yet: MangaUpdates' latest chapter; `Cadence` carries no number.)
/// 3. MangaBaka's `total_chapters` against `progress_chapter`, refreshed by
///    every library walk: `chapterThreshold` or more waiting.
struct BingeCandidate: Identifiable, Equatable, Sendable {
    enum Reason: Equatable, Sendable {
        /// `season` finished; `waiting` is the episodes past the reader.
        case seasonComplete(season: Int, waiting: Int)
        /// A season newer than the reader's has started.
        case newSeason(season: Int)
        /// No season data; this many chapters have been published since.
        case chaptersWaiting(Int)

        var line: String {
            switch self {
            case let .seasonComplete(season, waiting):
                waiting > 0
                    ? "Season \(season) is complete · \(waiting) to read"
                    : "Season \(season) is complete"
            case let .newSeason(season):
                "Season \(season) has started"
            case let .chaptersWaiting(count):
                "\(count) chapters since you stopped"
            }
        }

        /// For ordering: the most to read first.
        var waiting: Int {
            switch self {
            case let .seasonComplete(_, waiting): waiting
            case .newSeason: 0
            case let .chaptersWaiting(count): count
            }
        }
    }

    let entry: LibraryEntry
    let series: Series
    let reason: Reason

    var id: Int { entry.seriesId }
}

enum BingeCandidates {
    /// The states a reader may have simply forgotten about. `.completed`,
    /// `.dropped` and `.planToRead` are out: the first two are decisions, and
    /// the third has no progress to measure from.
    static let states: Set<LibraryEntry.State> = [.reading, .rereading, .paused]

    /// **A guess** (Abdi's own number): chapters published past the reader's
    /// progress before it is worth a "binge" nudge with no season data.
    static let chapterThreshold = 100

    /// **A guess**: thirty days without opening the series' page is "not
    /// touched in a while". A series opened last week is being read.
    static let untouchedFor: TimeInterval = 30 * 86_400

    /// - Parameters:
    ///   - lastOpened: series id → the reader's last visit to its page
    ///     (`HistoryStore.lastOpenedDates`). A series never opened in the
    ///     app counts as untouched.
    static func find(
        in entries: [LibraryEntry], feeds: [Int: ReleaseFeed], lastOpened: [Int: Date], now: Date
    ) -> [BingeCandidate] {
        entries.compactMap { entry -> BingeCandidate? in
            guard states.contains(entry.state), let series = entry.series else { return nil }
            if let opened = lastOpened[entry.seriesId], now.timeIntervalSince(opened) < untouchedFor {
                return nil
            }
            let progress = entry.progressChapter ?? 0
            let reason = feeds[entry.seriesId].flatMap { seasonReason(feed: $0, progress: progress) }
                ?? chaptersReason(series: series, progress: progress)
            return reason.map { BingeCandidate(entry: entry, series: series, reason: $0) }
        }
        .sorted { $0.reason.waiting > $1.reason.waiting }
    }

    /// Tier 1. The reader's season is the highest season among episodes at or
    /// below their progress; a feed with no season numbers answers nil and
    /// falls through to tier 3.
    static func seasonReason(feed: ReleaseFeed, progress: Double) -> BingeCandidate.Reason? {
        let episodes = feed.episodes
        guard episodes.contains(where: { $0.season != nil }) else { return nil }
        let readerSeason = episodes
            .filter { Double($0.number ?? 0) <= progress }
            .compactMap(\.season).max() ?? 0
        let waiting = episodes.filter { Double($0.number ?? 0) > progress }.count
        if let ended = feed.endedSeason, ended > readerSeason {
            return .seasonComplete(season: ended, waiting: waiting)
        }
        if let latest = episodes.compactMap(\.season).max(), latest > readerSeason {
            return .newSeason(season: latest)
        }
        return nil
    }

    /// Tier 3.
    static func chaptersReason(series: Series, progress: Double) -> BingeCandidate.Reason? {
        guard let total = series.totalChapters, total.isFinite else { return nil }
        let waiting = Int(exactly: (total - progress).rounded(.down)) ?? 0
        return waiting >= chapterThreshold ? .chaptersWaiting(waiting) : nil
    }
}

/// Builds the row for the library screen from the cached feeds and the
/// history — no request, so it costs nothing to show on every visit.
@MainActor
@Observable
final class BingeModel {
    private let repository: any SeriesRepositoryProtocol
    private let releaseFeeds: ReleaseFeedService
    private let history: HistoryStore
    private let clock: any Clock
    private(set) var candidates: [BingeCandidate] = []
    private var loadedFor: Set<Int>?

    private static let logger = Logger(subsystem: "dev.abdirahmanmohamed.mangabaka", category: "library")

    init(
        repository: any SeriesRepositoryProtocol, releaseFeeds: ReleaseFeedService, history: HistoryStore,
        clock: any Clock = SystemClock()
    ) {
        self.repository = repository
        self.releaseFeeds = releaseFeeds
        self.history = history
        self.clock = clock
    }

    func load(entries: [LibraryEntry]) async {
        let ids = Set(entries.filter { BingeCandidates.states.contains($0.state) }.map(\.seriesId))
        guard loadedFor != ids else { return }
        let eligible = entries.filter { BingeCandidates.states.contains($0.state) }
        // Same zero-request path `refreshReminders` uses: cached links, then
        // cached feeds, nothing fetched.
        let links = await repository.cachedExtrasLinks(for: eligible.map(\.seriesId))
        let feeds = await releaseFeeds.cachedFeeds(for: eligible) { links[$0] ?? [] }
        let lastOpened: [Int: Date]
        do {
            lastOpened = try await history.lastOpenedDates()
        } catch {
            Self.logger.error("binge: lastOpenedDates failed: \(String(describing: error), privacy: .public)")
            lastOpened = [:]
        }
        candidates = BingeCandidates.find(in: eligible, feeds: feeds, lastOpened: lastOpened, now: clock.now)
        loadedFor = ids
    }
}
