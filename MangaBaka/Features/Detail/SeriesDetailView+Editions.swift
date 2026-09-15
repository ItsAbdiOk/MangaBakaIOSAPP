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
    /// Asks all three, in parallel, and merges whatever answers.
    ///
    /// Parallel rather than sequential on purpose: they are three different
    /// hosts with three different gates, so serialising them would add ANN's
    /// 1.2 s to Open Library's two 4 s slots to NDL's 2 s for no benefit at
    /// all. Open Library's own two requests are still sequential inside its
    /// client — the second needs the first's work key.
    func loadEditions() async {
        isLoadingEditions = true
        defer { isLoadingEditions = false }

        // On-device, no network, and read once rather than per leg: the table
        // is a 451 KB gzipped file behind an actor, and `format(for:)` loads it
        // on first ask. Nil means "not in the table", which is three quarters
        // of the catalogue by row and is not evidence of anything.
        let format = await wikidata.format(for: shown)

        async let annLeg = annVolumes()
        async let openLibraryLeg = openLibraryEditionsAnswer(format: format)
        async let ndlLeg = ndlVolumes(format: format)

        let (ann, open, ndl) = await (annLeg, openLibraryLeg, ndlLeg)
        // A leg cut short by the reader leaving writes nothing (item 30): the
        // merged answer would be a shelf built from cancellations, and
        // `presentableFailure` would then have to unpick it row by row.
        guard !Task.isCancelled else { return }
        editions = VolumeEditions.merge(
            ann: ann, openLibrary: open, ndl: ndl, works: extras.volumes, format: format, for: shown
        )
        await reconcileOwned(with: editions.shelves)
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
        guard let ann else { return .idle }
        return await ann.volumes(for: shown)
    }

    /// Open Library, anchored on an ISBN out of MangaBaka's own works.
    ///
    /// **Never anchored on a title.** `OpenLibraryEditions`' own doc comment
    /// records what a plausible-but-wrong anchor does: feeding it
    /// 9781646090679 for The Apothecary Diaries returned a completely coherent
    /// answer for *Beauty and the Feast*. A bad anchor does not fail, it lies —
    /// so the anchor comes from MangaBaka or the leg does not run.
    private func openLibraryEditionsAnswer(format: WikidataFormat?) async -> Fetched<EditionAnswer> {
        guard let openLibraryEditions, let anchor = Self.anchorISBN(in: extras.volumes) else {
            return .idle
        }
        do throws(APIError) {
            let answer = try await openLibraryEditions.editions(
                anchorISBN: anchor,
                originalLanguage: Self.threeLetter(shown.nativeLanguage ?? shown.impliedLanguage),
                knownFormat: Self.bookFormat(format)
            )
            return .loaded(answer, fetchedAt: Date(), isPartial: false)
        } catch let error {
            return .failed(error, stale: nil)
        }
    }

    /// NDL, and only when the answer could be shown.
    ///
    /// Two guards, both of which save a request rather than filter one after
    /// the fact: the series must have a Japanese title to search with (NDL
    /// finds nothing searched in English), and Japanese must be one of the
    /// languages this shelf shows. A Korean webtoon passes neither.
    private func ndlVolumes(format: WikidataFormat?) async -> Fetched<EditionAnswer> {
        guard let ndl, shown.coverLanguages?.contains("ja") ?? false,
              let japanese = Self.japaneseTitle(of: shown)
        else { return .idle }
        do throws(APIError) {
            let page = try await ndl.volumes(
                japaneseTitle: japanese, format: Self.bookFormat(format)
            )
            // One SRU page of `NDLClient.pageSize`; 薬屋のひとりごと holds 84.
            // `VolumeEditions.merge` marks the shelf, and the owned line then
            // stops saying "of M" over a list it has not seen the end of.
            return .loaded(page.answer, fetchedAt: Date(), isPartial: page.isPartial)
        } catch let error {
            return .failed(error, stale: nil)
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
