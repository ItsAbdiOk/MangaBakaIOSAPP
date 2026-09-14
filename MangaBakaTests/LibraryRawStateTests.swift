import Foundation
import Testing
@testable import MangaBaka

/// Work-list 90: a backup has to survive a state this build has never heard
/// of. `LibraryEntry.State` coerces an unrecognised value to `.considering`
/// on purpose — that is right for the screen and wrong for a file the reader
/// keeps in order to restore from it. These are the round trips, both
/// formats, with an ordinary state as the control.
///
/// A separate file rather than more of `LibraryTransferTests.swift`: that
/// file is 321 lines and SwiftLint's `file_length` is 400.
@Suite("Library raw state round trip")
struct LibraryRawStateTests {
    /// The state used throughout. Not in `LibraryEntry.State.allCases` — if
    /// it ever is, these tests stop testing anything, which is what the
    /// `allCases` check below is for.
    private static let unknownState = "hiatus_by_author"

    /// An entry as it arrives from `/v1/my/library`, decoded with the app's
    /// own decoder so the coercion under test is the real one.
    private func decodedEntry(state: String, seriesId: Int = 87872) throws -> LibraryEntry {
        try Fixture.decoder().decode(LibraryEntry.self, from: Data("""
        {"id":\(seriesId),"series_id":\(seriesId),"state":"\(state)","progress_chapter":17}
        """.utf8))
    }

    /// What the account already holds when the file is restored into it: the
    /// same series, in the state the coercion produced.
    private func existingConsidering(seriesId: Int = 87872) -> LibraryEntry {
        LibraryEntry(
            id: seriesId, seriesId: seriesId, state: .considering, progressChapter: 17,
            progressVolume: nil, rating: nil, note: nil, startDate: nil, finishDate: nil,
            numberOfRereads: nil, priority: nil, isPrivate: nil, readLink: nil, series: nil
        )
    }

    /// Records what `LibraryImport.apply` actually sent, including the raw
    /// state overload — the default forwarding version on `LibraryProviding`
    /// would drop it, which is the whole point of the assertion.
    private final class Recorder: LibraryProviding, @unchecked Sendable {
        private(set) var added: [(seriesId: Int, rawState: String?)] = []
        private(set) var updated: [(seriesId: Int, change: LibraryChange)] = []

        func recommendationStatus() async throws(APIError) -> RecommendationStatus {
            throw APIError.offline
        }
        func recommendations(limit: Int, page: Int, excluding: [Int]) async -> PersonalRecommendations {
            PersonalRecommendations()
        }
        func library(page: Int, limit: Int) async -> [LibraryEntry] { [] }
        func hiddenTagIDs() async -> Set<Int>? { [] }
        func topGenres() async -> [TopGenre]? { [] }
        func remove(seriesId: Int) async throws(APIError) {}

        func add(seriesId: Int, state: LibraryEntry.State) async throws(APIError) -> Bool {
            try await add(seriesId: seriesId, state: state, rawState: nil)
        }

        func add(
            seriesId: Int, state: LibraryEntry.State, rawState: String?
        ) async throws(APIError) -> Bool {
            added.append((seriesId, rawState))
            return true
        }

        func update(seriesId: Int, change: LibraryChange) async throws(APIError) {
            updated.append((seriesId, change))
        }
    }

    /// The guard on the two round trips below: if MangaBaka ever ships this
    /// state and the enum gains a case for it, these tests would pass for the
    /// wrong reason.
    @Test("The state under test really is one this build cannot name")
    func theUnknownStateIsUnknown() {
        #expect(LibraryEntry.State(rawValue: Self.unknownState) == nil)
    }

    /// Expected to fail before the import half landed with:
    /// `library.updated` empty, so `#expect(sent == "hiatus_by_author")`
    /// reports `nil == "hiatus_by_author"`. The JSON file already carried
    /// `rawState` (lane C did the export half), but `LibraryImport` decoded
    /// only `state`, which was `.considering` — equal to what the account
    /// already held, so `changeSet` produced an empty change and `apply`
    /// counted the row as skipped and sent nothing at all.
    @MainActor
    @Test("A state this build cannot name survives a JSON export and re-import")
    func jsonRoundTripKeepsAnUnknownState() async throws {
        let entry = try decodedEntry(state: Self.unknownState)
        #expect(entry.state == .considering, "the coercion under test")
        #expect(entry.exportedState == Self.unknownState, "the export half, lane C")

        let parsed = LibraryImport.parse(LibraryExport.json([entry]))
        guard case let .success(rows) = parsed, let row = rows.first else {
            Issue.record("the app's own JSON export must parse back")
            return
        }
        #expect(row.stateValue == Self.unknownState)

        let library = Recorder()
        let report = await LibraryImport.apply(
            rows, to: library, existing: [existingConsidering()]
        )
        #expect(report.updated == 1)
        let sent = library.updated.first?.change.body["state"] as? String
        #expect(sent == Self.unknownState)
    }

    /// The CSV twin. Expected to fail before the fix with a different
    /// symptom, which is why it is its own test: `parseCSV` bailed on any
    /// state `LibraryEntry.State(rawValue:)` did not recognise, so the row
    /// never existed and `parse` returned `.failure(.empty)` — the whole
    /// file, not just the field, was lost.
    @MainActor
    @Test("A state this build cannot name survives a CSV export and re-import")
    func csvRoundTripKeepsAnUnknownState() async throws {
        let entry = try decodedEntry(state: Self.unknownState)
        let parsed = LibraryImport.parse(LibraryExport.csv([entry]))
        guard case let .success(rows) = parsed, let row = rows.first else {
            Issue.record("a CSV row with an unknown state must parse, not drop the file")
            return
        }
        #expect(row.state == .considering)
        #expect(row.stateValue == Self.unknownState)

        let library = Recorder()
        let report = await LibraryImport.apply(
            rows, to: library, existing: [existingConsidering()]
        )
        #expect(report.updated == 1)
        #expect(library.updated.first?.change.body["state"] as? String == Self.unknownState)
    }

    /// A row for a series the account does not have yet goes out on the POST,
    /// not a follow-up PATCH — `changeSet` deliberately leaves `state` to
    /// `add`. Expected to fail before the fix with `rawState` nil, because
    /// `apply` called the enum-only `add`.
    @MainActor
    @Test("Adding a brand-new entry carries the unknown state on the POST")
    func addingNewEntryCarriesRawState() async throws {
        let entry = try decodedEntry(state: Self.unknownState)
        guard case let .success(rows) = LibraryImport.parse(LibraryExport.json([entry])) else {
            Issue.record("the app's own JSON export must parse back")
            return
        }

        let library = Recorder()
        let report = await LibraryImport.apply(rows, to: library, existing: [])
        #expect(report.added == 1)
        #expect(library.added.first?.rawState == Self.unknownState)
    }

    /// The control that reproduces a known answer: an ordinary state still
    /// round-trips, still writes no `rawState`, and re-importing a file that
    /// changes nothing still spends no write. Without this, a fix that put
    /// every entry's raw spelling on every PATCH would pass the three tests
    /// above.
    @MainActor
    @Test("A recognised state round-trips with no raw spelling and no write")
    func knownStateIsUnaffected() async throws {
        let entry = try decodedEntry(state: "dropped")
        #expect(entry.state == .dropped)

        guard case let .success(rows) = LibraryImport.parse(LibraryExport.json([entry])),
              let row = rows.first else {
            Issue.record("the app's own JSON export must parse back")
            return
        }
        #expect(row.rawState == nil)
        #expect(row.stateValue == "dropped")

        let existing = LibraryEntry(
            id: 87872, seriesId: 87872, state: .dropped, progressChapter: 17,
            progressVolume: nil, rating: nil, note: nil, startDate: nil, finishDate: nil,
            numberOfRereads: nil, priority: nil, isPrivate: nil, readLink: nil, series: nil
        )
        let library = Recorder()
        let report = await LibraryImport.apply(rows, to: library, existing: [existing])
        #expect(report.skipped == 1)
        #expect(library.updated.isEmpty)
        #expect(library.added.isEmpty)
    }

    /// Two different states this build cannot name both coerce to
    /// `.considering`, so an enum comparison in `changeSet` called them
    /// equal. Expected to fail before the fix with `library.updated` empty.
    @MainActor
    @Test("Two states this build cannot name are not treated as the same state")
    func twoUnknownStatesAreDistinguished() async throws {
        let entry = try decodedEntry(state: Self.unknownState)
        guard case let .success(rows) = LibraryImport.parse(LibraryExport.json([entry])) else {
            Issue.record("the app's own JSON export must parse back")
            return
        }
        let existing = try decodedEntry(state: "licensed_elsewhere")
        #expect(existing.state == .considering)

        let library = Recorder()
        let report = await LibraryImport.apply(rows, to: library, existing: [existing])
        #expect(report.updated == 1)
        #expect(library.updated.first?.change.body["state"] as? String == Self.unknownState)
    }
}
