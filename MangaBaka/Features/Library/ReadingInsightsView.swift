import SwiftUI

/// What the reader's own library says about them.
///
/// Six things, none of which any catalogue can answer, all computed on the
/// device from data the app already has:
///
/// - what is waiting for you
/// - what finished without telling you
/// - how much you have actually read
/// - which tags you finish
/// - which tags you abandon
/// - how you rate what you read
///
/// The last three are drawn only from series that arrived with tags, so the
/// screen says how much of the library that is. A verdict on 87 of 939 series
/// is a different claim from a verdict on all of them.
struct ReadingInsightsView: View {
    let entries: [LibraryEntry]
    /// False while the library walk this was built from is still going.
    /// Defaulted to `true` so every existing call site keeps compiling and
    /// behaving exactly as before until the shell (batch 6) passes the real
    /// value from `LibraryModel.isComplete`.
    var isComplete = true
    /// Work-list 85: count-plus-completedness does not move when a rating
    /// or a state changes through `LibraryModel.apply(_:to:)`, so "It
    /// finished without telling you" kept listing a series the reader had
    /// just marked Completed. `LibraryModel.revision` bumps on any change to
    /// `entries`, including a one-row patch. Defaulted so a preview or a test
    /// that passes rows directly keeps working.
    var libraryRevision = 0

    @Binding var path: [Series]
    @Environment(\.zoomRoute) private var zoomRoute

    /// Computed once when the library arrives, not on every body pass.
    ///
    /// **Measured before this was stored:** the four together took 19ms against
    /// a 1,000-entry library, and SwiftUI evaluates a body far more often than
    /// a person changes anything. A frame is 16.7ms, so scrolling this screen
    /// was dropping them. The tag verdicts alone are 13ms — a thousand entries
    /// at forty tags each is forty thousand dictionary touches.
    @State private var derived = Derived()
    /// Gap 93: `derived` starts at its all-zero default and the first real
    /// pass is a detached, off-main-actor computation — there is a real,
    /// visible window where this screen would otherwise show "0 chapters"
    /// before flipping to the true number. This is the loading branch that
    /// window needs, decided before the empty/content branches rather than
    /// after them.
    @State private var hasComputed = false

    /// What `.task(id:)` keys the recompute on. `entries` alone is not
    /// `Hashable`/`Equatable` as a `.task` id in a way that is cheap to
    /// compare, and a `let` property does not re-trigger a `.task {}` with no
    /// id at all when a parent hands this view a new array — which is why
    /// this screen used to show stale insights after a library reload landed
    /// while it was open. Count plus completedness is enough to catch both a
    /// changed library and a walk finishing.
    private var revision: String { "\(entries.count)-\(isComplete)-\(libraryRevision)" }

    private struct Derived {
        var waiting: [ReadingInsights.Behind] = []
        var nearly: [ReadingInsights.Behind] = []
        var verdicts: [ReadingInsights.TagVerdict] = []
        var sample: (seen: Int, total: Int) = (0, 0)
        var droppedLine: String?
        var chapters = 0
        var hours: Double = 0
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                // Gap 93 (decision: say "based on N of M" rather than hide):
                // a partial library still has something to say about the
                // part that loaded, and hiding the whole screen until a
                // 900-series walk finishes would be a worse answer than
                // naming the number it is built from.
                if !isComplete {
                    StaleBar(
                        headline: "Built from the \(entries.count.formatted()) series that loaded",
                        detail: "This updates once the rest of your library finishes loading."
                    )
                }
                if !hasComputed {
                    loading
                } else if !ReadingInsights.hasAnythingToSay(entries) {
                    EmptyState(
                        title: "Nothing to say yet",
                        message: """
                        Read a few chapters, finish something, or drop something you \
                        didn't like — these come from your library once there is a \
                        pattern in it.
                        """
                    )
                    .padding(.top, 20)
                } else {
                    readingTime
                    if !derived.nearly.isEmpty { finishedSection }
                    if !derived.waiting.isEmpty { catchUpSection }
                    if !derived.verdicts.isEmpty { tasteSection }
                }
            }
            .padding(.horizontal, Metrics.gutter)
            .padding(.top, Metrics.scrollTopInset)
            .padding(.bottom, Metrics.scrollBottomInset)
        }
        .scrollIndicators(.hidden)
        .background(Palette.ground)
        .scrollEdgeEffectStyle(.hard, for: .top)
        .navigationTitle("Your reading")
        .navigationBarTitleDisplayMode(.inline)
        // Keyed on `revision` rather than run once: a plain `.task {}` only
        // fires the first time this view's identity appears, so a library
        // reload landing while this screen was already open never
        // recomputed anything (gap 93).
        .task(id: revision) { await recompute() }
    }

    private var loading: some View {
        VStack(alignment: .leading, spacing: 10) {
            Capsule().fill(Palette.surface).frame(width: 160, height: 26)
            Capsule().fill(Palette.surface).frame(width: 220, height: 14)
        }
        .shimmering()
        .accessibilityHidden(true)
    }

    /// Off the main actor, because it is tens of milliseconds of pure work on a
    /// real library and the screen it is for should still scroll while it runs.
    private func recompute() async {
        let rows = entries
        let computed = await Task.detached(priority: .userInitiated) {
            Derived(
                waiting: ReadingInsights.waiting(in: rows),
                nearly: ReadingInsights.nearlyFinished(in: rows),
                verdicts: ReadingInsights.verdicts(in: rows),
                sample: ReadingInsights.sampleSize(in: rows),
                droppedLine: ReadingInsights.droppedLine(in: rows),
                chapters: ReadingInsights.chaptersRead(in: rows),
                hours: ReadingInsights.hoursRead(in: rows)
            )
        }.value
        derived = computed
        hasComputed = true
    }

    // MARK: - Time

}

/// The screen's sections, split out of the type above purely to stay under
/// SwiftLint's `type_body_length` — the loading/empty branches this batch
/// added (gap 93) pushed the single declaration over it.
extension ReadingInsightsView {
    private var readingTime: some View {
        let hours = derived.hours
        let chapters = derived.chapters
        return VStack(alignment: .leading, spacing: 6) {
            Text("\(chapters.formatted()) chapters")
                .typeScreenTitle()
                .foregroundStyle(Palette.textEmphasis)
            // "About", always. Nobody records reading time, so this is chapters
            // times a per-format estimate and the screen should not pretend
            // otherwise.
            Text("""
            About \(Int(wholeOrClamped: hours.rounded()).formatted()) hours, going by how long \
            a chapter usually takes.
            """)
                .typeSubtitle()
                .foregroundStyle(Palette.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Where you stopped

    private var finishedSection: some View {
        section(
            "It finished without telling you",
            note: "These have ended, and you are a few chapters short."
        ) {
            ForEach(derived.nearly.prefix(6)) { item in
                row(item, trailing: "\(item.waiting) left")
            }
        }
    }

    private var catchUpSection: some View {
        section(
            "Waiting for you",
            note: """
            Chapters published since you stopped. The schedule says what is \
            coming; this is what is already here.
            """
        ) {
            ForEach(derived.waiting.prefix(8)) { item in
                row(item, trailing: "\(item.waiting) behind", showEstimate: true)
            }
        }
    }

    private func row(
        _ item: ReadingInsights.Behind,
        trailing: String,
        showEstimate: Bool = false
    ) -> some View {
        Button {
            guard let series = item.series else { return }
            zoomRoute?.source = ZoomRoute.id("insights", series.id)
            path.append(series)
        } label: {
            HStack(spacing: 12) {
                if let series = item.series {
                    CoverImage(
                        cover: series.cover,
                        width: 38,
                        radius: 5,
                        accessibilityText: series.displayTitle ?? "Cover art"
                    )
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.series?.displayTitle ?? "Untitled series")
                        .typeRowTitle()
                        .foregroundStyle(Palette.textPrimary)
                        .lineLimit(1)
                    Text(Self.progressLine(item, showEstimate: showEstimate))
                        .typeSmallMeta()
                        .foregroundStyle(Palette.textMuted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(trailing)
                    .typeSmallMeta()
                    .foregroundStyle(Palette.accent)
            }
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.press)
        .zoomSource("insights", item.entry.seriesId)
        .accessibilityElement(children: .combine)
    }

    nonisolated static func progressLine(
        _ item: ReadingInsights.Behind, showEstimate: Bool = false
    ) -> String {
        // L7: `Int(...)` truncated a half chapter to a whole one here, though
        // not in the editor for the same entry.
        let read = LibraryEditSheet.chapterText(item.entry.progressChapter ?? 0)
        let total = Int(wholeOrClamped: item.series?.totalChapters ?? 0)
        var line = "\(item.entry.state.title) · ch \(read) of \(total)"
        // "Waiting for you" only: a filter, not a promise — see ReadingTime.
        // Left off "It finished without telling you" on purpose, the caller
        // controls that via `showEstimate`.
        if showEstimate,
           let estimate = ReadingTime.label(chapters: Double(item.waiting), type: item.series?.type) {
            line += " · \(estimate)"
        }
        return line
    }

    // MARK: - What you like

    /// A tag is "what you finish" when the reader completed at least this
    /// share of the series carrying it, and "what you give up on" at or below
    /// the other. GUESSES: neither is derived from anyone's library. They are
    /// far enough apart that a tag cannot be both, which is the only property
    /// relied on; the gap in between is deliberately unlabelled.
    private static let finishThreshold = 0.6
    private static let abandonThreshold = 0.3

    private var tasteSection: some View {
        let finishes = derived.verdicts
            .filter { ($0.completionRate ?? 0) >= Self.finishThreshold }
            .prefix(6)
        let abandons = derived.verdicts
            .filter { ($0.completionRate ?? 1) <= Self.abandonThreshold }
            .prefix(6)

        return VStack(alignment: .leading, spacing: 22) {
            if !finishes.isEmpty {
                section("What you finish", note: nil) {
                    ForEach(Array(finishes)) { verdict in
                        verdictRow(verdict)
                    }
                }
            }
            if !abandons.isEmpty {
                section("What you give up on", note: derived.droppedLine) {
                    ForEach(Array(abandons)) { verdict in
                        verdictRow(verdict)
                    }
                }
            }
            // Said plainly rather than buried: a verdict drawn from part of the
            // library is a different claim from one drawn from all of it.
            Text("""
            From the \(derived.sample.seen.formatted()) of your \
            \(derived.sample.total.formatted()) series we have tags for.
            """)
                .typeFootnote()
                .foregroundStyle(Palette.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func verdictRow(_ verdict: ReadingInsights.TagVerdict) -> some View {
        HStack(spacing: 12) {
            Text(verdict.name)
                .typeRowTitle()
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 8)
            if let rating = verdict.rating {
                Text(String(format: "%.1f★", rating))
                    .typeSmallMeta()
                    .foregroundStyle(Palette.textMuted)
            }
            Text(verdictLine(verdict))
                .typeSmallMeta()
                .foregroundStyle(Palette.accent)
        }
        .padding(.vertical, 7)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLine(verdict))
    }

    /// "8 of 11", which is the whole claim in four characters.
    private func verdictLine(_ verdict: ReadingInsights.TagVerdict) -> String {
        let decided = verdict.finished + verdict.dropped
        guard decided > 0 else { return "\(verdict.read) read" }
        return "\(verdict.finished) of \(decided)"
    }

    private func accessibilityLine(_ verdict: ReadingInsights.TagVerdict) -> String {
        let decided = verdict.finished + verdict.dropped
        var parts = ["\(verdict.name), read \(verdict.read)"]
        if decided > 0 { parts.append("finished \(verdict.finished) of \(decided)") }
        if let rating = verdict.rating { parts.append(String(format: "rated %.1f of 5", rating)) }
        return parts.joined(separator: ", ")
    }

    private func section(
        _ title: String,
        note: String?,
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .typeSubsectionHeader()
                .foregroundStyle(Palette.textPrimary)
            if let note {
                Text(note)
                    .typeSmallMeta()
                    .foregroundStyle(Palette.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 0) { content() }
        }
    }
}
