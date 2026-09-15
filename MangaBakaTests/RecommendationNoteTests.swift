import Foundation
import Testing
@testable import MangaBaka

/// The envelope around a recommended series — "10 shared tags", "86 readers"
/// — kept beside the row instead of dropped at the repository (Abdi,
/// 2026-09-15, after seeing the website say both). Fixtures are the live
/// answers for series 2060 captured the same day. `.serialized` for the stub.
@Suite("Recommendation notes survive to the row", .serialized)
struct RecommendationNoteTests {
    private let baseURL = URL(string: "https://api.example.invalid").unsafeTestURL

    private func makeRepository() throws -> SeriesRepository {
        SeriesRepository(
            client: APIClient(
                baseURL: baseURL, session: URLProtocolStub.makeSession(),
                tokenProvider: UnauthenticatedTokenProvider()
            ),
            database: try AppDatabase.inMemory(), clock: TestClock()
        )
    }

    /// Fails on the old `Recommendation` with `sharedUsers == nil`: the field
    /// was never modelled.
    @Test("readers-also-like decodes shared_users and rank")
    func decodesSharedUsers() throws {
        let rows = try Fixture.decoder().decode(
            APIEnvelope<[Recommendation]>.self, from: Fixture.data("readers-also-like-2060-2026-09-15")
        ).data ?? []
        let first = try #require(rows.first)
        #expect(first.rank == 1)
        let users = try #require(first.sharedUsers)
        #expect(users > 0)
        #expect(first.note.line == "\(users) readers")
    }

    @Test("similar decodes the shared-tag total, and the caption says it")
    func decodesSharedTags() throws {
        let rows = try Fixture.decoder().decode(
            APIEnvelope<[Recommendation]>.self, from: Fixture.data("similar-2060-2026-09-15")
        ).data ?? []
        let first = try #require(rows.first)
        let total = try #require(first.sharedTagsTotal)
        #expect(total > 1)
        #expect(first.sharedUsers == nil, "no reader signal on similar")
        #expect(first.note.line == "\(total) shared tags")
    }

    @Test("The caption's wording")
    func captionWording() {
        #expect(RecommendationNote(sharedUsers: 1).line == "1 reader")
        #expect(RecommendationNote(sharedTagsTotal: 1).line == "1 shared tag")
        #expect(RecommendationNote(sharedTagsTotal: 4, matchedAuthor: true).line == "Same author")
        #expect(RecommendationNote(sharedTagsTotal: 4, matchedRelated: true).line == "Directly related")
        #expect(RecommendationNote(sharedTagsTotal: 0).line == nil)
        #expect(RecommendationNote().line == nil)
    }

    /// The whole point: the note comes off the wire with the feed, and comes
    /// back off disk with it too. Fails on the old repository with
    /// `fresh.notes.isEmpty` (the envelope was dropped in
    /// `fetchConditionalFeed`).
    @Test("A feed's notes are returned fresh and again from the cache")
    func notesRoundTripTheCache() async throws {
        let body = try Fixture.data("similar-2060-2026-09-15")
        URLProtocolStub.setHandler { _ in .respond(.init(body: body)) }
        defer { URLProtocolStub.reset() }
        let repository = try makeRepository()

        let fresh = await repository.feed(.similar(seriesId: 2060), forceRefresh: true)
        #expect(fresh.origin == .network)
        #expect(!fresh.series.isEmpty)
        #expect(fresh.notes.count == fresh.series.count)
        let firstID = try #require(fresh.series.first?.id)
        #expect(fresh.notes[firstID]?.sharedTagsTotal ?? 0 > 0)

        let cached = await repository.feed(.similar(seriesId: 2060))
        #expect(cached.origin == .cache)
        #expect(cached.notes == fresh.notes, "the note column round-trips")
        #expect(URLProtocolStub.requests.count == 1)
    }

    /// A plain (non-recommendation) feed carries no notes and asks for none.
    @Test("A plain feed has no notes")
    func plainFeedHasNoNotes() async throws {
        let body = try Fixture.data("rising")
        URLProtocolStub.setHandler { _ in .respond(.init(body: body)) }
        defer { URLProtocolStub.reset() }
        let repository = try makeRepository()
        let result = await repository.feed(.rising, forceRefresh: true)
        #expect(result.notes.isEmpty)
        #expect(!result.series.isEmpty)
    }
}
