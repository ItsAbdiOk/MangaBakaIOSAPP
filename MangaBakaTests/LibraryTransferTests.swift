import Foundation
import Testing
@testable import MangaBaka

/// Export/import of the reader's own library — a safety net that has to keep
/// working even when MangaBaka does not: a file on the reader's own phone,
/// round-tripped without a server in the loop.
@Suite("Library export")
struct LibraryExportTests {
    private func makeEntry(
        id: Int = 1,
        seriesId: Int = 87872,
        state: LibraryEntry.State = .reading,
        progressChapter: Double? = 17,
        progressVolume: Double? = nil,
        rating: Double? = 80,
        note: String? = nil,
        startDate: Date? = nil,
        finishDate: Date? = nil,
        numberOfRereads: Int? = 1,
        priority: Int? = 5,
        isPrivate: Bool? = true,
        title: String? = "Breaking A Rock"
    ) -> LibraryEntry {
        let series = title.map {
            Series(
                id: seriesId, state: "active", mergedWith: nil,
                titles: [SeriesTitle(language: "en", traits: ["official"], title: $0, isPrimary: true)],
                cover: .empty, description: nil, authors: nil, artists: nil, status: nil,
                rating: nil, type: nil, contentRating: nil, totalChapters: nil, finalVolume: nil,
                publishers: nil, anime: nil, source: nil
            )
        }
        return LibraryEntry(
            id: id, seriesId: seriesId, state: state, progressChapter: progressChapter,
            progressVolume: progressVolume, rating: rating, note: note, startDate: startDate,
            finishDate: finishDate, numberOfRereads: numberOfRereads, priority: priority,
            isPrivate: isPrivate, readLink: nil, series: series
        )
    }

    @Test("A JSON export round-trips back to the same entries")
    func jsonRoundTrip() throws {
        let exportedAt = Date(timeIntervalSince1970: 1_757_000_000)
        let entries = [
            makeEntry(),
            makeEntry(
                id: 2, seriesId: 42, state: .planToRead,
                progressChapter: nil, rating: nil, isPrivate: nil, title: nil
            )
        ]
        let data = LibraryExport.json(entries, exportedAt: exportedAt)

        let envelope = try LibraryExport.dateDecoder.decode(LibraryExport.Envelope.self, from: data)
        #expect(envelope.format == "mangabaka-library")
        #expect(envelope.version == 1)
        #expect(envelope.exportedAt == exportedAt)
        #expect(envelope.entries.count == 2)
        #expect(envelope.entries[0].seriesId == 87872)
        #expect(envelope.entries[0].title == "Breaking A Rock")
        #expect(envelope.entries[0].state == .reading)
        #expect(envelope.entries[0].progressChapter == 17)
        #expect(envelope.entries[0].rating == 80)
        #expect(envelope.entries[0].isPrivate == true)
        #expect(envelope.entries[1].seriesId == 42)
        #expect(envelope.entries[1].title == nil)
    }

    @Test("JSON export is deterministic: the same entries produce the same bytes")
    func jsonIsDeterministic() {
        let exportedAt = Date(timeIntervalSince1970: 1_757_000_000)
        let entries = [makeEntry()]
        let first = LibraryExport.json(entries, exportedAt: exportedAt)
        let second = LibraryExport.json(entries, exportedAt: exportedAt)
        #expect(first == second)
    }

    @Test("CSV export quotes a note containing a comma, a quote and a newline, and it round-trips")
    func csvQuotingRoundTrips() {
        let entry = makeEntry(note: "Great, \"so far\"\nread again")
        let data = LibraryExport.csv([entry])
        let text = String(bytes: data, encoding: .utf8) ?? ""

        // RFC 4180: the embedded quote is doubled and the whole field is wrapped.
        #expect(text.contains("\"Great, \"\"so far\"\"\nread again\""))

        guard case let .success(parsed) = LibraryImport.parse(data) else {
            Issue.record("CSV with quoting failed to parse back")
            return
        }
        #expect(parsed.count == 1)
        #expect(parsed[0].note == "Great, \"so far\"\nread again")
        #expect(parsed[0].seriesId == 87872)
        #expect(parsed[0].state == .reading)
        #expect(parsed[0].progressChapter == 17)
    }

    /// Work-list 28: `LibraryExport.defused` puts an apostrophe in front of a
    /// title or note beginning `=`, `+`, `-` or `@` so a spreadsheet does not
    /// run it as a formula, and nothing ever took it back off.
    ///
    /// EXPECTED TO FAIL ON THE OLD CODE with: `parsed[0].note` reading
    /// **"'=SUM(A1:A9)"** instead of "=SUM(A1:A9)" for each of the four
    /// prefixes, and `title` the same. That is not cosmetic — `LibraryImport
    /// .apply` sends the note back to the server, so exporting and
    /// re-importing spent a real PATCH writing the apostrophe into the
    /// reader's account, and doing it twice wrote two.
    @Test(
        "A defused note survives the round trip without its apostrophe",
        arguments: ["=SUM(A1:A9)", "+1", "-1", "@import"]
    )
    func defusedFieldsRoundTrip(dangerous: String) {
        let entry = makeEntry(note: dangerous)
        let data = LibraryExport.csv([entry])
        let text = String(bytes: data, encoding: .utf8) ?? ""
        #expect(text.contains("'" + dangerous), "the export still defuses it")

        guard case let .success(parsed) = LibraryImport.parse(data) else {
            Issue.record("defused CSV failed to parse back")
            return
        }
        #expect(parsed.count == 1)
        #expect(parsed[0].note == dangerous)
    }

    /// The control: an apostrophe the reader actually typed is theirs and is
    /// not stripped. Without this, "strip a leading apostrophe" would pass the
    /// test above while quietly editing everybody's notes.
    @Test("An apostrophe the reader typed themselves survives the round trip")
    func aGenuineApostropheIsKept() {
        let entry = makeEntry(note: "'tis the season")
        guard case let .success(parsed) = LibraryImport.parse(LibraryExport.csv([entry])) else {
            Issue.record("CSV failed to parse back")
            return
        }
        #expect(parsed[0].note == "'tis the season")
    }

    @Test("A CSV with columns in a different order than the header still parses")
    func csvReorderedColumnsParse() {
        let csv = "state,seriesId,rating\r\nreading,555,60\r\n"
        guard case let .success(parsed) = LibraryImport.parse(Data(csv.utf8)) else {
            Issue.record("Reordered CSV failed to parse")
            return
        }
        #expect(parsed.count == 1)
        #expect(parsed[0].seriesId == 555)
        #expect(parsed[0].state == .reading)
        #expect(parsed[0].rating == 60)
        #expect(parsed[0].note == nil, "a column the file never mentioned must not appear")
    }

    @Test("A whole chapter renders without a trailing .0")
    func csvWholeChapterFormatting() {
        let data = LibraryExport.csv([makeEntry(progressChapter: 12)])
        let text = String(bytes: data, encoding: .utf8) ?? ""
        #expect(text.contains(",12,"))
        #expect(!text.contains(",12.0,"))
    }
}

@Suite("Library import parsing")
struct LibraryImportParsingTests {
    @Test("A MyAnimeList export parses every <manga> entry it names")
    func malXMLParsesCount() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8" ?>
        <myanimelist>
          <manga>
            <manga_mangadb_id>121</manga_mangadb_id>
            <manga_title>One Piece</manga_title>
            <my_status>Reading</my_status>
            <my_read_chapters>1050</my_read_chapters>
            <my_score>9</my_score>
          </manga>
          <manga>
            <manga_mangadb_id>2</manga_mangadb_id>
            <manga_title>Berserk</manga_title>
            <my_status>On-Hold</my_status>
            <my_read_chapters>0</my_read_chapters>
            <my_score>0</my_score>
          </manga>
        </myanimelist>
        """
        guard case let .success(parsed) = LibraryImport.parse(Data(xml.utf8)) else {
            Issue.record("MAL XML failed to parse")
            return
        }
        #expect(parsed.count == 2)
        #expect(parsed[0].malId == 121)
        #expect(parsed[0].seriesId == nil, "no MAL -> MangaBaka lookup; see LibraryImport.parseMALXML")
        #expect(parsed[0].state == .reading)
        #expect(parsed[0].progressChapter == 1050)
        #expect(parsed[0].rating == 90)
        #expect(parsed[1].state == .paused)
        #expect(parsed[1].progressChapter == nil, "0 chapters read is 'no progress', not literally zero")
        #expect(parsed[1].rating == nil, "an unrated MAL entry (score 0) must not become rating 0")
    }

    @Test("Garbage input is reported as an invalid format, not a crash")
    func invalidFormatIsReported() {
        guard case let .failure(error) = LibraryImport.parse(Data("not a real file".utf8)) else {
            Issue.record("expected a failure")
            return
        }
        #expect(error == .invalidFormat)
    }

    @Test("Empty input is reported as empty")
    func emptyInputIsReported() {
        guard case let .failure(error) = LibraryImport.parse(Data()) else {
            Issue.record("expected a failure")
            return
        }
        #expect(error == .empty)
    }
}

@Suite("Library import apply")
struct LibraryImportApplyTests {
    private final class StubLibrary: LibraryProviding, @unchecked Sendable {
        private(set) var added: [(seriesId: Int, state: LibraryEntry.State)] = []
        private(set) var updated: [(seriesId: Int, change: LibraryChange)] = []
        var failingSeriesIDs: Set<Int> = []

        func recommendationStatus() async throws(APIError) -> RecommendationStatus {
            throw APIError.offline
        }
        func recommendations(limit: Int, page: Int, excluding: [Int]) async -> PersonalRecommendations {
            PersonalRecommendations()
        }
        func library(page: Int, limit: Int) async -> [LibraryEntry] { [] }
        func hiddenTagIDs() async -> Set<Int>? { [] }
        func topGenres() async -> [TopGenre]? { [] }

        func add(seriesId: Int, state: LibraryEntry.State) async throws(APIError) -> Bool {
            if failingSeriesIDs.contains(seriesId) { throw APIError.offline }
            added.append((seriesId, state))
            return true
        }

        func remove(seriesId: Int) async throws(APIError) {}

        func update(seriesId: Int, change: LibraryChange) async throws(APIError) {
            if failingSeriesIDs.contains(seriesId) { throw APIError.offline }
            updated.append((seriesId, change))
        }
    }

    private func existingEntry(
        seriesId: Int, state: LibraryEntry.State = .reading, chapter: Double? = nil
    ) -> LibraryEntry {
        LibraryEntry(
            id: seriesId, seriesId: seriesId, state: state, progressChapter: chapter,
            progressVolume: nil, rating: nil, note: nil, startDate: nil, finishDate: nil,
            numberOfRereads: nil, priority: nil, isPrivate: nil, readLink: nil, series: nil
        )
    }

    /// A row an import file would produce, with only the fields a test cares
    /// about spelled out.
    private func imported(
        seriesId: Int?, malId: Int? = nil, state: LibraryEntry.State = .reading,
        progressChapter: Double? = nil, rating: Double? = nil
    ) -> ImportedEntry {
        ImportedEntry(
            seriesId: seriesId, malId: malId, title: nil, state: state,
            progressChapter: progressChapter, progressVolume: nil, rating: rating,
            note: nil, isPrivate: nil
        )
    }

    @MainActor
    @Test("A series not already in the library is added")
    func addsNewEntries() async {
        let library = StubLibrary()
        let entry = imported(seriesId: 10, state: .planToRead)
        let report = await LibraryImport.apply([entry], to: library, existing: [])
        #expect(report.added == 1)
        #expect(report.updated == 0)
        #expect(library.added.map(\.seriesId) == [10])
    }

    @MainActor
    @Test("A series already in the library with a genuinely different field is updated")
    func updatesExistingEntries() async {
        let library = StubLibrary()
        let existing = [existingEntry(seriesId: 10, state: .reading, chapter: 5)]
        let entry = imported(seriesId: 10, progressChapter: 20)
        let report = await LibraryImport.apply([entry], to: library, existing: existing)
        #expect(report.updated == 1)
        #expect(report.added == 0)
        #expect(library.updated.first?.change.progressChapter == .some(20))
    }

    @Test("Progress is never moved backwards: a lower imported chapter is skipped")
    @MainActor
    func neverDowngradesProgress() async {
        let library = StubLibrary()
        let existing = [existingEntry(seriesId: 10, state: .reading, chapter: 50)]
        let entry = imported(seriesId: 10, progressChapter: 3)
        let report = await LibraryImport.apply([entry], to: library, existing: existing)
        #expect(report.skipped == 1)
        #expect(library.updated.isEmpty)
        #expect(library.added.isEmpty)
    }

    @MainActor
    @Test("A MAL row with no MangaBaka match is counted unresolved, not silently dropped")
    func unresolvedMALRowsAreCounted() async {
        let library = StubLibrary()
        let entry = imported(seriesId: nil, malId: 999)
        let report = await LibraryImport.apply([entry], to: library, existing: [])
        #expect(report.unresolved == 1)
        #expect(library.added.isEmpty)
    }

    @MainActor
    @Test("One entry failing does not stop the rest, and is counted rather than thrown")
    func failingEntryIsCountedNotFatal() async {
        let library = StubLibrary()
        library.failingSeriesIDs = [10]
        let entries = [imported(seriesId: 10), imported(seriesId: 11)]
        let report = await LibraryImport.apply(entries, to: library, existing: [])
        #expect(report.failures == 1)
        #expect(report.added == 1)
        #expect(library.added.map(\.seriesId) == [11])
    }

    @MainActor
    @Test("Cancelling mid-import stops before the remaining entries are sent")
    func cancellationStopsEarly() async {
        let library = StubLibrary()
        let progress = LibraryImportProgress()
        let entries = (1...5).map { imported(seriesId: $0) }

        // Cancel after the very first entry lands, rather than racing a timer
        // against `apply`'s own 0.5s spacing.
        let task = Task { @MainActor in
            while progress.completed < 1 { await Task.yield() }
            progress.cancel()
        }
        let report = await LibraryImport.apply(entries, to: library, existing: [], progress: progress)
        _ = await task.value

        #expect(library.added.count < 5, "cancellation should stop before every entry is sent")
        #expect(report.added == library.added.count)
    }
}

/// The section has to actually be on screen for any of the above to matter.
@Suite("Library transfer section is wired", .enabled(if: SourceTree.isAvailable))
struct LibraryTransferWiringTests {
    @Test("Settings carries the library transfer section")
    func settingsShowsIt() throws {
        let source = try SourceTree.read("MangaBaka/Features/Settings/SettingsView.swift")
        // Work-list 20: the section takes the session's shared library and a
        // cached read of it now, rather than defaulting to a private walk of
        // its own — so the pin is on the wired call, not the bare one.
        #expect(source.contains("LibraryTransferSection(library: library, loadExisting: loadExisting)"))
    }
}
