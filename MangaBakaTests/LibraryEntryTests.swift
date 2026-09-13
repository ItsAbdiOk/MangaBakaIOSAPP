import Foundation
import Testing
@testable import MangaBaka

/// `LibraryEntry.State` decoding and the local-patch helper `apply(_:to:)`
/// relies on. New file: neither had a dedicated suite before this batch.
@Suite("Library entry")
struct LibraryEntryTests {
    private func json(state: String) -> Data {
        Data("""
        {"id":1,"series_id":1,"state":"\(state)"}
        """.utf8)
    }

    /// Gap 4: an unrecognised state used to throw out of the synthesized
    /// `Decodable` conformance for the whole entry, and that failure
    /// propagated to the array decode of an entire `/v1/my/library` page —
    /// one odd row stopped the whole library walk with a spinner nothing
    /// ever cleared.
    ///
    /// Falls back to `.considering` rather than an `.other(String)` case:
    /// `LibraryEntry.State` is switched on exhaustively in
    /// `TasteLedger.swift` and `LibraryShape.swift`, both outside this
    /// batch's files, and an associated-value case would have needed a
    /// matching edit in each to keep compiling. This is a deliberate
    /// deviation from the summary's literal suggestion, not an oversight —
    /// see the doc comment on `LibraryEntry.State.init(from:)`.
    ///
    /// Expected to fail before the fix with: a thrown `DecodingError` from
    /// `Fixture.decoder().decode(LibraryEntry.self, ...)`, not a value.
    @Test("An unrecognised state decodes rather than throwing for the whole entry")
    func unknownStateDoesNotThrow() throws {
        let entry = try Fixture.decoder().decode(LibraryEntry.self, from: json(state: "zzz"))
        #expect(entry.state == .considering)
    }

    /// The control: an ordinary, recognised state still decodes as itself.
    @Test("A recognised state decodes as itself")
    func knownStateDecodes() throws {
        let entry = try Fixture.decoder().decode(LibraryEntry.self, from: json(state: "dropped"))
        #expect(entry.state == .dropped)
    }

    /// One bad row in a page must not sink the other rows around it — the
    /// actual shape of gap 4 ("throws for the whole page").
    @Test("One row with an unrecognised state does not fail the page it arrived on")
    func unknownStateInAPageDoesNotFailTheBatch() throws {
        let page = try Fixture.decoder().decode([LibraryEntry].self, from: Data("""
        [{"id":1,"series_id":1,"state":"reading"},
         {"id":2,"series_id":2,"state":"a_future_state_this_build_does_not_know"},
         {"id":3,"series_id":3,"state":"dropped"}]
        """.utf8))
        #expect(page.map(\.state) == [.reading, .considering, .dropped])
    }

    private func entry(
        state: LibraryEntry.State = .reading,
        chapter: Double? = 10,
        rating: Double? = nil,
        note: String? = nil
    ) -> LibraryEntry {
        LibraryEntry(
            id: 1, seriesId: 1, state: state, progressChapter: chapter,
            progressVolume: nil, rating: rating, note: note, startDate: nil,
            finishDate: nil, numberOfRereads: nil, priority: nil,
            isPrivate: nil, readLink: nil, series: nil
        )
    }

    // MARK: - applying(_:)

    @Test("An untouched field in the change set survives applying")
    func untouchedFieldsSurvive() {
        var change = LibraryChange()
        change.rating = .some(80)
        let patched = entry(chapter: 12).applying(change)
        #expect(patched.progressChapter == 12, "not touched by the change, must not move")
        #expect(patched.rating == 80)
    }

    @Test("An explicit clear in the change set removes the value")
    func explicitClearRemovesValue() {
        var change = LibraryChange()
        change.note = .some(nil)
        let patched = entry(note: "gave up").applying(change)
        #expect(patched.note == nil)
    }

    @Test("applying changes state and keeps identity fields untouched")
    func stateChangeKeepsIdentity() {
        var change = LibraryChange()
        change.state = .completed
        let patched = entry(state: .reading).applying(change)
        #expect(patched.state == .completed)
        #expect(patched.id == 1)
        #expect(patched.seriesId == 1)
    }
}
