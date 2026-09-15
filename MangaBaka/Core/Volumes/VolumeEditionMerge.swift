import Foundation

/// Turns three catalogues' answers into the one thing the shelf draws.
///
/// Its own file since 2026-09-14: the types in `VolumeEdition.swift` are the
/// vocabulary and this is the one function that combines them, and together
/// they were past the lint's file-length ceiling.
///
/// **What this must get right, and why each rule is here:**
///
/// 1. *One row per book.* ANN and Open Library both carry the English
///    Delicious in Dungeon vol. 1 at ean 9780316471855 (measured 2026-09-14,
///    `docs/sources/publishers.md`). Two sources is not two books.
/// 2. *Both credits survive the collapse.* The loser of a dedupe still said it
///    — see `EditionVolume.alsoFrom`.
/// 3. *A full date beats a partial one, whoever stated it.* Open Library
///    answers `2021-03-02`, `Apr 07, 2021` and a bare `2012` in one response;
///    a year-precision row is not a publication day and must never displace a
///    dated one just because its source won the row.
/// 4. *Nothing here can say "the series has finished."* See `ForthcomingVolume`.
enum VolumeEditions {
    /// - Parameters:
    ///   - ann: `ANNClient.volumes(for:)`'s answer. `.idle` when the series
    ///     carries no ANN id to ask with, which is a real and common state —
    ///     not an error, and not an empty shelf either.
    ///   - openLibrary: `OpenLibraryEditions.editions(anchorISBN:…)`, wrapped
    ///     by the caller. `.idle` when the series has no ISBN in MangaBaka's
    ///     own works to anchor on, which is the documented no-answer case.
    ///   - ndl: `NDLClient.volumes(japaneseTitle:…)`. `.idle` when the series
    ///     carries no Japanese title to search with.
    ///   - works: MangaBaka's own `/v1/series/{id}/works`, already on screen
    ///     as the main shelf. Not a catalogue — it is never credited and never
    ///     draws a row here. It is read for one thing: **a third-party row
    ///     whose ISBN-13 MangaBaka already shows, with a date, is the row the
    ///     reader is looking at.** Drawing it again a few pixels below is the
    ///     "twenty-five entries for thirteen volumes" bug `VolumesSection`
    ///     already exists to avoid. A MangaBaka row with *no* date does not
    ///     suppress anything — that is how a forthcoming ANN or NDL volume
    ///     survives a series MangaBaka lists but has not dated.
    ///   - format: what Wikidata says the series is, or nil when the bundled
    ///     table has never heard of it — which is three quarters of the
    ///     catalogue by row and means nothing about what the series is. When
    ///     it says comic, prose rows are dropped: see `droppingProse`.
    ///   - series: read for `coverLanguages` (the existing "English plus the
    ///     original" rule) and for the native language the roles are tagged
    ///     against. Passing the series rather than two strings keeps that
    ///     rule in one place.
    ///   - ndlTotalRecords: NDL's own `<numberOfRecords>` for this page, when
    ///     the `ndl` leg is `.loaded` — carried separately because
    ///     `EditionAnswer` has no field for it. Attached to the NDL shelf only
    ///     when that shelf is partial, so `EditionShelf.totalRecords` can say
    ///     "first 50 of 84 on record" instead of only "partial" (item P3).
    static func merge(
        ann: Fetched<ANNVolumes> = .idle,
        openLibrary: Fetched<EditionAnswer> = .idle,
        ndl: Fetched<EditionAnswer> = .idle,
        ndlTotalRecords: Int? = nil,
        works: [SeriesWork.Volume] = [],
        format: WikidataFormat? = nil,
        for series: Series
    ) -> VolumeEditionAnswer {
        let candidates = shown(
            rows: collect(ann: ann, openLibrary: openLibrary, ndl: ndl, series: series),
            series: series, format: format, works: works
        )
        let shelves = group(
            deduplicate(candidates),
            partial: partialCatalogues(ann: ann, openLibrary: openLibrary, ndl: ndl),
            ndlTotalRecords: ndlTotalRecords
        )

        var failures: [VolumeCatalogue: APIError] = [:]
        if let error = ann.error { failures[.animeNewsNetwork] = error }
        if let error = openLibrary.error { failures[.openLibrary] = error }
        if let error = ndl.error { failures[.nationalDietLibrary] = error }

        // Read off the rows, not off which legs answered: a source whose every
        // row lost a dedupe or the language filter put nothing on screen, and
        // a credit for a source that contributed nothing is noise. `alsoFrom`
        // is why this is not simply the shelves' own catalogues — the loser of
        // a collapse is on screen too, inside someone else's row.
        let present = Set(shelves.flatMap { $0.volumes.flatMap(\.contributors) })
        let credits: [VolumeCatalogue] = VolumeCatalogue.allCases.filter { present.contains($0) }
        let reason: ForthcomingVolume.UnknownReason? = shelves.isEmpty
            ? unasked(ann: ann, openLibrary: openLibrary, ndl: ndl)
            : nil
        return VolumeEditionAnswer(
            shelves: shelves, credits: credits, failures: failures, unaskedReason: reason
        )
    }

    // MARK: - Gathering

    private static func collect(
        ann: Fetched<ANNVolumes>,
        openLibrary: Fetched<EditionAnswer>,
        ndl: Fetched<EditionAnswer>,
        series: Series
    ) -> [EditionVolume] {
        var rows = ann.value?.volumes ?? []
        rows += BookEditionShelf.editionVolumes(from: openLibrary.value?.rows ?? [], in: series)
        rows += BookEditionShelf.editionVolumes(from: ndl.value?.rows ?? [], in: series)
        return rows
    }

    /// English and the series' own language, comics only when we know, and
    /// nothing MangaBaka's own shelf is already showing.
    private static func shown(
        rows: [EditionVolume], series: Series, format: WikidataFormat?, works: [SeriesWork.Volume]
    ) -> [EditionVolume] {
        let languages = series.coverLanguages
        let alreadyShown = datedISBNs(in: works)
        return rows.filter { row in
            guard languages.map({ $0.contains(row.edition.language.lowercased()) }) ?? true else {
                return false
            }
            guard keeps(row, whenSeriesIs: format) else { return false }
            guard let isbn = row.isbn13 else { return true }
            return !alreadyShown.contains(isbn)
        }
    }

    /// The Apothecary Diaries rule: a comic shelf does not show prose.
    ///
    /// `VolumeFormat.other` is what `BookEditionShelf` maps a `BookEdition`
    /// whose `format` is `.prose` to — its own doc comment already says it is
    /// "a light novel beside the comic … never a volume of the series itself".
    /// This is the caller that acts on it, and it acts **only** when Wikidata
    /// positively says the series is a comic. A nil format is "not in the
    /// table", which is the common case and is not evidence of anything; a
    /// filter that treated it as one would hide three quarters of the
    /// catalogue (`WikidataIdentityTable`'s coverage measurements, 2026-09-14).
    private static func keeps(_ row: EditionVolume, whenSeriesIs format: WikidataFormat?) -> Bool {
        guard let format, format.isComic else { return true }
        return row.format != .other
    }

    /// Every ISBN-13 MangaBaka's own works list carries *with a date*.
    ///
    /// The date is the condition, not an extra: an undated MangaBaka row is a
    /// volume the reader can see but cannot place in time, and NDL's 近刊
    /// records and ANN's pre-orders are exactly the rows that would fill that
    /// gap. Suppressing on a bare ISBN match would throw away the forthcoming
    /// volume, which is the single thing these two sources are here for.
    private static func datedISBNs(in works: [SeriesWork.Volume]) -> Set<String> {
        var found: Set<String> = []
        for volume in works where volume.date != nil {
            for edition in volume.editions {
                guard let isbn = edition.isbn else { continue }
                let normalised = OpenLibraryEditions.normalise(isbn)
                found.insert(normalised)
                // Item P18: a MangaBaka work carrying an ISBN-10 used to
                // suppress nothing, because every third-party row's
                // `isbn13` is 13 digits — so the same dated volume showed
                // once on MangaBaka's own shelf and again, undeduplicated,
                // on ANN's or a library catalogue's. Both forms go in the
                // set so a row keyed on either matches.
                if let thirteen = Self.isbn13(fromISBN10: normalised) { found.insert(thirteen) }
            }
        }
        return found
    }

    /// ISBN-10 → ISBN-13 by the standard's own arithmetic (ISO 2108): drop
    /// the 10-digit check character, prefix `978`, recompute the check digit
    /// over the new 12 digits. Every ISBN-13 ever assigned to a book
    /// previously published as ISBN-10 uses the `978` prefix, so this is not
    /// a guess about which prefix to use — it is the only one in use.
    ///
    /// Nil for anything that is not exactly 10 characters after
    /// `OpenLibraryEditions.normalise` (digits and a possible trailing `X`),
    /// so a malformed value is left alone rather than "converted" into a
    /// 13-digit string nobody's catalogue would recognise.
    static func isbn13(fromISBN10 isbn10: String) -> String? {
        guard isbn10.count == 10 else { return nil }
        let core = "978" + isbn10.prefix(9)
        guard core.allSatisfy(\.isNumber) else { return nil }
        var sum = 0
        for (index, character) in core.enumerated() {
            guard let digit = character.wholeNumberValue else { return nil }
            sum += index.isMultiple(of: 2) ? digit : digit * 3
        }
        let check = (10 - sum % 10) % 10
        return core + String(check)
    }

    // MARK: - Dedupe

    /// One row per ISBN-13, the better-populated one winning, both credits
    /// kept, and the fuller date kept whoever stated it.
    ///
    /// Rows with no ISBN are never merged with anything. Two sources' titles
    /// for one book do not match — ANN writes "Delicious in Dungeon (GN 1)",
    /// Open Library "Delicious in Dungeon, Vol. 1", NDL "ダンジョン飯 1" — and
    /// matching on a normalised title is the string matching this whole family
    /// of sources was built to avoid (`OpenLibraryEditions`' doc comment
    /// records what a plausible-but-wrong match returns: a coherent answer for
    /// a different book).
    static func deduplicate(_ rows: [EditionVolume]) -> [EditionVolume] {
        var winners: [String: EditionVolume] = [:]
        var order: [String] = []
        var unmatched: [EditionVolume] = []

        for row in rows {
            guard let isbn = row.isbn13 else {
                unmatched.append(row)
                continue
            }
            guard let standing = winners[isbn] else {
                winners[isbn] = row
                order.append(isbn)
                continue
            }
            winners[isbn] = combine(standing, row)
        }
        return order.compactMap { winners[$0] } + unmatched
    }

    /// Two rows for one ISBN, become one.
    private static func combine(_ lhs: EditionVolume, _ rhs: EditionVolume) -> EditionVolume {
        let winner = population(of: rhs) > population(of: lhs) ? rhs : lhs
        let loser = winner.edition.catalogue == lhs.edition.catalogue ? rhs : lhs
        let (date, dateFrom) = betterDate(winner, loser)
        var credits = winner.alsoFrom + loser.contributors
        credits = credits.filter { $0 != winner.edition.catalogue }
        return EditionVolume(
            number: winner.number ?? loser.number,
            title: winner.title,
            releaseDate: date,
            isbn13: winner.isbn13,
            format: winner.format,
            edition: winner.edition,
            sourceLink: winner.sourceLink,
            alsoFrom: ordered(credits),
            dateFrom: dateFrom
        )
    }

    /// How much of a row a source actually filled in. Ties go to the row
    /// already standing, which makes the merge order-stable: `collect` puts
    /// ANN first, so on an exact tie ANN's row wins and its per-entry link
    /// survives — the one credit obligation that is per-row rather than
    /// per-section.
    private static func population(of row: EditionVolume) -> Int {
        var score = 0
        if row.number != nil { score += 1 }
        if !row.title.isEmpty { score += 1 }
        if let date = row.releaseDate { score += 1 + date.precision.rawValue }
        if row.sourceLink != nil { score += 1 }
        if row.format != .other { score += 1 }
        return score
    }

    /// The fuller of two dates, and who said it.
    ///
    /// Precision, not recency and not source rank: a bare `2012` is not a
    /// publication day and must not displace `2021-03-02` because its row won
    /// on other fields. When the loser's date is the fuller one, `dateFrom`
    /// records that so the view can say whose date it is showing.
    private static func betterDate(
        _ winner: EditionVolume, _ loser: EditionVolume
    ) -> (PartialDate?, VolumeCatalogue?) {
        guard let theirs = loser.releaseDate else { return (winner.releaseDate, winner.dateFrom) }
        guard let ours = winner.releaseDate else { return (theirs, loser.edition.catalogue) }
        guard theirs.precision > ours.precision else { return (ours, winner.dateFrom) }
        return (theirs, loser.edition.catalogue)
    }

    /// Deduplicated, in `allCases` order, so two rows that gathered the same
    /// credits in a different order compare equal.
    private static func ordered(_ credits: [VolumeCatalogue]) -> [VolumeCatalogue] {
        let present = Set(credits)
        return VolumeCatalogue.allCases.filter { present.contains($0) }
    }

    // MARK: - Shelving

    /// One shelf per `(edition, format)` — see `EditionShelf`'s doc comment
    /// for why the format is part of the key and not a filter: `VolumeFormat`
    /// says a box set and an eBook are "carried rather than dropped so a
    /// caller can choose", and grouping is the choice that keeps both on
    /// screen without either counting as a print volume.
    ///
    /// - Parameter partial: the catalogues whose leg answered with less than
    ///   it holds. A shelf whose edition comes from one of them is marked
    ///   partial; the rows it merged in from another source do not change
    ///   that, because the gap is in the shelf's own catalogue's page.
    private static func group(
        _ rows: [EditionVolume], partial: Set<VolumeCatalogue>, ndlTotalRecords: Int? = nil
    ) -> [EditionShelf] {
        struct Key: Hashable {
            let edition: VolumeEdition
            let format: VolumeFormat
        }
        var grouped: [Key: [EditionVolume]] = [:]
        for row in rows {
            grouped[Key(edition: row.edition, format: row.format), default: []].append(row)
        }

        // Built in two named steps with explicit types: chaining `map` into
        // `sorted` with a ternary inside the comparator is what the type
        // checker gave up on ("unable to type-check in reasonable time",
        // 2026-09-14).
        let unsorted: [EditionShelf] = grouped.map { key, volumes in
            let isPartial = partial.contains(key.edition.catalogue)
            return EditionShelf(
                edition: key.edition, format: key.format, volumes: volumes.sorted(by: byNumber),
                isPartial: isPartial,
                totalRecords: (isPartial && key.edition.catalogue == .nationalDietLibrary)
                    ? ndlTotalRecords : nil
            )
        }
        return unsorted.sorted { lhs, rhs in
            if lhs.volumes.count != rhs.volumes.count { return lhs.volumes.count > rhs.volumes.count }
            return lhs.id < rhs.id
        }
    }

    /// The legs that came back `isPartial` — today only NDL can, when its
    /// one page of `NDLClient.pageSize` is fewer than NDL holds.
    static func partialCatalogues(
        ann: Fetched<ANNVolumes>, openLibrary: Fetched<EditionAnswer>, ndl: Fetched<EditionAnswer>
    ) -> Set<VolumeCatalogue> {
        var partial: Set<VolumeCatalogue> = []
        if case .loaded(_, _, true) = ann { partial.insert(.animeNewsNetwork) }
        if case .loaded(_, _, true) = openLibrary { partial.insert(.openLibrary) }
        if case .loaded(_, _, true) = ndl { partial.insert(.nationalDietLibrary) }
        return partial
    }

    /// Which kind of nothing an empty answer is, across three legs.
    ///
    /// The order is deliberate and is a claim about honesty, not about
    /// sources. "Nobody has been asked yet" outranks everything: a page whose
    /// legs are still in flight has not learned anything. A failure outranks
    /// `.notCatalogued`, because a leg that could not be asked is not evidence
    /// the others were right. `.noneListed` is last and is the weakest thing
    /// this can say — a source did have a record and nothing in it survived
    /// the language filter or the dedupe.
    static func unasked(
        ann: Fetched<ANNVolumes>, openLibrary: Fetched<EditionAnswer>, ndl: Fetched<EditionAnswer>
    ) -> ForthcomingVolume.UnknownReason {
        // `.idle` legs are dropped rather than counted: a caller that asked
        // one source and left the others at their default has not "not asked
        // yet", it has excluded them from this answer. Counting them made a
        // single-source merge report `.notAsked` over a source that had
        // answered — `ANNVolumesTests.notCatalogued`, 2026-09-14. `.loading`
        // is the case that really means in flight.
        let states = [state(ann) { $0.isCatalogued }, state(openLibrary) { $0.isCatalogued },
                      state(ndl) { $0.isCatalogued }].compactMap { $0 }
        if states.contains(where: { $0 == .notAsked }) { return .notAsked }
        if let failure = states.compactMap({ state -> APIError? in
            if case let .couldNotAsk(error) = state { return error }
            return nil
        }).first {
            return .couldNotAsk(failure)
        }
        if states.contains(where: { $0 == .noneListed }) { return .noneListed }
        // Every leg idle: nothing was asked at all.
        return states.isEmpty ? .notAsked : .notCatalogued
    }

    private static func state<T: Sendable>(
        _ leg: Fetched<T>, isCatalogued: (T) -> Bool
    ) -> ForthcomingVolume.UnknownReason? {
        switch leg {
        case .idle: nil
        case .loading: .notAsked
        case let .failed(error, _): .couldNotAsk(error)
        // A filtered-out shelf (a source answered with rows the language rule
        // or the dedupe removed) lands on `.noneListed` rather than
        // `.notCatalogued`: the source did have a record, and the app chose
        // not to show it.
        case let .loaded(value, _, _): isCatalogued(value) ? .noneListed : .notCatalogued
        }
    }

    // MARK: - Shared rules

    /// Which of "English" and "the original" a language code is, for this
    /// series.
    ///
    /// English wins a tie. An English-original series (`type: "oel"`) has no
    /// implied language and `nativeLanguage` is usually absent, so it never
    /// reaches the tie anyway — but a series that did carry `en` as native
    /// should read as the English edition, which is the heading a reader
    /// recognises.
    ///
    /// `nonisolated static` so `ANNClient` can tag an edition without
    /// building a shelf, and so the tests can reach it directly.
    nonisolated static func role(of language: String, in series: Series) -> EditionLanguageRole {
        let code = language.lowercased()
        if code == "en" { return .english }
        let own = (series.nativeLanguage ?? series.impliedLanguage)?.lowercased()
        return code == own ? .original : .other
    }

    /// Unnumbered releases — box sets, mostly — sort after every numbered one
    /// rather than to the front, which is where a nil-as-zero sort would put
    /// them.
    private static func byNumber(_ lhs: EditionVolume, _ rhs: EditionVolume) -> Bool {
        (lhs.number ?? Int.max, lhs.title) < (rhs.number ?? Int.max, rhs.title)
    }
}

private extension EditionAnswer {
    /// `.notCatalogued` is the one answer that means "this source has never
    /// heard of the series". An empty `.editions` is a source that *has* it.
    var isCatalogued: Bool {
        if case .notCatalogued = self { return false }
        return true
    }
}
