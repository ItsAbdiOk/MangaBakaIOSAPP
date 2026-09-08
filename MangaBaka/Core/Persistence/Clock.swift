import Foundation

/// The source of "now" for cache freshness decisions.
///
/// Injected rather than calling `Date()` directly so expiry can be tested by
/// moving time forward deliberately, instead of by sleeping. A test that sleeps
/// is slow and flaky; a test that advances a clock is neither.
protocol Clock: Sendable {
    var now: Date { get }
}

struct SystemClock: Clock {
    var now: Date { Date() }
}

/// Test double. Time only moves when a test says so.
final class TestClock: Clock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(now: Date = Date(timeIntervalSince1970: 1_757_000_000)) {
        current = now
    }

    var now: Date {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    func advance(by interval: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        current = current.addingTimeInterval(interval)
    }
}
