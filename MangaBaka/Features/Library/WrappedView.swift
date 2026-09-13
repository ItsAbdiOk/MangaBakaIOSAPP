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
    /// False while the library walk this was built from is still going.
    /// Defaulted to `true` so every existing call site keeps compiling and
    /// behaving exactly as before until the shell (batch 6) passes the real
    /// value from `LibraryModel.isComplete`.
    var isComplete = true
    @Binding var path: [Series]

    @State private var facts = Facts()
    /// Gap 94: this screen's header, provenance line and nothing readable in
    /// between is exactly what a library with nothing to say drew — there
    /// was no branch for "the partial library it was built from just has no
    /// year yet", only cards that each independently declined to render.
    @State private var hasComputed = false

    private var revision: String { "\(entries.count)-\(isComplete)" }

    /// Whether any card below the header would actually draw anything.
    private var hasAnythingToShow: Bool {
        (facts.year?.isWorthShowing ?? false)
            || facts.sprint != nil
            || !facts.signatures.isEmpty
            || facts.critic != nil
            || facts.longest != nil
            || !facts.creators.isEmpty
            || !facts.formats.isEmpty
    }

    private struct Facts {
        var year: ReadingWrapped.Year?
        var signatures: [ReadingWrapped.Signature] = []
        var critic: (gap: Double, sample: Int)?
        var loved: [ReadingWrapped.Disagreement] = []
        /// L5: the caveat below the critic headline used to always read from
        /// `loved` (the reader's biggest *positive* disagreement), even on
        /// the "tough crowd of one" card where the headline gap is negative —
        /// naming the reader's mildest overrating instead of the harsh
        /// underrating that actually produced the headline. `disliked` is the
        /// other half of the same comparison, picked by the sign of
        /// `critic.gap` in `criticCard`.
        var disliked: [ReadingWrapped.Disagreement] = []
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
                // Decision (matching gap 93's): say what this is built from
                // rather than hiding the screen until the walk completes.
                if !isComplete {
                    StaleBar(
                        headline: "Built from the \(entries.count.formatted()) series that loaded",
                        detail: "This updates once the rest of your library finishes loading."
                    )
                }
                if !hasComputed {
                    loading
                } else if !hasAnythingToShow {
                    EmptyState(
                        title: "Not enough of a year yet",
                        message: """
                        This fills in as you finish series, rate them, and read at your \
                        own pace — there is nothing distinctive to show yet.
                        """
                    )
                    .padding(.top, 20)
                } else {
                    if let year = facts.year, year.isWorthShowing {
                        yearCard(year)
                            .arrives(index: 0)
                            .arrivalHaptic(index: 0)
                            // The headline card: the one moment on this screen
                            // that is a reward rather than information, so it
                            // gets the celebration bounce and `.success` — see
                            // `Motion.celebrate`'s own doc comment on why that
                            // is reserved for one-off rewards. Keyed on
                            // `hasComputed` flipping true, which is exactly
                            // when this card first has something to show.
                            .celebrates(on: hasComputed)
                            .sensoryFeedback(Haptics.success, trigger: hasComputed)
                        if let busiest = facts.busiest {
                            busiestCard(busiest)
                                .arrives(index: 1)
                                .arrivalHaptic(index: 1)
                        }
                    }
                    if let sprint = facts.sprint {
                        sprintCard(sprint)
                            .arrives(index: 2)
                            .arrivalHaptic(index: 2)
                    }
                    if !facts.signatures.isEmpty {
                        signatureCard
                            .arrives(index: 3)
                            .arrivalHaptic(index: 3)
                    }
                    if let critic = facts.critic {
                        criticCard(critic)
                            .arrives(index: 4)
                            .arrivalHaptic(index: 4)
                    }
                    if let longest = facts.longest {
                        longestCard(longest)
                            .arrives(index: 5)
                            .arrivalHaptic(index: 5)
                    }
                    if !facts.creators.isEmpty {
                        creatorsCard
                            .arrives(index: 6)
                            .arrivalHaptic(index: 6)
                    }
                    if !facts.formats.isEmpty {
                        formatsCard
                            .arrives(index: 7)
                            .arrivalHaptic(index: 7)
                    }
                    provenance
                }
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
        // Keyed on `revision`: a plain `.task {}` runs once per view identity
        // and never again, so a library reload landing while this screen was
        // open used to leave it showing the year built from the old data.
        .task(id: revision) { await compute() }
    }

    private var loading: some View {
        VStack(alignment: .leading, spacing: 10) {
            Capsule().fill(Palette.surface).frame(width: 140, height: 40)
            Capsule().fill(Palette.surface).frame(width: 200, height: 14)
        }
        .shimmering()
        .accessibilityHidden(true)
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
            facts.disliked = ReadingWrapped.disagreements(in: entries, liked: false)
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
        hasComputed = true
    }

}

/// The individual cards, split out of the type above purely to stay under
/// SwiftLint's `type_body_length` — the loading/empty branches this batch
/// added (gap 94) pushed the single declaration over it.
extension WrappedView {
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
            headlineCounting(year.finished.count, "series finished", index: 0)
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
            headlineCounting(sprint.perDay, "chapters a day", index: 2)
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
                            .countsNotCuts()
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
            let furthest = Self.furthestDisagreement(
                critic: critic, loved: facts.loved, disliked: facts.disliked
            )
            if let furthest, let title = furthest.series?.displayTitle {
                caveat("Furthest apart on \(title) — \(furthest.displayGap) against the crowd.")
            }
        }
    }

    /// Which disagreement the critic card's caveat should name.
    ///
    /// L5: this used to always be `loved.first` — the reader's biggest
    /// *positive* disagreement — even on the "tough crowd of one" card, where
    /// the headline gap is negative and the disagreement that produced it is
    /// in `disliked`. Picking by the sign of `critic.gap` keeps the caveat
    /// pointing at the series that actually explains the headline above it.
    nonisolated static func furthestDisagreement(
        critic: (gap: Double, sample: Int),
        loved: [ReadingWrapped.Disagreement],
        disliked: [ReadingWrapped.Disagreement]
    ) -> ReadingWrapped.Disagreement? {
        critic.gap < 0 ? disliked.first : loved.first
    }

    /// The number a headline stat shows partway through its count-up, at
    /// `progress` from 0 (just landed) to 1 (settled on `target`). Rounded
    /// rather than truncated so the very last visible frame before `1` reads
    /// as one digit short of the truth rather than several — a truncated
    /// count from, say, 41 to a target of 42 sits on 41 for the whole
    /// animation and never visibly moves.
    ///
    /// `progress` outside 0...1 is clamped rather than trusted: the caller
    /// (`CountUpNumber`) derives it from elapsed wall-clock time minus a
    /// stagger delay, which is negative before the delay has elapsed and can
    /// run past 1 on a dropped frame.
    nonisolated static func countUp(progress: Double, target: Int) -> Int {
        let clamped = min(max(progress, 0), 1)
        return Int((Double(target) * clamped).rounded())
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
                            .countsNotCuts()
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
                            .countsNotCuts()
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
