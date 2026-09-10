import Foundation

/// What the app actually costs, in bytes and in milliseconds.
///
/// **Local only, and it never leaves the device.** This is not analytics: there
/// is no account behind it, no identifier, nothing is uploaded, and it is
/// emptied when the app quits. It exists because "is the API fast?" and "how
/// data-heavy is this?" had been answered dozens of times by looking at response
/// *shapes* and exactly zero times by measuring.
///
/// Kept as a running tally rather than a log of every request: a log is a
/// record of what someone read, and this only ever needs to answer how much and
/// how long.
actor NetworkLedger {
    static let shared = NetworkLedger()

    /// One endpoint's tally. Keyed by path with the ids stripped, so
    /// `/v1/series/3397` and `/v1/series/8` are one row rather than two
    /// thousand.
    struct Entry: Sendable, Equatable {
        var requests = 0
        var bytes = 0
        var totalSeconds: Double = 0
        var slowestSeconds: Double = 0
        var failures = 0

        var averageSeconds: Double { requests > 0 ? totalSeconds / Double(requests) : 0 }
    }

    private(set) var byPath: [String: Entry] = [:]
    private(set) var imageBytes = 0
    private(set) var imageCount = 0

    func record(path: String, bytes: Int, seconds: Double, failed: Bool = false) {
        let key = Self.shape(path)
        var entry = byPath[key] ?? Entry()
        entry.requests += 1
        entry.bytes += bytes
        entry.totalSeconds += seconds
        entry.slowestSeconds = max(entry.slowestSeconds, seconds)
        if failed { entry.failures += 1 }
        byPath[key] = entry
    }

    func recordImage(bytes: Int) {
        imageBytes += bytes
        imageCount += 1
    }

    /// Total bytes over the wire this session, images included.
    ///
    /// Images are counted separately as well, because they are almost all of it
    /// and lumping them in hides the one number worth acting on.
    var totalBytes: Int {
        byPath.values.reduce(imageBytes) { $0 + $1.bytes }
    }

    var totalRequests: Int {
        byPath.values.reduce(imageCount) { $0 + $1.requests }
    }

    /// Endpoints worth looking at first: slowest average, then heaviest.
    func slowest(limit: Int = 8) -> [(path: String, entry: Entry)] {
        byPath
            .sorted { $0.value.averageSeconds > $1.value.averageSeconds }
            .prefix(limit)
            .map { (path: $0.key, entry: $0.value) }
    }

    func reset() {
        byPath = [:]
        imageBytes = 0
        imageCount = 0
    }

    /// `/v1/series/3397/images` becomes `/v1/series/{id}/images`.
    ///
    /// Without this the tally is one row per series and answers nothing. A
    /// segment counts as an id when it is all digits or looks like a UUID.
    static func shape(_ path: String) -> String {
        path
            .split(separator: "/", omittingEmptySubsequences: false)
            .map { segment -> String in
                guard !segment.isEmpty else { return String(segment) }
                let isNumber = segment.allSatisfy(\.isNumber)
                let isUUID = segment.count == 36 && segment.filter { $0 == "-" }.count == 4
                return isNumber || isUUID ? "{id}" : String(segment)
            }
            .joined(separator: "/")
    }
}
