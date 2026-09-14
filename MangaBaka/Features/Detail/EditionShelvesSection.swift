import SwiftUI

/// The other printings of a series: Anime News Network's English volumes, Open
/// Library's sibling editions, and the National Diet Library's Japanese ones —
/// grouped by edition, English and the series' own language only.
///
/// It sits under the volumes shelf rather than inside it, and the two answer
/// different questions. The shelf above is *what you can buy* — a store, a
/// price, a cover. This is *what exists and what is coming*: a catalogue row,
/// its date, and how precise that date is.
///
/// **Two attribution rules live in this file and neither is decorative.**
///
/// 1. Every `.animeNewsNetwork` row renders its own `sourceLink` as a tappable
///    link, and the group carries the words "Anime News Network". That is what
///    ANN's API documentation requires, quoted in `docs/sources/publishers.md`
///    (2026-09-14): the source named, *and* a link to the relevant Encyclopedia
///    entry on any page that displays their details. A footer credit does not
///    satisfy it and neither does one link per section — see
///    `VolumeCatalogue.requiresPerEntryLink`, which is the rule this renders.
/// 2. Open Library and NDL rows carry `BookEdition.Source.credit`, read through
///    `VolumeCatalogue.credit` so the wording lives in exactly one place.
///
/// The language rule is **not** applied here. `VolumeEditions.merge` has
/// already applied `Series.coverLanguages` — the same rule the cover fan uses —
/// to every source at once, so this view draws what it is given and there is no
/// second place for "English plus the original" to be decided differently.
struct EditionShelvesSection: View {
    let answer: VolumeEditionAnswer
    /// True while the three legs are still out. A skeleton rather than an empty
    /// section that is about to fill in — gap 22, the same reasoning
    /// `VolumesSection.isCheckingStore` carries.
    var isLoading = false
    /// Injected so a test and a preview can pin "today". The forthcoming line
    /// is the one thing here that depends on the clock.
    var now: Date = .init()

    @Environment(\.openURL) private var openURL

    /// Whether this section has anything to say. A page with no shelves, no
    /// failure and nothing in flight says nothing — the same rule
    /// `VolumesSection.shows` applies, and for the same reason: a header over
    /// an empty box reads as a broken feature.
    ///
    /// **A failure is worth the header on its own.** "Anime News Network
    /// couldn't be reached" is a sentence; silence in its place is the bug the
    /// failure kit exists to fix.
    nonisolated static func shows(answer: VolumeEditionAnswer, isLoading: Bool) -> Bool {
        isLoading || !answer.isEmpty || !answer.failures.isEmpty
    }

    var body: some View {
        if Self.shows(answer: answer, isLoading: isLoading) {
            VStack(alignment: .leading, spacing: 14) {
                header
                forthcomingLine
                failures
                if isLoading {
                    CoverSkeletonRow(count: 2, width: Metrics.coverSeedWidth)
                        .transition(.blurReplace)
                } else {
                    ForEach(answer.shelves) { shelf in
                        shelfBlock(shelf)
                    }
                }
            }
            .animation(Motion.reduced(Motion.settle), value: isLoading)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            // Not "Other editions": `DetailEditions` directly below this is
            // already called "Editions", and a walk on 2026-09-14 read the two
            // headings as one section split in half. This one is volumes —
            // rows with numbers, dates and ISBNs — from catalogues other than
            // the store shelf above.
            Text("Volumes on record")
                .typeDetailSectionHeader()
                .foregroundStyle(Palette.textPrimary)
            Spacer(minLength: 0)
            if isLoading {
                Text("Checking catalogues…")
                    .typeGridMeta()
                    .foregroundStyle(Palette.textMuted)
            }
        }
        .padding(.horizontal, Metrics.gutter)
    }

    // MARK: - Forthcoming

    /// What is announced next, or why we cannot say.
    ///
    /// **Read `ForthcomingVolume` before touching this copy.** There is no
    /// value in that type meaning "nothing is coming", because no source
    /// surveyed can say it: ANN's encyclopedia is volunteer-edited, so One
    /// Piece has GN 113 dated 2026-11-10 because somebody entered it and The
    /// Apothecary Diaries stops at 2026-03-17 while the series is still
    /// running because nobody has. Both look identical on the wire. Every
    /// sentence below is therefore about what *we* know, never about what the
    /// publisher intends — "No announced date" is a statement about the
    /// catalogues, and "We haven't checked" is a statement about this app.
    @ViewBuilder
    private var forthcomingLine: some View {
        switch answer.forthcoming(asOf: now) {
        case let .announced(volume):
            HStack(spacing: 6) {
                Image(systemName: "calendar")
                    .typeSymbol(size: 12, weight: .regular)
                    .accessibilityHidden(true)
                Text(announcement(for: volume))
                    .typeSmallMeta()
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(Palette.textPrimary)
            .padding(.horizontal, Metrics.gutter)
        case let .unknown(reason):
            // Not hidden. A page that shows nothing here is a page a reader
            // reads as "there is nothing coming", which is the one thing this
            // section must never say.
            Text(Self.unknownWording(reason))
                .typeSmallMeta()
                .foregroundStyle(Palette.textMuted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Metrics.gutter)
        }
    }

    /// "Vol. 113 announced for 10 November 2026". The date's own precision
    /// decides the words: a month-precision date says "November 2026", because
    /// printing a day the catalogue never stated is the fabrication
    /// `PartialDate` exists to prevent.
    nonisolated static func announcementText(
        number: Int?, date: PartialDate?, source: String
    ) -> String {
        let volume = number.map { "Vol. \($0)" } ?? "A new volume"
        guard let date else { return "\(volume) is listed by \(source), with no date yet" }
        return "\(volume) announced for \(Self.wording(date)) · \(source)"
    }

    /// A date printed to exactly the precision the catalogue stated.
    nonisolated static func wording(_ date: PartialDate) -> String {
        switch date.precision {
        case .day: date.date.formatted(VolumesSection.utcDayMonthYear)
        case .month: date.date.formatted(VolumesSection.utcMonthYear)
        // Not "1 January 2012". `PartialDate` stores the first instant of the
        // stated period, and the period here is the year.
        case .year: String(VolumesSection.spineYear(for: date.date))
        }
    }

    private func announcement(for volume: EditionVolume) -> String {
        Self.announcementText(
            number: volume.number,
            date: volume.releaseDate,
            source: (volume.dateFrom ?? volume.edition.catalogue).displayName
        )
    }

    /// The four kinds of "we do not know", in the app's own voice.
    ///
    /// None of them is an ending. `.noneListed` in particular is the case a
    /// finished series and a series nobody has entered a date for both land in,
    /// and no source surveyed can tell those apart — so it says what the
    /// catalogues hold, not what the publisher plans.
    nonisolated static func unknownWording(_ reason: ForthcomingVolume.UnknownReason) -> String {
        switch reason {
        case .noneListed: "No catalogue lists a dated volume ahead — which is not the same as none coming."
        case .notCatalogued: "These catalogues have no record of this series."
        case .notAsked: "Checking for announced volumes…"
        case .couldNotAsk: "Announced volumes couldn't be checked just now."
        }
    }

    // MARK: - Failures

    /// One line per leg that failed, named. Three sources, three separate
    /// answers: a section that collapsed them would tell a reader whose Open
    /// Library request timed out that "editions couldn't be loaded", while ANN
    /// was sitting right there having answered.
    ///
    /// No retry button. Every one of these is re-asked when the page is opened
    /// again, and a per-leg retry would need a per-leg closure back into
    /// `SeriesDetailView+Editions` for three legs whose combined worst case is
    /// four requests against three politeness-limited hosts. Recorded as a
    /// deliberate omission, not an oversight — `VolumesSection` has a retry
    /// because its failure is the whole section.
    @ViewBuilder
    private var failures: some View {
        ForEach(VolumeCatalogue.allCases, id: \.self) { catalogue in
            if let error = answer.failures[catalogue],
               let shown = SeriesDetailView.presentableFailure(error) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(catalogue.displayName)
                        .typeGridMeta()
                        .foregroundStyle(Palette.textMuted)
                        .padding(.horizontal, Metrics.gutter)
                    InlineFailure(error: shown)
                }
            }
        }
    }

    // MARK: - One edition's spines

    private func shelfBlock(_ shelf: EditionShelf) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.heading(for: shelf.edition))
                    .typeRowTitle()
                    .foregroundStyle(Palette.textPrimary)
                // The source, named on the group. Obligation, not decoration —
                // see this file's own doc comment.
                Text(Self.creditLine(for: shelf))
                    .typeGridMeta()
                    .foregroundStyle(Palette.textMuted)
            }
            .padding(.horizontal, Metrics.gutter)

            ForEach(shelf.volumes) { volume in
                row(volume)
            }
        }
    }

    /// "English · Yen Press", "Japanese · KADOKAWA", or just the language when
    /// the catalogue named no publisher.
    ///
    /// The language word comes from the *role*, not from the code: "English
    /// edition" and "Japanese edition" are the headings a reader recognises,
    /// and the role is what `VolumeEditions.role(of:in:)` decided against this
    /// series rather than something re-derived here.
    nonisolated static func heading(for edition: VolumeEdition) -> String {
        let language: String
        switch edition.languageRole {
        case .english: language = "English"
        case .original: language = LanguageFlag.name(for: edition.language)
        // Reached only when the series states no language of its own, so
        // nothing was filtered and the code is all there is to go on.
        case .other: language = LanguageFlag.name(for: edition.language)
        }
        guard let title = edition.editionTitle, !title.isEmpty else { return language }
        return "\(language) · \(title)"
    }

    /// Every source standing behind this group's rows, credited.
    ///
    /// Built from the rows' own `contributors`, not from the group's catalogue:
    /// `VolumeEditions.merge` collapses two sources' rows for one ISBN into
    /// one, and the source that lost the collapse still said it. Crediting only
    /// the winner would be using the loser's data under someone else's name.
    nonisolated static func creditLine(for shelf: EditionShelf) -> String {
        let present = Set(shelf.volumes.flatMap(\.contributors))
        return VolumeCatalogue.allCases
            .filter { present.contains($0) }
            .map(\.credit)
            .joined(separator: " · ")
    }

    /// One catalogue row: its number, its title, its date at the precision the
    /// catalogue stated — and, for ANN, its own Encyclopedia link.
    @ViewBuilder
    private func row(_ volume: EditionVolume) -> some View {
        // The rule is the row's, not the parser's: a `.animeNewsNetwork` row
        // with no link must not be drawn at all, because drawing it would show
        // ANN's data without the link their terms require.
        // `ANNEncyclopedia.volumes(in:)` already drops those upstream, so this
        // is belt and braces — and it is the belt that is load-bearing.
        if !volume.edition.catalogue.requiresPerEntryLink || volume.sourceLink != nil {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(volume.title)
                        .typeCardTitle()
                        .foregroundStyle(Palette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let line = Self.dateLine(for: volume, now: now) {
                        Text(line)
                            .typeGridMeta()
                            .foregroundStyle(Palette.textMuted)
                    }
                }
                Spacer(minLength: 8)
                if let link = volume.sourceLink {
                    Button { openURL(link) } label: {
                        Image(systemName: "arrow.up.right")
                            .typeSymbol(size: 12, weight: .semibold)
                            .foregroundStyle(Palette.accent)
                            .frame(minWidth: Metrics.tapTarget, minHeight: Metrics.tapTarget)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.press)
                    .accessibilityLabel("\(volume.title) on \(volume.edition.catalogue.displayName)")
                    .accessibilityHint("Opens the catalogue entry in the browser")
                }
            }
            .padding(.horizontal, Metrics.gutter)
            .accessibilityElement(children: .contain)
        }
    }

    /// The date, at its stated precision, plus who said it when that is not the
    /// row's own source and plus "announced" when it is still ahead.
    ///
    /// A row with no date says nothing rather than "unknown": the title and the
    /// source are already on screen, and a muted "Date unknown" on forty rows
    /// is noise, not information.
    nonisolated static func dateLine(for volume: EditionVolume, now: Date = Date()) -> String? {
        guard let date = volume.releaseDate else { return nil }
        var line = wording(date)
        if date.isForthcoming(now: now) { line = "Announced · \(line)" }
        // Only when a *different* catalogue supplied the fuller date — merge
        // sets this exactly then, and saying so is the "record which won" half
        // of the dedupe rule.
        if let source = volume.dateFrom {
            line += " · date from \(source.displayName)"
        }
        return line
    }
}
