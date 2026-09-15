import Foundation
import os

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

    /// R20/P20: `load`/`save` were bare `try?` — a follow that silently
    /// failed to persist looked, from outside, identical to one that was
    /// never taken.
    private static let logger = Logger(
        subsystem: "dev.abdirahmanmohamed.mangabaka", category: "reader"
    )

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

            // Background: a follow check runs on its own schedule, not
            // because the reader asked right now, so it must not spend the
            // window a reader's own search needs (2026-09-13).
            let result = await repository.search(query, priority: .background)
            if case let .staleAfter(error) = result.origin, case .rateLimited = error {
                // Never retry into a 429: the remaining due follows would
                // each ask the same question and earn the same refusal one at
                // a time. Stop the whole run rather than mark this follow
                // checked — it genuinely was not — so the next run (or the
                // once-a-day throttle lapsing) tries it again instead of
                // waiting a full day over a refusal that had nothing to do
                // with whether anything new came out.
                break
            }
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
        // A missing file is the ordinary first-launch case and is not
        // logged; a file that exists but fails to decode is worth a line.
        guard let data = try? Data(contentsOf: url) else { return [] }
        do {
            return try JSONDecoder().decode([Follow].self, from: data)
        } catch {
            let description = String(describing: error)
            logger.error("Publisher follows decode failed: \(description, privacy: .public)")
            return []
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(follows) else {
            Self.logger.error("Publisher follows encode failed")
            return
        }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: .atomic)
        } catch {
            let description = String(describing: error)
            Self.logger.error("Publisher follows write failed: \(description, privacy: .public)")
        }
    }
}
