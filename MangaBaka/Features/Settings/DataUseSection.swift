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
                        Motion.run(.snappy(duration: 0.22)) { isExpanded.toggle() }
                    } label: {
                        Text(isExpanded ? "Hide the detail" : "The eight slowest")
                            .typeInstruction()
                            .foregroundStyle(Palette.accent)
                    }
                    .buttonStyle(.plain)

                    if isExpanded {
                        // Named as a top-eight rather than a breakdown. Read as
                        // a breakdown, the numbers do not add up to the total
                        // and the list quietly discredits itself.
                        SettingsCard {
                            ForEach(Array(slowest.enumerated()), id: \.offset) { index, row in
                                endpointRow(row)
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
        return "\(requests) requests · \(format(images)) of it cover art"
    }

    private func endpointRow(_ row: (path: String, entry: NetworkLedger.Entry)) -> some View {
        SettingsRow(
            title: row.path,
            caption: "\(row.entry.requests) calls · \(format(row.entry.bytes))"
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
    }
}
