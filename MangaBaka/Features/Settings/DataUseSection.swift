import SwiftUI

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
                droppedRows: row.entry.droppedRows
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
    nonisolated static func endpointCaption(calls: Int, bytes: String, droppedRows: Int) -> String {
        let base = "\(calls) calls · \(bytes)"
        guard droppedRows > 0 else { return base }
        return base + " · \(droppedRows) row\(droppedRows == 1 ? "" : "s") dropped"
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
    }
}
