import Foundation

/// A publisher, studio, or creator the reader wants to hear about again.
///
/// Reversible, so it is not the shelf and not the library — following REDICE
/// STUDIO says "tell me when they put something new out", nothing about
/// reading it. Persisted as its own JSON file in Application Support rather
/// than a row in the GRDB database: the follow list is small, unrelated to
/// anything cached from the API, and another agent's work this same round
/// touches the database's own schema — this store deliberately does not.
@MainActor
@Observable
final class PublisherFollows {
    enum Kind: String, Codable, Sendable {
        case publisher, author
    }

    struct Follow: Codable, Identifiable, Equatable, Sendable {
        let name: String
        let kind: Kind
        /// The newest series id seen for this name, last time `check` ran.
        /// Nil only before the first check has ever completed.
        var lastSeenSeriesID: Int?
        let followedAt: Date
        /// When `check` last actually queried the API for this follow, so
        /// the once-a-day throttle can tell "already checked today" from
        /// "never checked".
        var lastCheckedAt: Date?

        var id: String { "\(kind.rawValue)-\(name)" }
    }

    /// A follow whose top series changed since the last check — the thing
    /// worth a notification about.
    struct Update: Equatable, Sendable {
        let follow: Follow
        let seriesTitle: String
    }

    /// A guess: once a day. Each check spends one of the API's own
    /// 30-requests-a-minute search budget (`limit=1` still counts), and a
    /// publisher does not put out new work often enough that checking more
    /// often would ever catch anything sooner in practice.
    static let checkInterval: TimeInterval = 60 * 60 * 24

    private(set) var follows: [Follow] = []
    private let fileURL: URL
    private let now: () -> Date

    /// Where the app's own data normally lives; falls back to a temporary
    /// directory only if that location cannot be found, so a follow taken
    /// during that rare failure at least survives for the current launch
    /// instead of crashing.
    private static var defaultDirectory: URL {
        (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )) ?? FileManager.default.temporaryDirectory
    }

    init(directory: URL = PublisherFollows.defaultDirectory, now: @escaping () -> Date = Date.init) {
        fileURL = directory.appendingPathComponent("publisher-follows.json")
        self.now = now
        follows = Self.load(from: fileURL)
    }

    func isFollowing(_ name: String, kind: Kind) -> Bool {
        follows.contains { $0.name == name && $0.kind == kind }
    }

    func follow(_ name: String, kind: Kind) {
        guard !isFollowing(name, kind: kind) else { return }
        follows.append(
            Follow(name: name, kind: kind, lastSeenSeriesID: nil, followedAt: now(), lastCheckedAt: nil)
        )
        save()
    }

    func unfollow(_ name: String, kind: Kind) {
        guard isFollowing(name, kind: kind) else { return }
        follows.removeAll { $0.name == name && $0.kind == kind }
        save()
    }

    /// Looks for something new from every follow due a check, at most once a
    /// day each.
    ///
    /// The first check a follow ever gets only records what is at the top —
    /// there is nothing yet to compare it against, and reporting "new from
    /// X" about the series that was already there when the reader followed
    /// it would be a false alarm on the very first check.
    ///
    /// - Parameters:
    ///   - repository: searched with `publisher=`/`staff=`, sorted newest,
    ///     one result — the same search the publisher page itself runs.
    ///   - notify: called once per follow whose top series changed, so the
    ///     caller can turn it into an actual notification
    ///     (`ReleaseReminders.notify`) without this type depending on that
    ///     one. Defaults to doing nothing, for callers that only want the
    ///     returned list (tests, mainly).
    @discardableResult
    func check(
        using repository: any SeriesRepositoryProtocol,
        notify: (Follow, String) async -> Void = { _, _ in }
    ) async -> [Update] {
        var updates: [Update] = []
        let currentNow = now()

        for index in follows.indices {
            let follow = follows[index]
            if let lastChecked = follow.lastCheckedAt,
               currentNow.timeIntervalSince(lastChecked) < Self.checkInterval {
                continue
            }

            var query = SearchQuery()
            switch follow.kind {
            case .publisher: query.publisher = follow.name
            case .author: query.staff = follow.name
            }
            query.sort = "latest"
            query.limit = 1

            let result = await repository.search(query)
            follows[index].lastCheckedAt = currentNow
            guard let top = result.series.first else { continue }
            defer { follows[index].lastSeenSeriesID = top.id }

            if let lastSeen = follow.lastSeenSeriesID, lastSeen != top.id {
                let title = top.displayTitle ?? follow.name
                updates.append(Update(follow: follows[index], seriesTitle: title))
                await notify(follows[index], title)
            }
        }

        save()
        return updates
    }

    private static func load(from url: URL) -> [Follow] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([Follow].self, from: data)) ?? []
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(follows) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? data.write(to: fileURL, options: .atomic)
    }
}
