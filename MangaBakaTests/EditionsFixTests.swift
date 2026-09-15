import Foundation
import Testing
@testable import MangaBaka

// Shared across both suites below — a struct at 250 lines of body is
// SwiftLint's `type_body_length` ceiling, so the batch is split in two,
// sharing these file-scope helpers rather than duplicating them.

private func fixEdition(_ catalogue: VolumeCatalogue = .animeNewsNetwork) -> VolumeEdition {
    VolumeEdition(catalogue: catalogue, language: "en", languageRole: .english, editionTitle: "Mock")
}

private func fixVolume(_ number: Int, _ date: String) -> EditionVolume {
    EditionVolume(
        number: number, title: "Mock (GN \(number))", releaseDate: PartialDate.parse(date),
        isbn13: "978000000000\(number % 10)", format: .print, edition: fixEdition(),
        sourceLink: URL(string: "https://www.animenewsnetwork.com/encyclopedia/manga.php?id=1")
    )
}

private func fixAnswer(_ volumes: [EditionVolume]) -> VolumeEditionAnswer {
    VolumeEditionAnswer(
        shelves: [EditionShelf(edition: fixEdition(), volumes: volumes)],
        credits: [.animeNewsNetwork], failures: [:], unaskedReason: nil
    )
}

/// Tests for the 2026-09-15 perf-review fix batch
/// (`docs/reviews/perf/editions.md`, ids P1–P19). Grouped by finding rather
/// than by file, since several of these touch two or three files for one
/// behaviour. Split from `EditionsFixTestsPartTwo` below purely for
/// `type_body_length` — read the two as one suite.
@Suite("Editions fix batch")
struct EditionsFixTests {
    // MARK: - P2: the 30-day stored answer, read before any leg runs

    private func edition(_ catalogue: VolumeCatalogue = .animeNewsNetwork) -> VolumeEdition {
        fixEdition(catalogue)
    }

    private func volume(_ number: Int, _ date: String) -> EditionVolume {
        fixVolume(number, date)
    }

    private func answer(_ volumes: [EditionVolume]) -> VolumeEditionAnswer {
        fixAnswer(volumes)
    }

    /// Fails on the code as it stood before this batch with a compile error:
    /// `EditionAnswerStore` had no `answer(for:)` — `forthcoming(for:)` was
    /// the only reader, and it decodes a narrower partial type that cannot
    /// answer this question at all.
    @Test("The stored answer reads back with when it was written")
    func storedAnswerReadsBack() async throws {
        let database = try AppDatabase.inMemory()
        let clock = TestClock(now: Date(timeIntervalSince1970: 1_789_000_000))
        let store = EditionAnswerStore(database: database, clock: clock)
        await store.write(answer([volume(12, "2026-10-03")]), for: 7)

        let stored = await store.answer(for: 7)
        #expect(stored?.answer.shelves.first?.volumes.count == 1)
        #expect(stored?.fetchedAt == clock.now)
    }

    /// A read past `freshness` must not hand the page a fact it can no
    /// longer stand behind — the same rule `forthcoming(for:)` already
    /// applies, checked here against the sibling reader.
    @Test("A stored answer older than freshness is not returned")
    func staleStoredAnswerIsNil() async throws {
        let database = try AppDatabase.inMemory()
        let clock = TestClock(now: Date(timeIntervalSince1970: 1_789_000_000))
        let store = EditionAnswerStore(database: database, clock: clock)
        await store.write(answer([volume(12, "2026-10-03")]), for: 7)

        clock.advance(by: EditionAnswerStore.freshness + 1)
        let stored = await store.answer(for: 7)
        #expect(stored == nil)
    }

    // MARK: - P3: a partial NDL shelf says how partial

    /// `ndl-apothecary-diaries.xml` is the recorded 8-of-84 page
    /// (`docs/sources/bibliographic.md`). Fails before this batch with a
    /// compile error — `NDLClient.Answer` had no `totalRecords` field.
    @Test("A partial NDL page carries its totalRecords through the answer")
    func ndlTotalRecordsCarriesThrough() throws {
        let data = try Fixture.data("ndl-apothecary-diaries", extension: "xml")
        let answer = try #require(
            NDLClient.answer(title: "薬屋のひとりごと", format: .comic, from: data)
        )
        #expect(answer.isPartial)
        #expect(answer.totalRecords == 84)
    }

    /// `OwnedSummary.line` reads `EditionShelf.totalRecords` for the honest
    /// sentence. Fails before this batch on the vaguer `partialNote` text.
    @Test("A partial shelf with a known total reads as 'first N of M', not the vague note")
    func ownedSummaryUsesTotalRecordsWhenKnown() {
        let shelf = EditionShelf(
            edition: edition(.nationalDietLibrary), volumes: [volume(1, "2020-01-01")],
            isPartial: true, totalRecords: 84
        )
        let owned: Set<OwnedVolumeKey> = [OwnedVolumeKey(seriesID: 1, volume: shelf.volumes[0])]
        let line = OwnedSummary.line(for: shelf, owned: owned, seriesID: 1)
        #expect(line == "1 owned · first 1 of 84 on record")
    }

    /// The control: with no total known (Open Library's partial case today),
    /// the old vaguer note is still what shows — the fix must not invent a
    /// number nobody stated.
    @Test("Control: a partial shelf with no known total keeps the vague note")
    func ownedSummaryFallsBackWithNoTotal() {
        let shelf = EditionShelf(
            edition: edition(.openLibrary), volumes: [volume(1, "2020-01-01")], isPartial: true
        )
        let owned: Set<OwnedVolumeKey> = [OwnedVolumeKey(seriesID: 1, volume: shelf.volumes[0])]
        let line = OwnedSummary.line(for: shelf, owned: owned, seriesID: 1)
        #expect(line == "1 owned · \(OwnedSummary.partialNote)")
    }

    /// `EditionShelvesSection.creditLine` says the same thing `OwnedSummary`
    /// does, but before a single row is ticked — `OwnedSummary.line` is nil
    /// until then, which is the gap this half of P3 closes.
    @Test("The credit line reads as partial before any row is ticked")
    func creditLineIsPartialBeforeAnyTick() {
        let shelf = EditionShelf(
            edition: edition(.nationalDietLibrary), volumes: [volume(1, "2020-01-01")],
            isPartial: true, totalRecords: 84
        )
        #expect(EditionShelvesSection.creditLine(for: shelf).contains("first 1 of 84 on record"))
    }

    // MARK: - P4: an ANN spin-off is not a second "vol. 1"

    /// One Piece's recorded shape (`docs/sources/publishers.md`): a spin-off
    /// release sits beside the main run under the same `<manga>` id. Fails
    /// before this batch with `editions.count == 1` — both releases landed
    /// on one shelf as two "vol. 1"s.
    @Test("A spin-off release gets its own shelf, not a second vol. 1 on the main run's")
    func annSpinOffGetsItsOwnEdition() throws {
        let xml = """
        <ann><manga id="17164" name="One Piece">
          <release date="1997-07-22" href="https://www.animenewsnetwork.com/encyclopedia/releases.php?id=1" \
        ean="9781569319017">One Piece (GN 1)</release>
          <release date="2020-03-03" href="https://www.animenewsnetwork.com/encyclopedia/releases.php?id=2" \
        ean="9781974720798">One Piece: Ace's Story-The Manga (GN 1)</release>
        </manga></ann>
        """
        let entry = try #require(ANNEncyclopedia.parse(Data(xml.utf8)))
        let volumes = ANNEncyclopedia.volumes(in: entry, role: .english)
        #expect(volumes.count == 2)
        let editions = Set(volumes.map(\.edition))
        #expect(editions.count == 2, "The main run and the spin-off must not share an edition")
        let mainRun = try #require(volumes.first { $0.isbn13 == "9781569319017" })
        #expect(mainRun.edition.editionTitle == "One Piece")
        let spinOff = try #require(volumes.first { $0.isbn13 == "9781974720798" })
        #expect(spinOff.edition.editionTitle == "One Piece · One Piece: Ace's Story-The Manga")
    }

    /// The control: the recorded happy-path fixture has no spin-off, so it
    /// must still read as one edition — the fix must not split a series
    /// that has no side story into shelves of its own for no reason.
    @Test("Control: a series with no spin-off release still gets one edition")
    func noSpinOffStaysOneEdition() throws {
        let data = try Fixture.data("ann-delicious-in-dungeon-17164", extension: "xml")
        let entry = try #require(ANNEncyclopedia.parse(data))
        let volumes = ANNEncyclopedia.volumes(in: entry, role: .english)
        #expect(Set(volumes.map(\.edition)).count == 1)
    }

    // MARK: - P5: publisher inheritance is NDL-only, keyed by language too

    private func bookEdition(
        isbn: String, publisher: String?, language: String?, source: BookEdition.Source,
        workTitle: String? = nil
    ) -> BookEdition {
        BookEdition(
            id: "\(source)-\(isbn)", title: "Mock \(isbn)", isbn13: isbn, publisher: publisher,
            language: language, published: nil, coverID: nil, volume: "1", source: source,
            format: .comic, formatEvidence: .unstated, workTitle: workTitle
        )
    }

    /// The Solo Leveling shape this bug was found on: an Open Library row in
    /// the original language, no publisher, beside English rows that all
    /// name one. Fails before this batch with the OL row inheriting "Yen
    /// Press" — an English publisher on a shelf otherwise headed "Japanese".
    @Test("An Open Library row with no publisher does not inherit one from an English sibling")
    func openLibraryRowsDoNotInheritPublisher() {
        let rows = [
            bookEdition(isbn: "1", publisher: "Yen Press", language: "eng", source: .openLibrary),
            bookEdition(isbn: "2", publisher: nil, language: "jpn", source: .openLibrary)
        ]
        let result = BookEditionShelf.withInheritedPublishers(rows)
        #expect(result.first { $0.isbn13 == "2" }?.publisher == nil)
    }

    /// The case this rule exists for: NDL's own 近刊 record with no
    /// publisher yet, beside the rest of the run stating one.
    @Test("An NDL row with no publisher still inherits one when every sibling of the work agrees")
    func ndlRowsStillInheritPublisher() {
        let rows = [
            bookEdition(isbn: "1", publisher: "KADOKAWA", language: "jpn", source: .nationalDietLibrary),
            bookEdition(isbn: "2", publisher: nil, language: "jpn", source: .nationalDietLibrary)
        ]
        let result = BookEditionShelf.withInheritedPublishers(rows)
        #expect(result.first { $0.isbn13 == "2" }?.publisher == "KADOKAWA")
    }
}

/// Part two of the same batch — see `EditionsFixTests`'s doc comment.
@Suite("Editions fix batch, part two")
struct EditionsFixTestsPartTwo {
    private func edition(_ catalogue: VolumeCatalogue = .animeNewsNetwork) -> VolumeEdition {
        fixEdition(catalogue)
    }

    // MARK: - P6: Open Library's isPartial is a real answer

    private func makeOpenLibraryClient(clock: TestClock) -> OpenLibraryEditions {
        OpenLibraryEditions(
            session: URLProtocolStub.makeSession(), clock: clock,
            gate: HostRateGate(minimumInterval: 0),
            cacheDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("ol-fix-tests-\(UUID().uuidString)", isDirectory: true)
        )
    }

    /// The recorded Solo Leveling fixture states `"size": 3` and returns all
    /// three entries — a complete page. Fails before this batch trivially
    /// (`isPartial` was hard-coded `false`, so this always passed); paired
    /// with the next test as the control that proves the field is actually
    /// read.
    @Test("A complete Open Library page is not partial")
    func openLibraryCompletePageIsNotPartial() async throws {
        let isbn = try Fixture.data("openlibrary-isbn-9781975319434")
        let editions = try Fixture.data("openlibrary-editions-OL19921538W")
        URLProtocolStub.setHandler { request in
            let path = request.url?.path ?? ""
            if path.hasPrefix("/isbn/") { return .respond(.init(body: isbn)) }
            if path.hasSuffix("/editions.json") { return .respond(.init(body: editions)) }
            return .respond(.init(statusCode: 404, body: Data()))
        }
        defer { URLProtocolStub.reset() }
        let result = try await makeOpenLibraryClient(clock: TestClock())
            .editionsWithFetchedAt(anchorISBN: "9781975319434")
        #expect(!result.isPartial)
    }

    /// A minimal, hand-built page (not a live capture — Open Library was not
    /// asked for a work with more than 50 editions during this review) that
    /// states more editions than it returned. Fails before this batch with
    /// `isPartial == false` — the field existed nowhere in `EditionDocument`,
    /// and the caller passed a hard-coded `false` regardless of what the
    /// wire said.
    @Test("A page whose size exceeds its entry count reads as partial")
    func openLibraryShortPageIsPartial() async throws {
        let isbn = try Fixture.data("openlibrary-isbn-9781975319434")
        let short = Data("""
        {"size": 60, "entries": [
          {"key": "/books/OL1M", "title": "Mock, Vol. 1",
           "isbn_13": ["9780000000001"], "publishers": ["Yen Press"],
           "languages": [{"key": "/languages/eng"}], "publish_date": "2021-01-01"}
        ]}
        """.utf8)
        URLProtocolStub.setHandler { request in
            let path = request.url?.path ?? ""
            if path.hasPrefix("/isbn/") { return .respond(.init(body: isbn)) }
            if path.hasSuffix("/editions.json") { return .respond(.init(body: short)) }
            return .respond(.init(statusCode: 404, body: Data()))
        }
        defer { URLProtocolStub.reset() }
        let result = try await makeOpenLibraryClient(clock: TestClock())
            .editionsWithFetchedAt(anchorISBN: "9781975319434")
        #expect(result.isPartial)
    }

    // MARK: - P13: a cache hit says when it was really fetched

    /// Fails before this batch with both readings equal to the *second*
    /// call's `Date()` — `openLibraryEditionsAnswer` stamped every answer
    /// `Date()` at the call site, cache hit or not.
    @Test("A cache hit's fetchedAt is the original fetch time, not the second call's")
    func openLibraryCacheHitKeepsOriginalFetchedAt() async throws {
        let isbn = try Fixture.data("openlibrary-isbn-9781975319434")
        let editions = try Fixture.data("openlibrary-editions-OL19921538W")
        URLProtocolStub.setHandler { request in
            let path = request.url?.path ?? ""
            if path.hasPrefix("/isbn/") { return .respond(.init(body: isbn)) }
            if path.hasSuffix("/editions.json") { return .respond(.init(body: editions)) }
            return .respond(.init(statusCode: 404, body: Data()))
        }
        defer { URLProtocolStub.reset() }
        let clock = TestClock()
        let client = makeOpenLibraryClient(clock: clock)

        let first = try await client.editionsWithFetchedAt(anchorISBN: "9781975319434")
        clock.advance(by: 3600)
        let second = try await client.editionsWithFetchedAt(anchorISBN: "9781975319434")

        #expect(second.fetchedAt == first.fetchedAt)
        #expect(second.fetchedAt != clock.now)
    }

    // MARK: - P9: an ANN "(Novel n)" release is prose, not print

    @Test("An ANN release marked Novel is filed as .other, not .print")
    func annNovelReleaseIsOther() {
        let (format, number) = ANNEncyclopedia.readMarker(in: "Mock Series (Novel 3)")
        #expect(format == .other)
        #expect(number == 3)
    }

    /// The control: the ordinary print marker is unaffected.
    @Test("Control: an ordinary GN release still prints")
    func annGNReleaseIsPrint() {
        let (format, _) = ANNEncyclopedia.readMarker(in: "Mock Series (GN 3)")
        #expect(format == .print)
    }

    // MARK: - P16: Google's isNovel agrees with Apple's, including the Wikidata fallback

    /// A series with no stated `type` used to always read as a comic on
    /// Google's side, ignoring the Wikidata fallback Apple's shelf already
    /// consults. Fails before this batch with `false`.
    @Test("A nil-type series takes Wikidata's word for prose, matching Apple's rule exactly")
    func googleIsNovelMatchesAppleForNilType() {
        let series = SeriesFactory.make(id: 1, title: "Mock Series", type: nil)
        #expect(AppleBooksClient.isNovel(series: series, format: .novel))
        #expect(!AppleBooksClient.isNovel(series: series, format: .manga))
    }

    // MARK: - P18: a MangaBaka ISBN-10 matches a catalogue's ISBN-13

    @Test("ISBN-10 to ISBN-13 conversion matches the standard's own worked example")
    func isbn10ToIsbn13() {
        // 0-306-40615-2 → 978-0-306-40615-7, the example ISO 2108 itself uses.
        #expect(VolumeEditions.isbn13(fromISBN10: "0306406152") == "9780306406157")
    }

    @Test("A malformed value is left alone rather than 'converted' into a wrong 13-digit string")
    func isbn10ConversionRejectsMalformed() {
        #expect(VolumeEditions.isbn13(fromISBN10: "12345") == nil)
        #expect(VolumeEditions.isbn13(fromISBN10: "abcdefghij") == nil)
    }

    /// The suppression this was for: a MangaBaka work dated with an ISBN-10
    /// must suppress the same book's ISBN-13 row from ANN or a catalogue.
    /// Fails before this batch with the ANN row still on screen beside
    /// MangaBaka's own.
    @Test("A dated MangaBaka ISBN-10 suppresses the same book's ISBN-13 row from a catalogue")
    func datedISBN10SuppressesCatalogueRow() {
        let series = SeriesFactory.make(id: 1, title: "Mock Series", type: "manga")
        let works: [SeriesWork.Volume] = [
            SeriesWork.Volume(
                number: "1",
                editions: [
                    SeriesWork(
                        id: "w-1", sequenceString: "1", sequenceNumeric: 1, subTitle: nil,
                        releaseDate: "2003-01-01", pages: nil, prices: nil,
                        identifiers: [SeriesWork.Identifier(id: "0306406152", name: "isbn")],
                        links: nil, images: nil
                    )
                ]
            )
        ]
        let annRow = EditionVolume(
            number: 1, title: "Mock (GN 1)", releaseDate: PartialDate.parse("2003-01-01"),
            isbn13: "9780306406157", format: .print, edition: edition(),
            sourceLink: URL(string: "https://www.animenewsnetwork.com/encyclopedia/manga.php?id=1")
        )
        let ann = Fetched.loaded(
            ANNVolumes(volumes: [annRow], isCatalogued: true), fetchedAt: .now, isPartial: false
        )
        let result = VolumeEditions.merge(ann: ann, works: works, for: series)
        #expect(
            result.shelves.flatMap(\.volumes).isEmpty,
            "The ISBN-13 row must be suppressed as already shown"
        )
    }

    // MARK: - P19: a second <manga> block does not contribute releases

    /// Not reachable through `ANNClient` today — it only ever asks by
    /// numeric id, which answers one `<manga>` — but the parser must not
    /// silently mix two series' releases if a future caller adds a name
    /// lookup. Fails before this batch with `releases.count == 2`.
    @Test("Only the first <manga> block's releases are kept")
    func onlyFirstMangaReleasesAreKept() throws {
        let link1 = "https://www.animenewsnetwork.com/encyclopedia/releases.php?id=1"
        let link2 = "https://www.animenewsnetwork.com/encyclopedia/releases.php?id=2"
        let xml = """
        <ann>
          <manga id="1" name="First Series">
            <release date="2020-01-01" href="\(link1)" ean="9780000000001">First Series (GN 1)</release>
          </manga>
          <manga id="2" name="Second Series">
            <release date="2020-01-01" href="\(link2)" ean="9780000000002">Second Series (GN 1)</release>
          </manga>
        </ann>
        """
        let entry = try #require(ANNEncyclopedia.parse(Data(xml.utf8)))
        #expect(entry.id == 1)
        #expect(entry.releases.count == 1)
        #expect(entry.releases.first?.ean == "9780000000001")
    }

    // MARK: - P8: hand-typed Apple Books title shapes (no live fixture — see report)

    /// **Hand-typed, not captured from a live iTunes Search response.** The
    /// perf review's P8 records these as real shapes seen in other
    /// storefronts (French, German, J-Novel Club multi-part, decimal
    /// volumes) with no saved fixture to test against reliably — this suite
    /// records today's actual behaviour (all rejected) so a future fixture
    /// capture has a documented baseline to compare against, not a claim
    /// that these are the *right* answers.
    @Test("Hand-typed: shapes P8 names as real but unrecognised by the current pattern")
    func handTypedUnrecognisedShapes() {
        // A decimal volume ("Vol. 8.5") — `\d+` has no fractional part.
        #expect(AppleBooksMatch.split("Mock Series, Vol. 8.5 (comic)") == nil)
        // A roman-numeral volume.
        #expect(AppleBooksMatch.split("Mock Series, Vol. II (comic)") == nil)
        // J-Novel Club's multi-part light novels: the marker eats "Part 1"
        // into the title rather than a separate field.
        let multiPart = AppleBooksMatch.split("Mock Series: Part 1, Vol. 1 (comic)")
        #expect(multiPart?.title == "Mock Series: Part 1")
        // French "Tome"/"T01" and German "Band" are not in the marker
        // alternation at all.
        #expect(AppleBooksMatch.split("Mock Series, Tome 1") == nil)
        #expect(AppleBooksMatch.split("Mock Series T01") == nil)
        #expect(AppleBooksMatch.split("Mock Series, Band 1") == nil)
        // Japanese-store volume words other than Shueisha's/Kodansha's shape
        // (`bare` numbering), tried against `.marker` as the home-store path
        // would.
        #expect(AppleBooksMatch.split("Mock Series 1巻") == nil)
        #expect(AppleBooksMatch.split("Mock Series 第1巻") == nil)
        // A light novel tagged "LN" rather than a word `isNovelTag` knows —
        // it still parses (unlike the shapes above), but the tag itself
        // reads as not-a-novel, so it would land on the comic shelf.
        let lnTag = AppleBooksMatch.split("Mock Series, Vol. 1 (LN)")
        #expect(lnTag?.tag == "ln")
        #expect(!AppleBooksMatch.isNovelTag("ln"))
    }
}
