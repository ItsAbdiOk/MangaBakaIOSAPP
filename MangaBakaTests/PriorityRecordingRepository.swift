import Foundation
@testable import MangaBaka

/// A stub that records *which* `count`/`search` overload it was asked
/// through, and at what priority.
///
/// Its own file rather than a change to `StubRepositoryBase`
/// (`SeriesFactory.swift`), which `SearchModelTests` and a dozen other
/// suites subclass — that file is shared, and a change to the base's
/// signatures would ripple into suites owned by other work.
///
/// Why it exists (search review, tests finding 11): every stub in `LensTests`
/// overrides the plain `count(_:)`, and the protocol extension in
/// `SeriesRepository+Priority.swift` forwards the priority-taking call to it,
/// dropping the priority on the floor. So nothing could tell
/// `repository.count(q, priority: .background)` from
/// `repository.count(q)` — the very thing the 2026-09-13 lens-count change
/// was about. This stub overrides *both* overloads: the priority-taking one
/// records the priority it was given, the plain one records `nil`, so an
/// ask that bypassed the priority-aware path shows up as a `nil` in the log
/// rather than vanishing into the default.
final class PriorityRecordingRepository: StubRepositoryBase, @unchecked Sendable {
    private let lock = NSLock()
    private var countLog: [RequestPriority?] = []
    private var searchLog: [RequestPriority?] = []
    /// What `count` answers. Non-nil so `LensCounts` treats each ask as
    /// answered and walks on (a nil stops the walk — see
    /// `LensCounts.load`'s 429 guard).
    let answer: Int?

    init(answer: Int? = 9) {
        self.answer = answer
    }

    /// One entry per `count` ask, in order: the priority it arrived with, or
    /// `nil` when it came through the priority-less overload.
    var countPriorities: [RequestPriority?] {
        lock.lock(); defer { lock.unlock() }
        return countLog
    }

    /// Same, for `search`.
    var searchPriorities: [RequestPriority?] {
        lock.lock(); defer { lock.unlock() }
        return searchLog
    }

    /// Every search-family ask — `SeriesRepository` sends both `count` and
    /// `search` to `/v2/series/search`, so against the real client they
    /// share the 30/min window.
    var searchFamilyAsks: Int { countPriorities.count + searchPriorities.count }

    override func count(_ query: SearchQuery) async -> Int? {
        record(count: nil)
        return answer
    }

    override func count(_ query: SearchQuery, priority: RequestPriority) async -> Int? {
        record(count: priority)
        return answer
    }

    override func search(_ query: SearchQuery) async -> FeedResult {
        record(search: nil)
        return FeedResult(series: [], origin: .network)
    }

    override func search(_ query: SearchQuery, priority: RequestPriority) async -> FeedResult {
        record(search: priority)
        return FeedResult(series: [], origin: .network)
    }

    /// Synchronous, because NSLock is unavailable from an async context.
    private func record(count priority: RequestPriority?) {
        lock.lock(); defer { lock.unlock() }
        countLog.append(priority)
    }

    private func record(search priority: RequestPriority?) {
        lock.lock(); defer { lock.unlock() }
        searchLog.append(priority)
    }
}
