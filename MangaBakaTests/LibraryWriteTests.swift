import Foundation
import Testing
@testable import MangaBaka

/// Writing to the reader's real library.
///
/// This is the only thing the app does that changes someone's data on a server,
/// so the tests are about what gets SENT: a wrong body here silently overwrites
/// a real library, and nothing on screen would look wrong.
@Suite("Library writes", .serialized)
struct LibraryWriteTests {
    private let baseURL = URL(string: "https://api.example.invalid").unsafeTestURL

    private func makeService() -> LibraryService {
        LibraryService(client: APIClient(
            baseURL: baseURL,
            session: URLProtocolStub.makeSession(),
            tokenProvider: UnauthenticatedTokenProvider()
        ))
    }

    private func sentBody() throws -> [String: Any] {
        let request = try #require(URLProtocolStub.requests.first)
        // URLProtocol strips httpBody into a stream, so read whichever survived.
        let data = try #require(request.httpBody ?? request.httpBodyStream.map { stream in
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            let read = stream.read(&buffer, maxLength: buffer.count)
            return Data(buffer.prefix(max(read, 0)))
        })
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - What travels

    /// PATCH merges, so a field that is sent overwrites whatever is there. Only
    /// what the reader actually changed may travel.
    @Test("Only the fields that changed are sent")
    func sendsOnlyChanges() async throws {
        URLProtocolStub.setHandler { _ in .respond(.init(body: Data("{}".utf8))) }
        defer { URLProtocolStub.reset() }

        var change = LibraryChange()
        change.state = .completed
        try await makeService().update(seriesId: 42, change: change)

        let body = try sentBody()
        #expect(body["state"] as? String == "completed")
        #expect(body.count == 1, "sending an untouched field would overwrite it")
    }

    @Test("The request is a PATCH to the entry's own path")
    func usesPatch() async throws {
        URLProtocolStub.setHandler { _ in .respond(.init(body: Data("{}".utf8))) }
        defer { URLProtocolStub.reset() }

        var change = LibraryChange()
        change.progressChapter = .some(18)
        try await makeService().update(seriesId: 87_872, change: change)

        let request = try #require(URLProtocolStub.requests.first)
        #expect(request.httpMethod == "PATCH")
        #expect(request.url?.path == "/v1/my/library/87872")
    }

    /// The double-optional carries a distinction the API needs: absent means
    /// "leave it", null means "clear it". Collapsing them would make a note
    /// impossible to erase.
    @Test("Clearing a field sends an explicit null, not an omission")
    func clearingSendsNull() async throws {
        URLProtocolStub.setHandler { _ in .respond(.init(body: Data("{}".utf8))) }
        defer { URLProtocolStub.reset() }

        var change = LibraryChange()
        change.note = .some(nil)
        change.rating = .some(nil)
        try await makeService().update(seriesId: 1, change: change)

        let body = try sentBody()
        #expect(body["note"] is NSNull)
        #expect(body["rating"] is NSNull)
    }

    @Test("Leaving a field alone omits it entirely")
    func untouchedIsOmitted() {
        var change = LibraryChange()
        change.state = .paused
        #expect(change.body["note"] == nil)
        #expect(change.body["rating"] == nil)
        #expect(change.body["progress_chapter"] == nil)
    }

    /// Spending a write against someone's library to say nothing.
    @Test("An empty change makes no request at all")
    func emptyChangeMakesNoRequest() async throws {
        URLProtocolStub.setHandler { _ in .respond(.init(body: Data("{}".utf8))) }
        defer { URLProtocolStub.reset() }

        try await makeService().update(seriesId: 1, change: LibraryChange())
        #expect(URLProtocolStub.requests.isEmpty)
    }

    @Test("Every shelf state sends the API's own spelling")
    func statesUseAPISpelling() {
        var change = LibraryChange()
        change.state = .planToRead
        #expect(change.body["state"] as? String == "plan_to_read")
    }

    // MARK: - When it fails

    /// A rejected token cannot be fixed by retrying, and the message has to say
    /// where to go.
    @Test("A rejected credential points at Settings")
    func rejectedCredential() async {
        URLProtocolStub.setHandler { _ in .respond(.init(statusCode: 401, body: Data("{}".utf8))) }
        defer { URLProtocolStub.reset() }

        var change = LibraryChange()
        change.state = .dropped
        do {
            try await makeService().update(seriesId: 1, change: change)
            Issue.record("a 401 must not read as success")
        } catch {
            #expect(error.userFacingMessage.contains("Settings"))
        }
    }

    /// A failed write must throw. Swallowing it would leave the sheet closing
    /// as though the change had been saved.
    @Test("A server failure is not silently swallowed")
    func serverFailureThrows() async {
        URLProtocolStub.setHandler { _ in .respond(.init(statusCode: 500, body: Data("{}".utf8))) }
        defer { URLProtocolStub.reset() }

        var change = LibraryChange()
        change.rating = .some(80)
        await #expect(throws: APIError.self) {
            try await makeService().update(seriesId: 1, change: change)
        }
    }

    @Test("A rate limit is reported as one, so it can be retried later")
    func rateLimited() async {
        URLProtocolStub.setHandler { _ in
            .respond(.init(statusCode: 429, body: Data("{}".utf8), headers: ["Retry-After": "30"]))
        }
        defer { URLProtocolStub.reset() }

        var change = LibraryChange()
        change.state = .reading
        do {
            try await makeService().update(seriesId: 1, change: change)
            Issue.record("a 429 must not read as success")
        } catch {
            guard case .rateLimited = error else {
                Issue.record("expected a rate limit, got \(error)")
                return
            }
        }
    }
}

/// What the edit sheet decides to send.
///
/// The sheet holds every field, so the risk is that it sends all of them and
/// overwrites values the reader never touched.
@Suite("The edit sheet sends only what changed")
@MainActor
struct LibraryEditSheetTests {
    private func entry(
        state: LibraryEntry.State = .reading,
        chapter: Double? = 17,
        rating: Double? = 60,
        note: String? = "keep going",
        isPrivate: Bool = false
    ) throws -> LibraryEntry {
        try Fixture.decoder().decode(LibraryEntry.self, from: Data("""
        {"id":1,"series_id":1,"state":"\(state.rawValue)",
         "progress_chapter":\(chapter.map { String($0) } ?? "null"),
         "rating":\(rating.map { String($0) } ?? "null"),
         "note":\(note.map { "\"\($0)\"" } ?? "null"),
         "is_private":\(isPrivate)}
        """.utf8))
    }

    private func sheet(_ entry: LibraryEntry) -> LibraryEditSheet {
        LibraryEditSheet(entry: entry, series: SeriesFactory.make(id: 1)) { _ in nil }
    }

    /// Opened and closed without touching anything, the sheet must have nothing
    /// to say. Otherwise every open would rewrite the entry.
    @Test("An untouched sheet produces no change")
    func untouchedIsEmpty() throws {
        #expect(sheet(try entry()).changes.isEmpty)
    }

    /// An entry with nothing filled in is still untouched, and the nils must
    /// not read as "clear these".
    @Test("An empty entry left alone still produces no change")
    func emptyEntryUntouched() throws {
        let bare = try entry(chapter: nil, rating: nil, note: nil)
        #expect(sheet(bare).changes.isEmpty)
    }

    /// The rating is five steps in the UI and 0-100 on the wire.
    @Test("A rating converts between five steps and the API's scale")
    func ratingScale() throws {
        // 60 on the wire is three steps in the sheet; unchanged means unsent.
        #expect(sheet(try entry(rating: 60)).changes.rating == nil)
    }
}

/// Adding to the library, which is a different call from editing one.
///
/// Verified against the live API 2026-09-09 on a throwaway series that was then
/// deleted: POST creates and answers 201; POST on an existing entry answers 409
/// rather than duplicating; PATCH answers 404 when the entry does not exist, so
/// it cannot be used to add.
@Suite("Adding to the library", .serialized)
struct LibraryAddTests {
    private let baseURL = URL(string: "https://api.example.invalid").unsafeTestURL

    private func makeService() -> LibraryService {
        LibraryService(client: APIClient(
            baseURL: baseURL,
            session: URLProtocolStub.makeSession(),
            tokenProvider: UnauthenticatedTokenProvider()
        ))
    }

    @Test("Adding posts to the entry's path with the chosen shelf")
    func addsWithPost() async throws {
        URLProtocolStub.setHandler { _ in
            .respond(.init(statusCode: 201, body: Data(#"{"status":201}"#.utf8)))
        }
        defer { URLProtocolStub.reset() }

        let created = try await makeService().add(seriesId: 87_872, state: .planToRead)

        #expect(created)
        let request = try #require(URLProtocolStub.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/v1/my/library/87872")
    }

    /// "Already in your library" is an ordinary answer to "add this", not a
    /// failure to show the reader.
    @Test("A series already tracked is moved to the chosen shelf, not an error")
    func alreadyTrackedFallsBackToPatch() async throws {
        nonisolated(unsafe) var calls: [String] = []
        URLProtocolStub.setHandler { request in
            calls.append(request.httpMethod ?? "")
            return calls.count == 1
                ? .respond(.init(statusCode: 409, body: Data(#"{"status":409}"#.utf8)))
                : .respond(.init(statusCode: 200, body: Data("{}".utf8)))
        }
        defer { URLProtocolStub.reset() }

        let created = try await makeService().add(seriesId: 1, state: .reading)

        #expect(!created, "it was already there")
        #expect(calls == ["POST", "PATCH"], "a 409 should move the shelf, not give up")
    }

    /// A real failure still has to surface. Swallowing every non-201 would make
    /// "add" silently do nothing.
    @Test("A genuine failure to add is not treated as already-present")
    func realFailureThrows() async {
        URLProtocolStub.setHandler { _ in
            .respond(.init(statusCode: 500, body: Data("{}".utf8)))
        }
        defer { URLProtocolStub.reset() }

        await #expect(throws: APIError.self) {
            _ = try await makeService().add(seriesId: 1, state: .reading)
        }
    }

    @Test("Removing deletes the entry's own path")
    func removes() async throws {
        URLProtocolStub.setHandler { _ in .respond(.init(body: Data("{}".utf8))) }
        defer { URLProtocolStub.reset() }

        try await makeService().remove(seriesId: 4792)

        let request = try #require(URLProtocolStub.requests.first)
        #expect(request.httpMethod == "DELETE")
        #expect(request.url?.path == "/v1/my/library/4792")
        #expect(request.httpBody == nil, "a delete carries no body")
    }
}
