import Foundation
import Testing
@testable import MangaBaka

/// Open Library's editions API, and the language filter in front of it.
///
/// Both fixtures were saved verbatim on 2026-09-14:
/// `openlibrary-isbn-9781975319434.json` from
/// `https://openlibrary.org/isbn/9781975319434.json` (which answers 302 to
/// `/books/OL32184952M.json`), and
/// `openlibrary-editions-OL19921538W.json` from
/// `https://openlibrary.org/works/OL19921538W/editions.json?limit=50`.
///
/// The Solo Leveling work is the useful one to record: three editions, one
/// English with a full date, one French with no `languages` array at all, and
/// one junk row whose publisher is the literal string "unknown".
@Suite("Open Library editions", .serialized)
struct OpenLibraryEditionsTests {
    private func makeClient(clock: TestClock = TestClock()) -> OpenLibraryEditions {
        OpenLibraryEditions(
            session: URLProtocolStub.makeSession(),
            clock: clock,
            // A gate of this suite's own, at zero: the two sequential requests
            // one lookup makes would otherwise sleep for a real 4 seconds
            // between them, and the shared `HostRateGate.openLibrary` would
            // also queue this suite behind whatever `OpenLibraryCoversTests`
            // left on it.
            gate: HostRateGate(minimumInterval: 0),
            cacheDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("ol-editions-tests-\(UUID().uuidString)", isDirectory: true)
        )
    }

    /// Serves the two recorded payloads by path, and fails anything else so a
    /// third request cannot pass unnoticed.
    private func stubLiveWork() throws {
        let isbn = try Fixture.data("openlibrary-isbn-9781975319434")
        let editions = try Fixture.data("openlibrary-editions-OL19921538W")
        URLProtocolStub.setHandler { request in
            let path = request.url?.path ?? ""
            if path.hasPrefix("/isbn/") { return .respond(.init(body: isbn)) }
            if path.hasSuffix("/editions.json") { return .respond(.init(body: editions)) }
            return .respond(.init(statusCode: 404, body: Data()))
        }
    }

    /// The path that matters: an ISBN this app already holds becomes a work
    /// id, and the work's editions come back. No title search anywhere.
    @Test("An anchor ISBN resolves to a work and its editions")
    func resolvesAnchorToEditions() async throws {
        try stubLiveWork()
        defer { URLProtocolStub.reset() }

        let answer = try await makeClient().editions(
            anchorISBN: "978-1-9753-1943-4", originalLanguage: "kor", knownFormat: .comic
        )
        #expect(answer != .notCatalogued)
        let rows = answer.rows

        let paths = URLProtocolStub.requests.compactMap(\.url?.path)
        #expect(paths == ["/isbn/9781975319434.json", "/works/OL19921538W/editions.json"])
        let row = try #require(rows.first)
        #expect(row.id == "/books/OL32184952M")
        #expect(row.isbn13 == "9781975319434")
        #expect(row.publisher == "Yen Press")
        #expect(row.language == "eng")
        #expect(row.published == PartialDate.parse("2021-03-02"))
        #expect(row.coverID == 10_839_422)
        // Inherited from the anchor, not read out of any field in the
        // response — neither endpoint returns a `subject` array at all.
        #expect(row.format == .comic)
        #expect(row.formatEvidence == .anchorISBN("9781975319434"))
    }

    /// The scope rule: English plus the series' own language, never a third.
    /// This work's other two rows are a French printing (KBOOKS,
    /// 9782382880296) and a junk row, and both arrive with an empty
    /// `languages` array — so "drop what we cannot place" and "drop French"
    /// are the same filter here.
    @Test("Only English and the original language survive")
    func filtersToShownLanguages() async throws {
        try stubLiveWork()
        defer { URLProtocolStub.reset() }

        let answer = try await makeClient().editions(anchorISBN: "9781975319434", originalLanguage: "kor")
        #expect(answer.rows.count == 1)
        #expect(!answer.rows.contains { $0.isbn13 == "9782382880296" })
    }

    /// The control for the filter above. Without it, "one row survives" would
    /// also pass if the decoder only ever produced one row.
    @Test("All three recorded editions decode before the filter runs")
    func decodesEveryEditionControl() async throws {
        try stubLiveWork()
        defer { URLProtocolStub.reset() }

        // `eng` is one of the two shown languages, so asking for the original
        // language to *be* the unstated one cannot widen the answer — the
        // rows the filter drops are dropped for having no language at all.
        let answer = try await makeClient().editions(anchorISBN: "9781975319434", originalLanguage: nil)
        #expect(answer.rows.count == 1)

        let editions = try Fixture.data("openlibrary-editions-OL19921538W")
        let document = try JSONSerialization.jsonObject(with: editions) as? [String: Any]
        #expect(document?["size"] as? Int == 3)
        #expect((document?["entries"] as? [Any])?.count == 3)
    }

    /// An ISBN Open Library has never seen is an answer, not a failure, and
    /// not an empty edition list either.
    @Test("An unknown ISBN is notCatalogued, not an empty list")
    func unknownISBNIsNotCatalogued() async throws {
        URLProtocolStub.setHandler { _ in .respond(.init(statusCode: 404, body: Data())) }
        defer { URLProtocolStub.reset() }

        let answer = try await makeClient().editions(anchorISBN: "9780000000000")
        #expect(answer == .notCatalogued)
    }

    /// A 500 is a failure and must not be remembered as "they have nothing".
    @Test("A server error throws rather than answering notCatalogued")
    func serverErrorThrows() async throws {
        URLProtocolStub.setHandler { _ in .respond(.init(statusCode: 500, body: Data())) }
        defer { URLProtocolStub.reset() }

        await #expect(throws: APIError.self) {
            _ = try await self.makeClient().editions(anchorISBN: "9781975319434")
        }
    }

    /// Second ask, no requests. The cache also remembers a `.notCatalogued`,
    /// which is the answer most worth not re-asking for.
    @Test("A cached answer costs no request")
    func cachesAnswers() async throws {
        try stubLiveWork()
        defer { URLProtocolStub.reset() }

        let client = makeClient()
        _ = try await client.editions(anchorISBN: "9781975319434", originalLanguage: "kor")
        let first = URLProtocolStub.requests.count
        _ = try await client.editions(anchorISBN: "9781975319434", originalLanguage: "kor")
        #expect(URLProtocolStub.requests.count == first)
    }

    /// Hyphens and lower-case `x` both appear in ISBNs in the wild; NDL sends
    /// hyphenated ones. Open Library's path accepts neither.
    @Test("An ISBN is normalised before it reaches the URL")
    func normalisesISBN() {
        #expect(OpenLibraryEditions.normalise("978-4-04-681635-1") == "9784046816351")
        #expect(OpenLibraryEditions.normalise("043942089x") == "043942089X")
    }

    /// The rule stated on its own, since the live fixture can only exercise
    /// the `eng`/unstated half of it.
    @Test("The language rule keeps English and the original, and nothing else")
    func languageRule() {
        func row(_ language: String?) -> BookEdition {
            BookEdition(
                id: "x", title: "t", isbn13: nil, publisher: nil, language: language,
                published: nil, coverID: nil, volume: nil, source: .openLibrary,
                format: .comic, formatEvidence: .unstated
            )
        }
        #expect(OpenLibraryEditions.isShown(row("eng"), originalLanguage: "jpn"))
        #expect(OpenLibraryEditions.isShown(row("jpn"), originalLanguage: "jpn"))
        #expect(!OpenLibraryEditions.isShown(row("fre"), originalLanguage: "jpn"))
        #expect(!OpenLibraryEditions.isShown(row("jpn"), originalLanguage: "kor"))
        #expect(!OpenLibraryEditions.isShown(row(nil), originalLanguage: "jpn"))
    }
}

/// The date parser, against every shape Open Library and NDL were measured to
/// send on 2026-09-14.
@Suite("Partial dates")
struct PartialDateTests {
    @Test("Each measured date keeps the precision the catalogue stated")
    func parsesMeasuredShapes() throws {
        #expect(PartialDate.parse("2021-03-02")?.precision == .day)
        #expect(PartialDate.parse("2026-09-18")?.precision == .day)
        #expect(PartialDate.parse("2024-04")?.precision == .month)
        #expect(PartialDate.parse("2012")?.precision == .year)
        #expect(PartialDate.parse("Apr 07, 2021")?.precision == .day)
        #expect(PartialDate.parse("November 12, 2003")?.precision == .day)
        #expect(PartialDate.parse("June 2003")?.precision == .month)
        // `Mar 24th 2003`, one of the eighteen One Piece rows.
        #expect(PartialDate.parse("Mar 24th 2003")?.precision == .day)
    }

    /// A year is not a day. This is the whole reason the type exists: a
    /// lenient `DateFormatter` reads `2012` as 1 January 2012 at day
    /// precision and a view then prints a publication day nobody asserted.
    @Test("A year-only date is not promoted to a day")
    func yearStaysAYear() throws {
        let year = try #require(PartialDate.parse("2012"))
        #expect(year.precision == .year)
        #expect(year != PartialDate.parse("2012-01-01"))
        #expect(year.date == PartialDate.parse("2012-01-01")?.date)
    }

    /// `23/04/2016` — a real row in the One Piece response. Ambiguous, so
    /// unknown rather than guessed.
    @Test("An unreadable date is unknown, not a default")
    func unreadableIsNil() {
        #expect(PartialDate.parse("23/04/2016") == nil)
        #expect(PartialDate.parse("") == nil)
        #expect(PartialDate.parse(nil) == nil)
        #expect(PartialDate.parse("n.d.") == nil)
        #expect(PartialDate.parse("2021-13-02") == nil)
    }

    /// Dates are UTC, so a Tokyo release date does not shift by a day for a
    /// reader in Los Angeles.
    @Test("Parsing does not depend on the device timezone")
    func timezoneIndependent() throws {
        let parsed = try #require(PartialDate.parse("2026-09-18"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        #expect(calendar.component(.day, from: parsed.date) == 18)
    }
}
