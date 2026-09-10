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
    @Binding var path: [Series]

    private var waiting: [ReadingInsights.Behind] { ReadingInsights.waiting(in: entries) }
    private var nearly: [ReadingInsights.Behind] { ReadingInsights.nearlyFinished(in: entries) }
    private var verdicts: [ReadingInsights.TagVerdict] { ReadingInsights.verdicts(in: entries) }
    private var sample: (seen: Int, total: Int) { ReadingInsights.sampleSize(in: entries) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                readingTime
                if !nearly.isEmpty { finishedSection }
                if !waiting.isEmpty { catchUpSection }
                if !verdicts.isEmpty { tasteSection }
            }
            .padding(.horizontal, Metrics.gutter)
            .padding(.top, Metrics.scrollTopInset)
            .padding(.bottom, Metrics.scrollBottomInset)
        }
        .scrollIndicators(.hidden)
        .background(Palette.ground)
        .navigationTitle("Your reading")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Time

    private var readingTime: some View {
        let hours = ReadingInsights.hoursRead(in: entries)
        let chapters = ReadingInsights.chaptersRead(in: entries)
        return VStack(alignment: .leading, spacing: 6) {
            Text("\(chapters.formatted()) chapters")
                .typeScreenTitle()
                .foregroundStyle(Palette.textEmphasis)
            // "About", always. Nobody records reading time, so this is chapters
            // times a per-format estimate and the screen should not pretend
            // otherwise.
            Text("""
            About \(Int(hours.rounded()).formatted()) hours, going by how long \
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
            ForEach(nearly.prefix(6)) { item in
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
            ForEach(waiting.prefix(8)) { item in
                row(item, trailing: "\(item.waiting) behind")
            }
        }
    }

    private func row(_ item: ReadingInsights.Behind, trailing: String) -> some View {
        Button {
            if let series = item.series { path.append(series) }
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
                    Text(progressLine(item))
                        .typeSmallMeta()
                        .foregroundStyle(Palette.textTertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(trailing)
                    .typeSmallMeta()
                    .foregroundStyle(Palette.accent)
            }
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }

    private func progressLine(_ item: ReadingInsights.Behind) -> String {
        let read = Int(item.entry.progressChapter ?? 0)
        let total = Int(item.series?.totalChapters ?? 0)
        return "\(item.entry.state.title) · ch \(read) of \(total)"
    }

    // MARK: - What you like

    private var tasteSection: some View {
        let finishes = verdicts
            .filter { ($0.completionRate ?? 0) >= 0.6 }
            .prefix(6)
        let abandons = verdicts
            .filter { ($0.completionRate ?? 1) <= 0.3 }
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
                section(
                    "What you give up on",
                    note: "Nearly half of your library is dropped. This is what it has in common."
                ) {
                    ForEach(Array(abandons)) { verdict in
                        verdictRow(verdict)
                    }
                }
            }
            // Said plainly rather than buried: a verdict drawn from part of the
            // library is a different claim from one drawn from all of it.
            Text("""
            From the \(sample.seen.formatted()) of your \
            \(sample.total.formatted()) series we have tags for.
            """)
                .typeFootnote()
                .foregroundStyle(Palette.textQuaternary)
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
                    .foregroundStyle(Palette.textTertiary)
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
                    .foregroundStyle(Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 0) { content() }
        }
    }
}
