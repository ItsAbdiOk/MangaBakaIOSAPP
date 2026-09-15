import os
import SwiftUI

/// The three catalogue legs behind the volumes shelf: Anime News Network,
/// Open Library and the National Diet Library.
///
/// Its own file, beside `+Store.swift`, for the lint's ceiling on
/// `SeriesDetailView` — and because these three are one concern: bibliographic
/// records, none of which sells anything, all of which are third-party hosts
/// with their own politeness limits.
///
/// **Request budget, counted 2026-09-14.** The page already fires nine
/// MangaBaka requests and seven to nine third-party ones. This adds **at most
/// four**, and usually fewer:
///
/// | Leg | Requests | Asked when |
/// |---|---|---|
/// | ANN | 1 | MangaBaka holds an `anime_news_network` id |
/// | Open Library | 2 | MangaBaka's own works carry an ISBN to anchor on |
/// | NDL | 1 | the series' own language is Japanese *and* it has a Japanese title |
///
/// So the worst case is 11–13 third-party requests and the common one is
/// fewer: a Korean webtoon asks ANN nothing it can answer (both webtoon misses
/// in the five-series set are total) and asks NDL nothing at all, because NDL
/// catalogues books published in Japan and a Korean shelf could not show the
/// answer anyway. **Nothing here is fetched that the reader cannot see** — the
/// language rule is checked before the request, not after it, which is the only
/// version of that rule that costs nothing.
///
/// Each leg is independently optional and independently failable. A leg with no
/// client, no id, or no answer contributes `.idle` or `.failed` and the other
/// two render — see `Fetched` and `VolumeEditionAnswer.failures`.
extension SeriesDetailView {
    /// Asks all three, in parallel, merging each leg's answer in as it lands
    /// rather than waiting for the slowest.
    ///
    /// Parallel rather than sequential on purpose: they are three different
    /// hosts with three different gates, so serialising them would add ANN's
    /// 1.2 s to Open Library's two 4 s slots to NDL's 2 s for no benefit at
    /// all. Open Library's own two requests are still sequential inside its
    /// client — the second needs the first's work key.
    ///
    /// **Progressive, since 2026-09-15 (item P1).** ANN answers in well under
    /// a second; Open Library's second request waits behind a 4 s gate and,
    /// behind interleaved cover HEADs, up to 8–12 s. The old shape awaited all
    /// three with `async let` and merged once, so ANN's rows sat unseen behind
    /// a skeleton for the whole span. `VolumeEditions.merge` is pure and runs
    /// in well under a millisecond even at the worst-case row count (`docs/
    /// reviews/perf/editions.md`, P10) — cheap enough to re-run once per leg
    /// rather than once per page.
    func loadEditions() async {
        isLoadingEditions = true
        // Backstop for an early return (a cancelled page, an empty ISBN): the
        // per-result `remerge` inside `runEditionLegs` sets the honest value
        // on every step that actually runs; this only covers the paths that
        // skip it.
        defer { isLoadingEditions = false }

        // On-device, no network, and read once rather than per leg: the table
        // is a 451 KB gzipped file behind an actor, and `format(for:)` loads it
        // on first ask. Nil means "not in the table", which is three quarters
        // of the catalogue by row and is not evidence of anything.
        let format = await wikidata.format(for: shown)

        await drawStoredEditionsIfNeeded()
        await runEditionLegs(format: format)

        guard !Task.isCancelled else { return }
        // Persisted here, where the merge happens, so the Next-volume widget
        // can read this page's forthcoming volume for 30 days without the
        // merge being re-derived anywhere else (`EditionAnswerStore`).
        await editionAnswers?.write(editions, for: shown.id)
        await reconcileOwned(with: editions.shelves)
    }

    /// The 30-day merged answer, drawn before any leg has run (item P2).
    ///
    /// Only when the page has nothing of its own yet — a re-run (the reader
    /// ticked a row, `reconcileOwned` moved something) must not stomp the
    /// fresher in-memory answer with yesterday's disk copy.
    private func drawStoredEditionsIfNeeded() async {
        guard editions.isEmpty, let stored = await editionAnswers?.answer(for: shown.id) else { return }
        editions = stored.answer
        Self.editionsLogger.log(
            "leg=stored outcome=hit rows=\(stored.answer.shelves.count, privacy: .public)"
        )
    }

    /// One leg's result, tagged so the single `for await` loop in
    /// `runEditionLegs` can tell which local variable to update — three
    /// different `Sendable` payloads, one channel, rather than three
    /// unstructured `Task`s each mutating a shared `var` from a different
    /// thread.
    private enum EditionLeg: Sendable {
        case ann(Fetched<ANNVolumes>)
        case openLibrary(Fetched<EditionAnswer>)
        case ndl(Fetched<EditionAnswer>, totalRecords: Int?)
    }

    /// Asks all three legs in parallel, merging each one's answer in as it
    /// lands rather than waiting for the slowest (item P1). See
    /// `loadEditions`'s own doc comment for why this is progressive.
    private func runEditionLegs(format: WikidataFormat?) async {
        var ann: Fetched<ANNVolumes> = .loading
        var openLibrary: Fetched<EditionAnswer> = .loading
        var ndl: Fetched<EditionAnswer> = .loading
        var ndlTotalRecords: Int?

        // Re-merges with whatever is known so far. A leg still `.loading`
        // contributes nothing to the shelves (`VolumeEditionMerge.state`
        // maps it to "not asked yet") without blocking the legs that have
        // already answered — the whole point of running this per result
        // rather than once at the end.
        func remerge() {
            editions = VolumeEditions.merge(
                ann: ann, openLibrary: openLibrary, ndl: ndl, ndlTotalRecords: ndlTotalRecords,
                works: extras.volumes, format: format, for: shown
            )
            isLoadingEditions = ann.isLoading || openLibrary.isLoading || ndl.isLoading
        }

        await withTaskGroup(of: EditionLeg.self) { group in
            group.addTask { .ann(await self.annVolumes()) }
            group.addTask { .openLibrary(await self.openLibraryEditionsAnswer(format: format)) }
            group.addTask {
                let (leg, total) = await self.ndlVolumes(format: format)
                return .ndl(leg, totalRecords: total)
            }

            // Each iteration of this loop runs on the caller's actor
            // (`SeriesDetailView` is `@MainActor`), one result at a time, even
            // though the three child tasks race concurrently — so `ann`,
            // `openLibrary` and `ndl` above are never written from two places
            // at once.
            for await result in group {
                switch result {
                case let .ann(value): ann = value
                case let .openLibrary(value): openLibrary = value
                case let .ndl(value, total):
                    ndl = value
                    ndlTotalRecords = total
                }
                // A leg cut short by the reader leaving writes nothing
                // (item 30): the merged answer would be a shelf built from a
                // cancellation, and `presentableFailure` would then have to
                // unpick it row by row.
                guard !Task.isCancelled else { continue }
                remerge()
            }
        }
    }

    /// One line per third-party leg, at the merge site — the only place that
    /// sees every leg's own outcome (item P11). Before this, zero of the
    /// 4,326 lines in `Core/Editions`/`Core/Volumes` logged anything: a
    /// swallowed transport error or a cache miss was unanswerable on a
    /// device. Category `"editions"` so it can be filtered on its own in the
    /// Console.
    private static let editionsLogger = Logger(
        subsystem: "dev.abdirahmanmohamed.mangabaka", category: "editions"
    )

    /// `leg=<ann|openLibrary|ndl> outcome=<idle|hit|failed> rows=<n>
    /// partial=<bool> ms=<n>` — counts and timings only, never reader text,
    /// so every field is `.public`. `start` is a plain `Date` rather than a
    /// `ContinuousClock.Instant`: the three leg functions already take a
    /// wall-clock `Date()` for `fetchedAt`, and a second clock family here
    /// would be the "two ways to get one number" this project rejects.
    private static func logLeg<T>(_ name: String, start: Date, result: Fetched<T>, rows: Int, partial: Bool) {
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        switch result {
        case .idle:
            editionsLogger.log("leg=\(name, privacy: .public) outcome=idle ms=\(ms, privacy: .public)")
        case .loading:
            break
        case let .failed(error, _):
            editionsLogger.log(
                """
                leg=\(name, privacy: .public) outcome=failed rows=\(rows, privacy: .public) \
                ms=\(ms, privacy: .public) error=\(String(describing: error), privacy: .public)
                """
            )
        case .loaded:
            editionsLogger.log(
                """
                leg=\(name, privacy: .public) outcome=hit rows=\(rows, privacy: .public) \
                partial=\(partial, privacy: .public) ms=\(ms, privacy: .public)
                """
            )
        }
    }

    /// A tick taken on a row before it had an ISBN is moved to the ISBN once
    /// the row carries one — see `OwnedVolumes.reconcile(shelves:for:)`.
    /// Runs after every merge because the shelf is what knows both spellings
    /// of the row, and re-reads the ticks only when something moved.
    private func reconcileOwned(with shelves: [EditionShelf]) async {
        guard let ownedVolumes else { return }
        do {
            let moved = try await ownedVolumes.reconcile(shelves: shelves, for: shown.id)
            if moved > 0 { owned = try await ownedVolumes.owned(for: shown.id) }
        } catch let error {
            Self.ownedLogger.error("Owned volumes could not be reconciled: \(error, privacy: .public)")
        }
    }

    // MARK: - The reader's own shelf

    /// What the section reads through `\.ownedShelf` — see
    /// `EditionShelvesSection`'s doc comment for why it is an environment
    /// value and not a parameter. Nil when the page has no store, so the rows
    /// draw with no ticks rather than ticks that cannot be kept.
    var ownedShelfControls: OwnedShelfControls? {
        guard ownedVolumes != nil else { return nil }
        return OwnedShelfControls(
            seriesID: shown.id, owned: owned, toggle: toggleOwned, scan: { isScanning = true }
        )
    }

    /// The reader's ticks for this series, off the reader's own file.
    ///
    /// A read that throws leaves `owned` empty and logs: on the corrupt-
    /// database fallback the table does not exist (`OwnedVolumes` records
    /// why), and a page that crashed for it would be worse than a page with
    /// no ticks. Not `.failed` into the failure kit — there is no request to
    /// retry, and the only reader-facing consequence is ticks that do not
    /// appear, which the log is enough to diagnose.
    func loadOwned() async {
        guard let ownedVolumes else { return }
        do {
            owned = try await ownedVolumes.owned(for: shown.id)
        } catch let error {
            Self.ownedLogger.error("Owned volumes could not be read: \(error, privacy: .public)")
        }
    }

    /// Ticks or unticks one row, optimistically. The write is off the main
    /// actor; the set is updated first so the circle fills under the finger,
    /// and put back if the write fails.
    func toggleOwned(_ volume: EditionVolume) {
        guard let ownedVolumes else { return }
        let key = OwnedVolumeKey(seriesID: shown.id, volume: volume)
        let nowOwned = !owned.contains(key)
        if nowOwned { owned.insert(key) } else { owned.remove(key) }
        Task {
            do {
                try await ownedVolumes.setOwned(key, nowOwned)
            } catch let error {
                Self.ownedLogger.error("Owned volume could not be written: \(error, privacy: .public)")
                if nowOwned { owned.remove(key) } else { owned.insert(key) }
            }
        }
    }

    private static let ownedLogger = Logger(
        subsystem: "dev.abdirahmanmohamed.mangabaka", category: "owned"
    )

    // MARK: - The three legs

    /// ANN answers a whole series in one request and already returns a
    /// `Fetched`, including the "MangaBaka holds no ANN id" case as a real
    /// `.loaded(isCatalogued: false)` rather than a failure.
    private func annVolumes() async -> Fetched<ANNVolumes> {
        let start = Date()
        guard let ann else {
            Self.logLeg("ann", start: start, result: Fetched<ANNVolumes>.idle, rows: 0, partial: false)
            return .idle
        }
        let result = await ann.volumes(for: shown)
        Self.logLeg(
            "ann", start: start, result: result, rows: result.value?.volumes.count ?? 0, partial: false
        )
        return result
    }

    /// Open Library, anchored on an ISBN out of MangaBaka's own works.
    ///
    /// **Never anchored on a title.** `OpenLibraryEditions`' own doc comment
    /// records what a plausible-but-wrong anchor does: feeding it
    /// 9781646090679 for The Apothecary Diaries returned a completely coherent
    /// answer for *Beauty and the Feast*. A bad anchor does not fail, it lies —
    /// so the anchor comes from MangaBaka or the leg does not run.
    private func openLibraryEditionsAnswer(format: WikidataFormat?) async -> Fetched<EditionAnswer> {
        let start = Date()
        guard let openLibraryEditions, let anchor = Self.anchorISBN(in: extras.volumes) else {
            Self.logLeg(
                "openLibrary", start: start, result: Fetched<EditionAnswer>.idle, rows: 0, partial: false
            )
            return .idle
        }
        do throws(APIError) {
            // `editionsWithFetchedAt`, not `editions`: this is the one caller
            // that needs the honest `fetchedAt` (a cache hit's own storedAt,
            // not "now") and the real `isPartial` off Open Library's `size`
            // field, rather than the hard-coded `false` this used to pass
            // (items P6, P13).
            let timed = try await openLibraryEditions.editionsWithFetchedAt(
                anchorISBN: anchor,
                originalLanguage: Self.threeLetter(shown.nativeLanguage ?? shown.impliedLanguage),
                knownFormat: Self.bookFormat(format)
            )
            let result = Fetched.loaded(timed.answer, fetchedAt: timed.fetchedAt, isPartial: timed.isPartial)
            Self.logLeg(
                "openLibrary", start: start, result: result, rows: timed.answer.rows.count,
                partial: timed.isPartial
            )
            return result
        } catch let error {
            let result = Fetched<EditionAnswer>.failed(error, stale: nil)
            Self.logLeg("openLibrary", start: start, result: result, rows: 0, partial: false)
            return result
        }
    }

    /// NDL, and only when the answer could be shown.
    ///
    /// Two guards, both of which save a request rather than filter one after
    /// the fact: the series must have a Japanese title to search with (NDL
    /// finds nothing searched in English), and Japanese must be one of the
    /// languages this shelf shows. A Korean webtoon passes neither.
    ///
    /// - Returns: the leg for `VolumeEditions.merge`, and separately NDL's own
    ///   `<numberOfRecords>` — `EditionAnswer` has no field for it, and
    ///   `merge` takes it as its own parameter so a partial NDL shelf can say
    ///   "first 50 of 84 on record" (item P3) instead of only "partial".
    private func ndlVolumes(
        format: WikidataFormat?
    ) async -> (leg: Fetched<EditionAnswer>, totalRecords: Int?) {
        let start = Date()
        guard let ndl, shown.coverLanguages?.contains("ja") ?? false,
              let japanese = Self.japaneseTitle(of: shown)
        else {
            Self.logLeg("ndl", start: start, result: Fetched<EditionAnswer>.idle, rows: 0, partial: false)
            return (.idle, nil)
        }
        do throws(APIError) {
            let page = try await ndl.volumes(
                japaneseTitle: japanese, format: Self.bookFormat(format)
            )
            // One SRU page of `NDLClient.pageSize`; 薬屋のひとりごと holds 84.
            // `VolumeEditions.merge` marks the shelf, and the owned line then
            // stops saying "of M" over a list it has not seen the end of.
            // `page.storedAt`, not `Date()`: a cache hit now says when it was
            // really fetched rather than "just now" (item P13).
            let result = Fetched.loaded(page.answer, fetchedAt: page.storedAt, isPartial: page.isPartial)
            Self.logLeg(
                "ndl", start: start, result: result, rows: page.answer.rows.count, partial: page.isPartial
            )
            return (result, page.totalRecords)
        } catch let error {
            let result = Fetched<EditionAnswer>.failed(error, stale: nil)
            Self.logLeg("ndl", start: start, result: result, rows: 0, partial: false)
            return (result, nil)
        }
    }

    // MARK: - What each leg needs before it can run

    /// The first ISBN MangaBaka's own works list carries, in volume order.
    ///
    /// Volume order, not dictionary order, and deliberately the *first* volume
    /// where there is one: Open Library files printings under a work, and
    /// volume 1 is the printing most likely to have siblings in other
    /// languages. `nonisolated static` so a test can assert the choice without
    /// a view.
    nonisolated static func anchorISBN(in volumes: [SeriesWork.Volume]) -> String? {
        let numbered = volumes
            .compactMap { volume -> (Int, String)? in
                guard let number = volume.number.flatMap(Int.init),
                      let isbn = volume.editions.compactMap(\.isbn).first
                else { return nil }
                return (number, isbn)
            }
            .sorted { $0.0 < $1.0 }
        if let first = numbered.first { return first.1 }
        // A series whose every volume is unnumbered ("Other editions") still
        // has an ISBN worth anchoring on.
        return volumes.flatMap { $0.editions }.compactMap(\.isbn).first
    }

    /// The series' own Japanese title, excluding romanisations.
    ///
    /// `-Latn` is excluded for the same reason `Series.nativeLanguage` excludes
    /// it: a romanisation is a reading of the title, not the title, and NDL's
    /// `title=` search in Latin script finds nothing. Solo Leveling carries
    /// `ja-Latn` and `ja` titles both, so first-match without this guard would
    /// sometimes search NDL for "Ore dake Level Up na Ken".
    nonisolated static func japaneseTitle(of series: Series) -> String? {
        series.titles?.first { title in
            title.language.lowercased() == "ja" && Self.isJapaneseScript(title.title)
        }?.title
    }

    /// Whether a title marked `ja` is actually written in Japanese.
    ///
    /// It often is not: One Piece's `ja` title is the Latin string "ONE
    /// PIECE", and MangaBaka carries dozens like it. Sending that to NDL's
    /// SRU is worse than sending nothing — measured 2026-09-14, a
    /// `title="ONE PIECE"` search answered 935 records whose titles were
    /// 俺だけレベルアップな件 (Solo Leveling). Their title index matches a
    /// Latin string loosely enough to return an unrelated series, and a
    /// wrong volume on a shelf is worse than an absent one.
    ///
    /// Kanji, hiragana and katakana only. A title that is entirely Latin or
    /// digits is refused; one that mixes scripts ("ONE PIECE 巻一") passes,
    /// because the Japanese part is what NDL will key on.
    nonisolated static func isJapaneseScript(_ title: String) -> Bool {
        title.unicodeScalars.contains { scalar in
            (0x3040...0x30FF).contains(scalar.value)      // kana
                || (0x4E00...0x9FFF).contains(scalar.value)   // CJK ideographs
                || (0x3400...0x4DBF).contains(scalar.value)   // CJK extension A
        }
    }

    /// What Wikidata's answer means to a bibliographic client.
    ///
    /// `.unknown` for a series the table has never heard of — which is what
    /// both clients document as "turn the genre filter off and let every
    /// titled record through". That is the honest reading of an absent answer,
    /// and it is what they did before this table existed.
    nonisolated static func bookFormat(_ format: WikidataFormat?) -> BookEdition.Format {
        guard let format else { return .unknown }
        if format.isComic { return .comic }
        if format.isProse { return .prose }
        // `.other` — Wikidata knows this item and calls it an anime, a film, a
        // video game. Not a book of either kind, and not a thing to assert a
        // genre filter on.
        return .unknown
    }

    /// Two-letter to the ISO 639-2/B form `OpenLibraryEditions` filters on.
    ///
    /// The inverse of `BookEditionShelf.twoLetter`, and only for the codes
    /// `Series.nativeLanguage`/`impliedLanguage` can produce. An unmapped code
    /// is nil — "we cannot state the original language" — rather than a guess,
    /// because the value goes straight into a filter that decides which rows
    /// the reader sees.
    nonisolated static func threeLetter(_ code: String?) -> String? {
        guard let code = code?.lowercased() else { return nil }
        let table = ["ja": "jpn", "ko": "kor", "zh": "chi", "en": "eng"]
        return table[code]
    }
}
