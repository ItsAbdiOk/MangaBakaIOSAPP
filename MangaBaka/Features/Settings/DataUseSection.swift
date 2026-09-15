import SwiftUI

/// S18/W11: nothing today counts local refusals, server 429s, or background
/// wait seconds, so "was I throttled this session?" can only be answered
/// live in a debugger (`docs/reviews/perf/SUMMARY.md` §6, §8 #14). The
/// counters belong beside `NetworkLedger`'s per-endpoint tallies and are
/// wire's to add, not this file's — `NetworkLedger` is outside this agent's
/// files. This protocol is the seam: the default below answers `nil` ("not
/// counted yet"), so `DataUseSection` compiles today and the throttle row
/// stays hidden; a stored or computed property added to `NetworkLedger`
/// under one of these three exact names and types satisfies the requirement
/// directly and wins over the default automatically, with nothing to change
/// here when it lands. `async` on every requirement because `NetworkLedger`
/// is an actor and a real property there can only be read that way; the
/// default below is not actor-isolated and returns at once.
protocol GateDiagnosticsProviding {
    var localRefusals: Int? { get async }
    var serverRateLimits: Int? { get async }
    var backgroundWaitSeconds: Double? { get async }
}

extension GateDiagnosticsProviding {
    var localRefusals: Int? {
        get async { nil }
    }
    var serverRateLimits: Int? {
        get async { nil }
    }
    var backgroundWaitSeconds: Double? {
        get async { nil }
    }
}

extension NetworkLedger: GateDiagnosticsProviding {
    var localRefusals: Int? {
        get async { localRefusalCount }
    }
    var serverRateLimits: Int? {
        get async { serverRateLimitCount }
    }
    var backgroundWaitSeconds: Double? {
        get async { backgroundWaitTotal }
    }
}

/// What this session has cost, in bytes and in milliseconds.
///
/// **Not analytics.** Nothing here is uploaded, nothing is stored, and it is
/// empty again next launch. It exists so the answer to "how heavy is this app?"
/// is a number the reader can see rather than a claim the developer makes.
///
/// It is also the only place the API's actual speed is visible. Every previous
/// answer to "is the API fast?" in this project was about response shapes.
struct DataUseSection: View {
    /// Optional so previews and tests can render without one.
    var taste: TasteProfile?

    @State private var seenSeries = 0
    @State private var countedSeries = 0
    @State private var knownTags = 0
    @State private var total = 0
    @State private var requests = 0
    @State private var images = 0
    /// Every row `getLossy` threw away this session, across all endpoints.
    ///
    /// Session-wide and not only per-endpoint because the expanded list is
    /// the *eight slowest* paths: a fast endpoint that drops rows would never
    /// appear in it, and item 20's whole point is that a silent drop must be
    /// countable somewhere. This line is always on screen.
    @State private var droppedRows = 0
    @State private var slowest: [(path: String, entry: NetworkLedger.Entry)] = []
    @State private var isExpanded = false
    /// S18/W11. `nil` until `NetworkLedger` actually counts one of these —
    /// see `GateDiagnosticsProviding` above.
    @State private var localRefusals: Int?
    @State private var serverRateLimits: Int?
    @State private var backgroundWaitSeconds: Double?

    var body: some View {
        SettingsSection(title: "Data used", caption: caption) {
            VStack(alignment: .leading, spacing: 12) {
                SettingsCard {
                    SettingsRow(title: "This session", caption: breakdown) {
                        Text(format(total))
                            .typeRowTitle()
                            .foregroundStyle(Palette.accent)
                    }
                    SettingsDivider()
                    // Both numbers, because together they diagnose the one way
                    // this feature fails quietly: series counted but no tags
                    // known means the payload those series arrived in carried
                    // none, and nothing else on screen would say so.
                    SettingsRow(title: "Taste profile", caption: tasteCaption) {
                        Text("\(knownTags)")
                            .typeRowTitle()
                            .foregroundStyle(knownTags > 0 ? Palette.accent : Palette.textTertiary)
                    }
                }

                // S18/W11: shown only once something has actually been
                // counted, so an unthrottled session (or a build without the
                // ledger fields yet) draws nothing extra here.
                if let throttleCaption = Self.throttleCaption(
                    localRefusals: localRefusals,
                    serverRateLimits: serverRateLimits,
                    backgroundWaitSeconds: backgroundWaitSeconds
                ) {
                    SettingsCard {
                        SettingsRow(title: "Throttling this session", caption: throttleCaption) {}
                    }
                }

                if !slowest.isEmpty {
                    Button {
                        // `Motion.settle`: a disclosure is content arriving
                        // (or leaving), the same category sheets and lists
                        // assembling already use — not a tap being answered.
                        Motion.run(Motion.settle) { isExpanded.toggle() }
                    } label: {
                        Text(isExpanded ? "Hide the detail" : "The eight slowest")
                            .typeInstruction()
                            .foregroundStyle(Palette.accent)
                    }
                    .buttonStyle(.press)

                    if isExpanded {
                        // Named as a top-eight rather than a breakdown. Read as
                        // a breakdown, the numbers do not add up to the total
                        // and the list quietly discredits itself.
                        SettingsCard {
                            ForEach(Array(slowest.enumerated()), id: \.offset) { index, row in
                                endpointRow(row).arrives(index: index)
                                if index < slowest.count - 1 { SettingsDivider() }
                            }
                        }
                    }
                }
            }
        }
        .task { await refresh() }
    }

    private var caption: String {
        """
        Counted on this phone and never sent anywhere. It resets when the app \
        closes.
        """
    }

    private var tasteCaption: String {
        guard seenSeries > 0 else {
            return "Nothing counted yet. Open a series you have read."
        }
        // Seen but not counted is the one quiet failure this feature has: the
        // series arrived without tags. Said in numbers, so it can be seen.
        let untagged = seenSeries - countedSeries
        guard countedSeries > 0 else {
            return "\(seenSeries) series seen, and none of them carried tags"
        }
        return untagged > 0
            ? "\(countedSeries) series counted · \(knownTags) tags known · \(untagged) had no tags"
            : "\(countedSeries) series counted · \(knownTags) tags known"
    }

    private var breakdown: String {
        guard requests > 0 else { return "Nothing fetched yet" }
        // Images are named separately because they are almost all of it, and
        // lumping them in hides the one number worth doing anything about.
        return Self.breakdownCaption(
            requests: requests, images: format(images), droppedRows: droppedRows
        )
    }

    /// `nonisolated static` so the string is testable without a view.
    nonisolated static func breakdownCaption(requests: Int, images: String, droppedRows: Int) -> String {
        let base = "\(requests) requests · \(images) of it cover art"
        guard droppedRows > 0 else { return base }
        return base + " · \(droppedRows) row\(droppedRows == 1 ? "" : "s") the app couldn't read"
    }

    private func endpointRow(_ row: (path: String, entry: NetworkLedger.Entry)) -> some View {
        SettingsRow(
            title: row.path,
            caption: Self.endpointCaption(
                calls: row.entry.requests,
                bytes: format(row.entry.bytes),
                droppedRows: row.entry.droppedRows,
                failures: row.entry.failures
            )
        ) {
            VStack(alignment: .trailing, spacing: 1) {
                Text(milliseconds(row.entry.averageSeconds))
                    .typeRowTitle()
                    .foregroundStyle(Palette.textPrimary)
                Text("worst \(milliseconds(row.entry.slowestSeconds))")
                    .typeFootnote()
                    .foregroundStyle(Palette.textMuted)
            }
        }
    }

    /// Item 20: `NetworkLedger.Entry.droppedRows` was written by fourteen
    /// `getLossy` call sites and read by nothing, so `LossyArray`'s own stated
    /// justification — "is the app quietly showing nineteen of twenty?" — could
    /// not be answered anywhere in the app. A lossy decode that silently drops
    /// a row is strictly worse than a strict one that empties a section, unless
    /// something counts the drops out loud. This is the only place that does.
    ///
    /// `nonisolated static` so the string is testable without a view.
    ///
    /// S17: `failures` (`NetworkLedger.Entry.failures`) was written at every
    /// `record(path:bytes:seconds:failed:)` call and read by nothing — the
    /// one number that says "this endpoint is being refused" was the one
    /// this screen omitted. Same shape as `droppedRows` above it.
    nonisolated static func endpointCaption(
        calls: Int, bytes: String, droppedRows: Int, failures: Int = 0
    ) -> String {
        var caption = "\(calls) calls · \(bytes)"
        if droppedRows > 0 {
            caption += " · \(droppedRows) row\(droppedRows == 1 ? "" : "s") dropped"
        }
        if failures > 0 {
            caption += " · \(failures) failed"
        }
        return caption
    }

    /// S18/W11. `nil` when nothing has been counted, so a session with no
    /// throttling (or a build ahead of the ledger fields) draws no row at
    /// all — see `GateDiagnosticsProviding` above `DataUseSection`.
    /// `nonisolated static` so the string is testable without a view.
    nonisolated static func throttleCaption(
        localRefusals: Int?, serverRateLimits: Int?, backgroundWaitSeconds: Double?
    ) -> String? {
        var parts: [String] = []
        if let localRefusals, localRefusals > 0 {
            parts.append("\(localRefusals) refused locally")
        }
        if let serverRateLimits, serverRateLimits > 0 {
            parts.append("\(serverRateLimits) server 429\(serverRateLimits == 1 ? "" : "s")")
        }
        if let backgroundWaitSeconds, backgroundWaitSeconds > 0 {
            parts.append("\(Int(backgroundWaitSeconds.rounded()))s waited in the background")
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " · ")
    }

    private func format(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private func milliseconds(_ seconds: Double) -> String {
        seconds >= 1
            ? String(format: "%.1fs", seconds)
            : "\(Int((seconds * 1000).rounded()))ms"
    }

    private func refresh() async {
        if let taste {
            let counts = await taste.diagnostics()
            seenSeries = counts.seen
            countedSeries = counts.series
            knownTags = counts.tags
        }
        total = await NetworkLedger.shared.totalBytes
        requests = await NetworkLedger.shared.totalRequests
        images = await NetworkLedger.shared.imageBytes
        slowest = await NetworkLedger.shared.slowest()
        droppedRows = await NetworkLedger.shared.byPath.values.reduce(0) { $0 + $1.droppedRows }
        localRefusals = await NetworkLedger.shared.localRefusals
        serverRateLimits = await NetworkLedger.shared.serverRateLimits
        backgroundWaitSeconds = await NetworkLedger.shared.backgroundWaitSeconds
    }
}
