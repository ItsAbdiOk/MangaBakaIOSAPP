import Foundation
import Testing
@testable import MangaBaka

/// The library walk's partial-failure handling, local-patch API and
/// credential-vs-emptiness distinction — split out of `LibraryModelTests.swift`
/// purely to keep that file under SwiftLint's `type_body_length`/
/// `file_length`; there is no ownership split intended by the file boundary.
@Suite("Library walk: partial failure, patching, credentials")
@MainActor
struct LibraryModelPagingTests {
    private func entry(_ id: Int, _ state: LibraryEntry.State) throws -> LibraryEntry {
        try Fixture.decoder().decode(LibraryEntry.self, from: Data("""
        {"id":\(id),"series_id":\(id),"state":"\(state.rawValue)"}
        """.utf8))
    }

    // MARK: - Gap 83: partial walk failure

    /// Expected to fail before the fix with: `partialFailure == nil` — the
    /// model had no such property, and the reader saw either a spinner that
    /// never stopped (`LibraryView.swift:228-247`) or nothing distinguishing
    /// this from a clean page-cap stop.
    @Test("A walk that fails partway keeps its rows and names the failure")
    func partialWalkKeepsRowsAndNamesFailure() async throws {
        let library = PagedLibrary(total: 1_300, failOnPage: 3)
        let model = LibraryModel(library: library)
        await model.load()

        #expect(model.entries.count == 200, "two clean pages before the failure")
        #expect(!model.isComplete)
        #expect(model.partialFailure == .offline)
        #expect(model.screenState == .list, "rows exist, so this is not a blocking failure")
    }

    /// A walk that stops cleanly at the page cap is not a failure — nothing
    /// asked came back with an error — so `partialFailure` must stay nil even
    /// though `isComplete` is false.
    @Test("Hitting the page cap is incomplete but not a failure")
    func cappedWalkHasNoPartialFailure() async throws {
        let model = LibraryModel(library: PagedLibrary(total: 9_000))
        await model.load()
        #expect(!model.isComplete)
        #expect(model.partialFailure == nil)
    }

    /// A library past a thousand entries loads all of it (the ceiling this
    /// paging stub also proves for the two tests above).
    @Test("A library past a thousand entries loads all of it")
    func loadsPastTheOldCeiling() async throws {
        let model = LibraryModel(library: PagedLibrary(total: 1_204))
        await model.load()
        #expect(model.entries.count == 1_204)
        #expect(model.isComplete)
    }

    // MARK: - Gap 88/j (decision 5): local patch

    /// Expected to fail before the fix with: no such method existed on
    /// `LibraryModel` at all.
    @Test("apply(_:to:) patches one entry without a network call")
    func applyPatchesLocally() async throws {
        let library = PagedLibrary(total: 3)
        let model = LibraryModel(library: library)
        await model.load()
        let before = library.pageRequests

        var change = LibraryChange()
        change.rating = .some(80)
        await model.apply(change, to: 1)

        #expect(library.pageRequests == before, "no re-walk for a single patched field")
        #expect(model.entries.first { $0.seriesId == 1 }?.rating == 80)
    }

    // MARK: - Gap 117: reload after a completed walk

    /// Gap 117 is rated "low" confidence in the audit itself — "reasoned, not
    /// observed" — and a genuine interleaving needs the first walk's later
    /// pages to resolve after the second walk has already reset `entries`,
    /// which is a timing race no deterministic unit test can force without
    /// instrumenting `LibrarySnapshot` internals this batch does not own.
    /// This proves the ordinary, non-racing case still works after the
    /// generation counter was added — it does not prove the race itself is
    /// closed, only that the guard's bookkeeping does not break the common
    /// path. Recorded here rather than left unstated, per CLAUDE.md: a
    /// finding — or a proof — that does not fully reproduce is still worth
    /// saying so about, not silently upgrading into a stronger claim.
    @Test("A reload after a completed walk starts a clean, uninterleaved second walk")
    func reloadAfterCompletedWalkIsClean() async throws {
        let library = PagedLibrary(total: 250)
        let model = LibraryModel(library: library)
        await model.load()
        #expect(model.entries.count == 250)

        await model.reload()
        #expect(model.failure == nil)
        #expect(model.entries.count == 250, "the second walk's own, complete result")
        #expect(Set(model.entries.map(\.seriesId)).count == 250, "no duplicated rows from either walk")
    }

    // MARK: - Gap 84/85/89 (f): credentials vs. emptiness

    /// "Add a MangaBaka token" is only ever true when there genuinely is no
    /// credential — never inferred from what a walk happened to return.
    @Test("No credential reads as no account, regardless of what the library returns")
    func noCredentialIsNoAccount() async throws {
        let model = LibraryModel(library: PagedLibrary(total: 0), hasCredentials: { false })
        await model.load()
        #expect(model.screenState == .noAccount)
    }

    /// The header and the body of one screen, disagreeing.
    ///
    /// Reproduced on the simulator 2026-09-14 and again two seconds later,
    /// pixel-identical: "945 series · 429 dropped · 425 rated" above
    /// "No library yet — Add a MangaBaka token in Settings", with Settings
    /// showing "No account". `LibrarySnapshot` refusing to serve a signed-out
    /// reader the previous account's cache is the fix for how rows got into
    /// `entries`; this is the fix for the header being free to describe them
    /// at all. Both halves of the screen are decided by one `screenState`
    /// now, so no future source of rows can put the contradiction back.
    ///
    /// Constructed the way the walk found it: rows present, credential
    /// absent. `subtitle` is deliberately still the count — nothing else on
    /// the screen is wrong about the rows it has — but it is not what the
    /// header renders.
    @Test("The header cannot describe a library the body says is not there")
    func headerNeverContradictsTheEmptyState() async throws {
        let model = LibraryModel(library: PagedLibrary(total: 945), hasCredentials: { false })
        await model.load()

        #expect(model.screenState == .noAccount, "the body says no account, and it is right")
        #expect(
            !model.headerSubtitle.contains("945"),
            "the header claimed a 945-series library above 'No library yet'"
        )
        #expect(!model.headerSubtitle.contains("rated"))
    }

    /// The control: with a credential the header is exactly what it was, so
    /// the rule above cannot be satisfied by blanking the line for everyone.
    @Test("With an account the header still counts the library")
    func headerStillCountsASignedInLibrary() async throws {
        let model = LibraryModel(library: PagedLibrary(total: 250), hasCredentials: { true })
        await model.load()

        #expect(model.headerSubtitle == model.subtitle)
        #expect(model.headerSubtitle.contains("250"))
    }

    /// The control: a rejected token is a failure to show, not a missing one
    /// — "Add a token" would be actively wrong advice for a reader who has
    /// one and it was refused.
    @Test("A rejected credential is a failure, not a missing account")
    func rejectedCredentialIsFailureNotNoAccount() async throws {
        let model = LibraryModel(
            library: FailingLibrary(failure: .server(status: 401, message: "", party: .mangaBaka)),
            hasCredentials: { true }
        )
        await model.load()
        guard case .failed = model.screenState else {
            Issue.record("a rejected token must render as a failure, not \(model.screenState)")
            return
        }
    }

    /// Gap 89: signing out has to leave nothing of the previous account's
    /// library behind, or the next reader's session opens to it until
    /// relaunch.
    @Test("forget() clears the library so the next load starts fresh")
    func forgetClearsEverything() async throws {
        let model = LibraryModel(library: FixedLibrary(entries: [try entry(1, .reading)]))
        await model.load()
        #expect(!model.entries.isEmpty)

        await model.forget()
        #expect(model.entries.isEmpty)
        #expect(model.shelves.isEmpty)
        #expect(model.failure == nil)
    }

    // MARK: - Stubs

    /// A library that actually pages, with an optional failure point and a
    /// request counter — `LibraryModelTests.swift` keeps its own, simpler
    /// copy without either, since its tests do not need them.
    private final class PagedLibrary: LibraryProviding, @unchecked Sendable {
        let total: Int
        /// Throws `.offline` on this page and every one after, so a walk can
        /// be made to stop partway through for `partialFailure` tests.
        var failOnPage: Int?
        private let lock = NSLock()
        private var requests = 0

        init(total: Int, failOnPage: Int? = nil) {
            self.total = total
            self.failOnPage = failOnPage
        }

        var pageRequests: Int {
            lock.lock(); defer { lock.unlock() }
            return requests
        }

        func libraryPage(page: Int, limit: Int) async throws(APIError) -> [LibraryEntry] {
            lock.withLock { requests += 1 }
            if let failOnPage, page >= failOnPage { throw APIError.offline }
            let start = (page - 1) * limit
            guard start < total else { return [] }
            return (start..<min(start + limit, total)).map { index in
                LibraryEntry(
                    id: index, seriesId: index, state: .reading, progressChapter: nil,
                    progressVolume: nil, rating: nil, note: nil, startDate: nil,
                    finishDate: nil, numberOfRereads: nil, priority: nil,
                    isPrivate: nil, readLink: nil, series: nil
                )
            }
        }
        func library(page: Int, limit: Int) async -> [LibraryEntry] {
            (try? await libraryPage(page: page, limit: limit)) ?? []
        }
        func recommendationStatus() async throws(APIError) -> RecommendationStatus {
            throw APIError.offline
        }
        func recommendations(
            limit: Int, page: Int, excluding: [Int]
        ) async -> PersonalRecommendations { PersonalRecommendations() }
        func hiddenTagIDs() async -> Set<Int>? { [] }
        func topGenres() async -> [TopGenre]? { [] }
        func update(seriesId: Int, change: LibraryChange) async throws(APIError) {}
        func add(seriesId: Int, state: LibraryEntry.State) async throws(APIError) -> Bool { true }
        func remove(seriesId: Int) async throws(APIError) {}
    }

    private final class FailingLibrary: LibraryProviding, @unchecked Sendable {
        let failure: APIError
        init(failure: APIError) { self.failure = failure }

        func libraryPage(page: Int, limit: Int) async throws(APIError) -> [LibraryEntry] {
            throw failure
        }
        func library(page: Int, limit: Int) async -> [LibraryEntry] { [] }
        func recommendationStatus() async throws(APIError) -> RecommendationStatus {
            throw APIError.offline
        }
        func recommendations(
            limit: Int, page: Int, excluding: [Int]
        ) async -> PersonalRecommendations { PersonalRecommendations() }
        func hiddenTagIDs() async -> Set<Int>? { [] }
        func topGenres() async -> [TopGenre]? { [] }
        func update(seriesId: Int, change: LibraryChange) async throws(APIError) {}
        func add(seriesId: Int, state: LibraryEntry.State) async throws(APIError) -> Bool { true }
        func remove(seriesId: Int) async throws(APIError) {}
    }

    private final class FixedLibrary: LibraryProviding, @unchecked Sendable {
        let entries: [LibraryEntry]
        init(entries: [LibraryEntry]) { self.entries = entries }

        func library(page: Int, limit: Int) async -> [LibraryEntry] { page == 1 ? entries : [] }
        func recommendationStatus() async throws(APIError) -> RecommendationStatus {
            throw APIError.offline
        }
        func recommendations(
            limit: Int, page: Int, excluding: [Int]
        ) async -> PersonalRecommendations { PersonalRecommendations() }
        func hiddenTagIDs() async -> Set<Int>? { [] }
        func topGenres() async -> [TopGenre]? { [] }
        func update(seriesId: Int, change: LibraryChange) async throws(APIError) {}
        func add(seriesId: Int, state: LibraryEntry.State) async throws(APIError) -> Bool { true }
        func remove(seriesId: Int) async throws(APIError) {}
    }
}
