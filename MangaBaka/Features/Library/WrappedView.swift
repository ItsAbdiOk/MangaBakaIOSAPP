import SwiftUI

/// The reader's year, and the parts of their taste that are actually theirs.
///
/// Full-bleed cards, one fact each, read top to bottom. Not a dashboard: a
/// dashboard invites comparison between numbers that have nothing to do with
/// each other, and the point of every card here is a single sentence somebody
/// might read aloud.
///
/// The screen's own rule, inherited from `ReadingWrapped`: say the size of the
/// sample. A year built from four finish dates is not a year, and this says so
/// rather than presenting it as one.
struct WrappedView: View {
    let entries: [LibraryEntry]
    /// How many series the database holds, for the signature baseline. Taken
    /// from the community pulse rather than hard-coded, because it moves every
    /// week.
    let catalogueSize: Int
    @Binding var path: [Series]

    @State private var facts = Facts()

    private struct Facts {
        var year: ReadingWrapped.Year?
        var signatures: [ReadingWrapped.Signature] = []
        var critic: (gap: Double, sample: Int)?
        var loved: [ReadingWrapped.Disagreement] = []
        var busiest: (month: Int, count: Int)?
        var sprint: ReadingWrapped.Sprint?
        var longest: LibraryEntry?
        var formats: [ReadingWrapped.Slice] = []
        var creators: [ReadingWrapped.Slice] = []
    }

    private var thisYear: Int { Calendar.current.component(.year, from: Date()) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if let year = facts.year, year.isWorthShowing {
                    yearCard(year)
                    if let busiest = facts.busiest { busiestCard(busiest) }
                }
                if let sprint = facts.sprint { sprintCard(sprint) }
                if !facts.signatures.isEmpty { signatureCard }
                if let critic = facts.critic { criticCard(critic) }
                if let longest = facts.longest { longestCard(longest) }
                if !facts.creators.isEmpty { creatorsCard }
                if !facts.formats.isEmpty { formatsCard }
                provenance
            }
            .padding(.horizontal, Metrics.gutter)
            .padding(.top, Metrics.scrollTopInset)
            .padding(.bottom, Metrics.scrollBottomInset)
        }
        .scrollIndicators(.hidden)
        .background(Palette.ground)
        .scrollEdgeEffectStyle(.hard, for: .top)
        .navigationTitle("Your year")
        .navigationBarTitleDisplayMode(.inline)
        .task { await compute() }
    }

    /// Off the main actor: the signature pass walks every tag of every series,
    /// which on a 939-entry library is tens of thousands of dictionary
    /// touches, and a frame is 16.7ms.
    private func compute() async {
        let entries = entries
        let size = catalogueSize
        let year = thisYear
        let computed = await Task.detached(priority: .userInitiated) { () -> Facts in
            var facts = Facts()
            facts.year = ReadingWrapped.year(year, in: entries)
            facts.signatures = ReadingWrapped.signatures(in: entries, catalogueSize: size)
            facts.critic = ReadingWrapped.criticGap(in: entries)
            facts.loved = ReadingWrapped.disagreements(in: entries, liked: true)
            facts.sprint = ReadingWrapped.fastestFinish(in: entries)
            facts.longest = ReadingWrapped.longestRunning(in: entries)
            facts.formats = ReadingWrapped.formats(in: entries)
            facts.creators = ReadingWrapped.creators(in: entries)
            if let builtYear = facts.year {
                facts.busiest = ReadingWrapped.busiestMonth(in: builtYear)
            }
            return facts
        }.value
        facts = computed
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(thisYear))
                .typeScreenTitle()
                .foregroundStyle(Palette.textPrimary)
            Text("""
            Worked out on this phone, from your own library. None of it is \
            sent anywhere, and nothing here is a number MangaBaka keeps \
            about you.
            """)
            .typeSubtitle()
            .foregroundStyle(Palette.textMuted)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 6)
    }

    // MARK: - Cards

    private func yearCard(_ year: ReadingWrapped.Year) -> some View {
        card("This year") {
            headline("\(year.finished.count)", "series finished")
            detail("\(year.chapters.formatted()) chapters, give or take what you logged.")
            if year.coverage < 0.6 {
                // The honesty line. A finish date is set when a series is
                // completed through the site and not otherwise, so this figure
                // can be a fraction of the truth — and saying that is better
                // than a confident wrong number.
                caveat("""
                Counted from the \(year.dated.formatted()) of your \
                \(year.total.formatted()) entries that carry a finish date.
                """)
            }
        }
    }

    private func busiestCard(_ busiest: (month: Int, count: Int)) -> some View {
        card("Your month") {
            headline(monthName(busiest.month), "")
            detail("\(busiest.count) finished. More than any other month this year.")
        }
    }

    private func sprintCard(_ sprint: ReadingWrapped.Sprint) -> some View {
        card("Fastest read") {
            headline("\(sprint.perDay)", "chapters a day")
            detail("""
            \(sprint.entry.series?.displayTitle ?? "A series") — \
            \(sprint.chapters.formatted()) chapters in \
            \(sprint.days) day\(sprint.days == 1 ? "" : "s").
            """)
        }
    }

    private var signatureCard: some View {
        card("What makes your library yours") {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(facts.signatures) { signature in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(signature.tag)
                            .typeRowTitle()
                            .foregroundStyle(Palette.textPrimary)
                        Spacer(minLength: 8)
                        Text("\(Int(signature.lift.rounded()))×")
                            .typeDetailSectionHeader()
                            .foregroundStyle(Palette.accent)
                    }
                }
            }
            detail("""
            How much more often these appear in your library than in \
            MangaBaka as a whole. Your top tags would look like everyone \
            else's; this is the part that does not.
            """)
        }
    }

    private func criticCard(_ critic: (gap: Double, sample: Int)) -> some View {
        // Stars, the reader's own scale — see Disagreement.displayGap.
        let scaled = abs(critic.gap / 20)
        return card(critic.gap < 0 ? "A tough crowd of one" : "A generous reader") {
            headline(String(format: "%.1f★", scaled), critic.gap < 0 ? "below" : "above")
            detail("""
            On the \(critic.sample.formatted()) series you have rated, you sit \
            \(String(format: "%.1f", scaled)) stars \
            \(critic.gap < 0 ? "under" : "over") everyone else on average.
            """)
            if let loved = facts.loved.first, let title = loved.series?.displayTitle {
                caveat("Furthest apart on \(title) — \(loved.displayGap) against the crowd.")
            }
        }
    }

    private func longestCard(_ longest: LibraryEntry) -> some View {
        card("Still going") {
            headline(longest.series?.displayTitle ?? "A series", "")
            if let start = longest.startDate {
                detail("""
                You started it \(start.formatted(.relative(presentation: .named))) \
                and have not finished.
                """)
            }
        }
    }

    private var creatorsCard: some View {
        card("Who you follow") {
            VStack(alignment: .leading, spacing: 9) {
                ForEach(facts.creators) { creator in
                    HStack(spacing: 10) {
                        Text(creator.label)
                            .typeRowTitle()
                            .foregroundStyle(Palette.textPrimary)
                        Spacer(minLength: 8)
                        Text("\(creator.count)")
                            .typeSmallMeta()
                            .foregroundStyle(Palette.textMuted)
                    }
                }
            }
        }
    }

    private var formatsCard: some View {
        card("What you read") {
            VStack(alignment: .leading, spacing: 9) {
                ForEach(facts.formats.prefix(4)) { slice in
                    HStack(spacing: 10) {
                        Text(slice.label)
                            .typeRowTitle()
                            .foregroundStyle(Palette.textPrimary)
                        Spacer(minLength: 8)
                        Text("\(slice.count)")
                            .typeSmallMeta()
                            .foregroundStyle(Palette.textMuted)
                    }
                }
            }
        }
    }

    private var provenance: some View {
        Text("""
        Hours are an estimate from a per-format average, not something anybody \
        measured. Everything else is counted.
        """)
        .typeFootnote()
        .foregroundStyle(Palette.textMuted)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, 8)
    }
}
