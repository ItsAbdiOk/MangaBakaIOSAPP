import Foundation
import Testing
@testable import MangaBaka

/// The merge of three catalogues into one shelf.
///
/// Every test here fails on the code as it stood at `be75a2e`, where
/// `VolumeEditions.merge` took one argument (`ann:for:`) and `VolumeCatalogue`
/// had one case. The expected failures are named per test, because they could
/// not be run before the change was written.
@Suite("Volume edition merge")
struct VolumeEditionMergeTests {
    // MARK: - Cross-source dedupe

    /// Measured 2026-09-14 (`docs/sources/publishers.md`): ANN has Delicious in
    /// Dungeon vol. 1 at ean 9780316471855 with an exact date, and Open Library
    /// files a printing under the same ISBN. Two sources describing one book is
    /// one row.
    ///
    /// **Expected to fail before the change with:** a compile error —
    /// `merge(ann:openLibrary:ndl:works:format:for:)` did not exist, nor did
    /// `VolumeCatalogue.openLibrary` or `EditionVolume.alsoFrom`. With the
    /// signature alone and no dedupe it would fail on
    /// `#expect(rows.count == 1)` with `rows.count == 2`.
    @Test("One ISBN stated by two sources is one row, and both are credited")
    func deduplicatesOnISBN13() {
        let series = SeriesFactory.make(id: 17164, title: "Delicious in Dungeon", type: "manga")
        let answer = VolumeEditions.merge(
            ann: .loaded(
                ANNVolumes(volumes: [annVolume(1, isbn: "9780316471855", date: "2017-05-23")],
                           isCatalogued: true),
                fetchedAt: .now, isPartial: false
            ),
            openLibrary: .loaded(
                .editions([bookRow(isbn: "9780316471855", published: "2017", source: .openLibrary)]),
                fetchedAt: .now, isPartial: false
            ),
            for: series
        )

        let rows = answer.shelves.flatMap(\.volumes)
        #expect(rows.count == 1, "Two sources, one book — got \(rows.count) rows")
        let row = rows.first
        #expect(row?.edition.catalogue == .animeNewsNetwork, "The better-populated row wins")
        #expect(row?.alsoFrom == [.openLibrary], "The loser of the collapse still said it")
        #expect(
            answer.credits == [.animeNewsNetwork, .openLibrary],
            "Both sources put this row on screen, so both are owed a credit"
        )
    }

    /// Rule 3 in `VolumeEditions`' own doc comment: a bare `2012` is not a
    /// publication day and must never displace a dated row just because its
    /// source won the row on other fields.
    ///
    /// **Expected to fail before the change with:** a compile error on
    /// `dateFrom`. With a dedupe that simply kept the winner's fields it would
    /// fail on the precision expectation, reading `.year` instead of `.day`.
    @Test("A full date beats a partial one whoever stated it, and the row records who won")
    func fullerDateWinsAndIsAttributed() throws {
        let series = SeriesFactory.make(id: 3397, title: "Solo Leveling", type: "manhwa")
        // ANN's row is fuller overall — it carries a number and its own
        // Encyclopedia link — but its date here is year-only; the Open Library
        // row is thinner in every field except the one that matters, and states
        // the day. That is the exact case the rule is for: source rank and date
        // precision are independent questions.
        let answer = VolumeEditions.merge(
            ann: .loaded(
                ANNVolumes(volumes: [annVolume(1, isbn: "9781975319434", date: "2021")],
                           isCatalogued: true),
                fetchedAt: .now, isPartial: false
            ),
            openLibrary: .loaded(
                .editions([bookRow(isbn: "9781975319434", published: "2021-03-02",
                                   source: .openLibrary, volume: nil, linkable: false)]),
                fetchedAt: .now, isPartial: false
            ),
            for: series
        )

        let row = try #require(answer.shelves.flatMap(\.volumes).first)
        #expect(row.edition.catalogue == .animeNewsNetwork)
        #expect(row.releaseDate?.precision == .day, "The day-precision date wins the field")
        #expect(row.dateFrom == .openLibrary, "And the row records whose date it is showing")
    }

    // MARK: - Language

    /// The shelf shows English and the series' original language, and nothing
    /// else (Abdi, 2026-09-14). One rule — `Series.coverLanguages`, the same
    /// one the cover fan uses — applied to every source at once.
    ///
    /// The French Solo Leveling printing (KBOOKS, 9782382880296) is a real row
    /// measured that day in the same Open Library response as the English one.
    ///
    /// **Expected to fail before the change with:** a compile error, and then —
    /// once the signature existed but without the filter being applied to the
    /// `BookEdition` legs — `languages` would read
    /// `["en", "fr", "ja"]` rather than `["en", "ja"]`.
    @Test("The shelf shows English and the original language, and drops every third")
    func showsOnlyEnglishAndTheOriginal() {
        let series = SeriesFactory.make(
            id: 17164,
            titles: [
                SeriesTitle(language: "en", traits: ["official"], title: "Delicious in Dungeon",
                            isPrimary: true),
                SeriesTitle(language: "ja", traits: ["native"], title: "ダンジョン飯", isPrimary: true)
            ],
            type: "manga"
        )
        let answer = VolumeEditions.merge(
            openLibrary: .loaded(
                .editions([
                    bookRow(isbn: "9781975319434", published: "2021-03-02", source: .openLibrary,
                            language: "eng", title: "Delicious in Dungeon, Vol. 1"),
                    bookRow(isbn: "9782382880296", published: "2021-04-07", source: .openLibrary,
                            language: "fre", title: "Gloutons & Dragons T01"),
                    bookRow(isbn: "9784047301535", published: "2015-01-15", source: .openLibrary,
                            language: "jpn", title: "ダンジョン飯 1")
                ]),
                fetchedAt: .now, isPartial: false
            ),
            for: series
        )

        let languages = Set(answer.shelves.map(\.edition.language))
        #expect(languages == ["en", "ja"], "French is neither English nor the original — got \(languages)")
        #expect(
            !answer.shelves.flatMap(\.volumes).contains { $0.title.contains("Gloutons") },
            "The French printing must not reach the shelf"
        )
    }

    // MARK: - Wikidata

    /// The Apothecary Diaries bug, in the form the table can actually prevent:
    /// a light-novel printing must not land on a comic shelf. A `.prose`
    /// `BookEdition` becomes `VolumeFormat.other`, and merge drops those when —
    /// and only when — Wikidata positively says the series is a comic.
    ///
    /// **Expected to fail before the change with:** a compile error on the
    /// `format:` parameter. With the parameter but no filter, it would fail on
    /// `#expect(titles == ["薬屋のひとりごと 1"])`, reading both rows.
    @Test("A prose printing is refused a comic shelf when Wikidata says the series is a comic")
    func prosePrintingIsRefusedAComicShelf() {
        let series = SeriesFactory.make(
            id: 106_090_656,
            titles: [SeriesTitle(language: "ja", traits: ["native"], title: "薬屋のひとりごと",
                                 isPrimary: true)],
            type: "manga"
        )
        let rows = [
            bookRow(isbn: "9784041104361", published: "2017-09-22", source: .nationalDietLibrary,
                    language: "jpn", title: "薬屋のひとりごと 1", format: .comic),
            bookRow(isbn: "9784074105502", published: "2014-08-30", source: .nationalDietLibrary,
                    language: "jpn", title: "薬屋のひとりごと 1 (ヒーロー文庫)", format: .prose)
        ]
        let answer = VolumeEditions.merge(
            ndl: .loaded(.editions(rows), fetchedAt: .now, isPartial: false),
            format: .manga,
            for: series
        )

        let titles = answer.shelves.flatMap(\.volumes).map(\.title)
        #expect(titles == ["薬屋のひとりごと 1"], "The light novel must not be on the comic shelf")
    }

    /// `nil` means "not in the table", which is three quarters of the catalogue
    /// by row and is not evidence of anything. A filter that treated it as a
    /// negative would hide real volumes.
    ///
    /// **Expected to fail before the change with:** a compile error on
    /// `format:`. It is the control for the test above — the same rows, the
    /// same call, one argument different, and a known answer (both rows).
    @Test("A series the Wikidata table has never heard of filters nothing")
    func absentWikidataAnswerFiltersNothing() {
        let series = SeriesFactory.make(
            id: 1,
            titles: [SeriesTitle(language: "ja", traits: ["native"], title: "薬屋のひとりごと",
                                 isPrimary: true)],
            type: "manga"
        )
        let rows = [
            bookRow(isbn: "9784041104361", published: "2017-09-22", source: .nationalDietLibrary,
                    language: "jpn", title: "薬屋のひとりごと 1", format: .comic),
            bookRow(isbn: "9784074105502", published: "2014-08-30", source: .nationalDietLibrary,
                    language: "jpn", title: "薬屋のひとりごと 1 (ヒーロー文庫)", format: .prose)
        ]
        let answer = VolumeEditions.merge(
            ndl: .loaded(.editions(rows), fetchedAt: .now, isPartial: false),
            format: nil,
            for: series
        )
        #expect(answer.shelves.flatMap(\.volumes).count == 2, "An absent answer is not a negative")
    }

    // MARK: - MangaBaka's own shelf

    /// A third-party row the reader is already looking at, a few pixels up, is
    /// not drawn twice — but only when MangaBaka's own row carries a date.
    ///
    /// **Expected to fail before the change with:** a compile error on
    /// `works:`. With the parameter but no suppression it would fail on the
    /// first expectation, reading 1 instead of 0.
    @Test("A dated MangaBaka volume suppresses the same ISBN; an undated one does not")
    func mangaBakaSuppressesOnlyWhatItHasDated() {
        let series = SeriesFactory.make(id: 17164, title: "Delicious in Dungeon", type: "manga")
        let ann = Fetched.loaded(
            ANNVolumes(volumes: [annVolume(1, isbn: "9780316471855", date: "2017-05-23")],
                       isCatalogued: true),
            fetchedAt: .now, isPartial: false
        )
        let dated = VolumeEditions.merge(
            ann: ann, works: [work(isbn: "9780316471855", date: "2017-05-23")], for: series
        )
        #expect(dated.shelves.isEmpty, "MangaBaka already shows this exact book, dated")

        let undated = VolumeEditions.merge(
            ann: ann, works: [work(isbn: "9780316471855", date: nil)], for: series
        )
        #expect(
            undated.shelves.flatMap(\.volumes).count == 1,
            "An undated MangaBaka row must not swallow a source that can date it"
        )
    }

    // MARK: - Failures and absence

    /// Rule 4: nothing here can say the series has finished. One leg failing
    /// must not turn into an ending, and must not stop the others rendering.
    ///
    /// **Expected to fail before the change with:** a compile error on
    /// `openLibrary:`/`ndl:`, and `failures` carrying only ANN.
    @Test("One leg failing leaves the others on screen and is reported by name")
    func aFailedLegDoesNotCostTheOthers() {
        let series = SeriesFactory.make(id: 17164, title: "Delicious in Dungeon", type: "manga")
        let answer = VolumeEditions.merge(
            ann: .loaded(
                ANNVolumes(volumes: [annVolume(1, isbn: "9780316471855", date: "2017-05-23")],
                           isCatalogued: true),
                fetchedAt: .now, isPartial: false
            ),
            openLibrary: .failed(.offline, stale: nil),
            ndl: .failed(.rateLimited(retryAfter: 60, party: .nationalDietLibrary), stale: nil),
            for: series
        )

        #expect(answer.shelves.count == 1, "ANN answered and its shelf must still draw")
        #expect(answer.failures[.openLibrary] == .offline)
        #expect(answer.failures[.nationalDietLibrary] != nil)
        #expect(
            answer.credits == [.animeNewsNetwork],
            "A source that put no row on screen is owed no credit, failed or not"
        )
    }

    /// "Nobody has been asked yet" outranks every other kind of nothing. A
    /// page whose legs are still out has not learned anything, and must not
    /// say it has.
    ///
    /// **Expected to fail before the change with:** a compile error; the old
    /// `unasked` read one leg.
    @Test("A leg still in flight beside a not-catalogued one is not-asked, never an ending")
    func inFlightOutranksNotCatalogued() {
        let series = SeriesFactory.make(id: 3397, title: "Solo Leveling", type: "manhwa")
        let answer = VolumeEditions.merge(
            ann: .loaded(
                ANNVolumes(volumes: [], isCatalogued: false), fetchedAt: .now, isPartial: false
            ),
            openLibrary: .loading,
            for: series
        )
        #expect(answer.forthcoming(asOf: .now) == .unknown(.notAsked))
    }

    /// The distinction the test above rests on, and the reason it says
    /// `.loading` rather than `.idle`.
    ///
    /// `SeriesDetailView+Editions` returns `.idle` for a leg that does not
    /// apply to this series at all — no client, no anchor ISBN, or a series
    /// that is not Japanese. A Korean webtoon skips both library legs that
    /// way. Counting those as "not asked yet" meant such a series could never
    /// say anything about a forthcoming volume, however clearly ANN had
    /// answered (2026-09-14).
    @Test("A leg that does not apply does not hold the answer open")
    func skippedLegDoesNotOutrank() {
        let series = SeriesFactory.make(id: 3397, title: "Solo Leveling", type: "manhwa")
        let answer = VolumeEditions.merge(
            ann: .loaded(
                ANNVolumes(volumes: [], isCatalogued: false), fetchedAt: .now, isPartial: false
            ),
            openLibrary: .idle,
            ndl: .idle,
            for: series
        )
        #expect(answer.forthcoming(asOf: .now) == .unknown(.notCatalogued))
    }

    /// The control: nothing asked at all is still `.notAsked`.
    @Test("Every leg skipped is not-asked")
    func nothingAskedIsNotAsked() {
        let answer = VolumeEditions.merge(for: SeriesFactory.make(id: 1, title: "Anything"))
        #expect(answer.forthcoming(asOf: .now) == .unknown(.notAsked))
    }

    // MARK: - Helpers

    private func annVolume(_ number: Int, isbn: String?, date: String) -> EditionVolume {
        EditionVolume(
            number: number,
            title: "Delicious in Dungeon (GN \(number))",
            releaseDate: PartialDate.parse(date),
            isbn13: isbn,
            format: .print,
            edition: VolumeEdition(
                catalogue: .animeNewsNetwork, language: "en", languageRole: .english,
                editionTitle: "Delicious in Dungeon"
            ),
            sourceLink: URL(string: "https://www.animenewsnetwork.com/encyclopedia/manga.php?id=17164")
        )
    }

    private func bookRow(
        isbn: String,
        published: String,
        source: BookEdition.Source,
        language: String = "eng",
        title: String = "Delicious in Dungeon, Vol. 1",
        format: BookEdition.Format = .comic,
        volume: String? = "1",
        /// False gives the row an id that resolves to no catalogue page, so the
        /// row is genuinely thinner — which is how a test can make a specific
        /// source lose the dedupe on purpose rather than by accident.
        linkable: Bool = true
    ) -> BookEdition {
        BookEdition(
            id: !linkable
                ? "unresolvable-\(isbn)"
                : source == .openLibrary
                ? "/books/OL\(isbn.suffix(6))M"
                : "https://ndlsearch.ndl.go.jp/books/R100000002-I\(isbn.suffix(6))",
            title: title,
            isbn13: isbn,
            publisher: source == .openLibrary ? "Yen Press" : "KADOKAWA",
            language: language,
            published: PartialDate.parse(published),
            coverID: nil,
            volume: volume,
            source: source,
            format: format,
            formatEvidence: .anchorISBN(isbn)
        )
    }

    private func work(isbn: String, date: String?) -> SeriesWork.Volume {
        SeriesWork.Volume(
            number: "1",
            editions: [
                SeriesWork(
                    id: "w-\(isbn)", sequenceString: "1", sequenceNumeric: 1, subTitle: nil,
                    releaseDate: date, pages: nil, prices: nil,
                    identifiers: [SeriesWork.Identifier(id: isbn, name: "isbn")],
                    links: nil, images: nil
                )
            ]
        )
    }
}
