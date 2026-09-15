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
        /// Rows the decoder threw away because they did not match the model.
        ///
        /// Lives here rather than in a log line because the question it
        /// answers — "is the app quietly showing nineteen of twenty?" — is
        /// the same shape as the request counts beside it, and a log line is
        /// only read by whoever is already looking. Two sections have been
        /// emptied in production by one bad row (`SeriesWork`,
        /// `PublisherRecord`); after `LossyArray` they will instead be short
        /// by one, which is better and also harder to notice.
        var droppedRows = 0
        /// The most recent dropped row's own `DecodingError` description —
        /// names the coding path and the key that changed, rather than just
        /// a count with no way to tell a `tags_v2` rename from a `works`
        /// rename (wire review W10/P10, 2026-09-15). The latest rather than
        /// the first across the entry's whole lifetime, on the same logic
        /// `slowestSeconds`/`averageSeconds` use elsewhere in this type:
        /// this is a running tally for the session, and the most recent
        /// shape change is the one still worth reading.
        var lastDropReason: String?

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

    /// Counts rows a lenient array decode dropped. No request is implied —
    /// this is called after one whose count is already recorded.
    ///
    /// - Parameter reason: the first dropped row's `DecodingError`
    ///   description this batch, or nil when the caller has none (a decode
    ///   loss recorded some other way). Optional with a default so existing
    ///   call sites keep compiling; `LossyArray`'s own callers always have
    ///   one to give (W10/P10, 2026-09-15).
    func recordDropped(path: String, count: Int, reason: String? = nil) {
        guard count > 0 else { return }
        let key = Self.shape(path)
        var entry = byPath[key] ?? Entry()
        entry.droppedRows += count
        if let reason { entry.lastDropReason = reason }
        byPath[key] = entry
    }

    /// What the gate did this session (review perf W11/S18, 2026-09-15):
    /// the three numbers that make a throttle card attributable from
    /// Settings — refused here before sending, refused by the server, and
    /// how long background legs waited instead. `DataUseSection` reads them
    /// through `GateDiagnosticsProviding`.
    private(set) var localRefusalCount = 0
    private(set) var serverRateLimitCount = 0
    private(set) var backgroundWaitTotal: Double = 0

    func recordLocalRefusal() { localRefusalCount += 1 }
    func recordServerRateLimit() { serverRateLimitCount += 1 }
    func recordBackgroundWait(seconds: Double) { backgroundWaitTotal += max(0, seconds) }

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
