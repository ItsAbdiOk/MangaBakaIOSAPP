import Testing
import Foundation
@testable import MangaBaka

/// Whether a filter change discards the cache it invalidated.
///
/// The exclusion id is the awkward one: the `applied` mechanism assumes a
/// first application is not a change, which is true for every filter read from
/// the same `UserDefaults` the cache was written under, and false for this one.
/// Both directions have shipped as bugs, so both are pinned here.
@Suite("The exclusion id is compared against the cache, not against the process", .serialized)
struct ExclusionInvalidationTests {
    private static let key = "cache.libraryExclusionUserID"

    private static func repository(_ database: AppDatabase) -> SeriesRepository {
        let payload = Data(#"{"status":200,"data":[{"id":1,"state":"active","cover":{}}]}"#.utf8)
        URLProtocolStub.setHandler { _ in .respond(.init(body: payload)) }
        // A database this test owns, so the cache it writes is its own.
        return SeriesRepository(
            client: APIClient(
                baseURL: URL(string: "https://api.example.invalid").unsafeTestURL,
                session: URLProtocolStub.makeSession(),
                tokenProvider: UnauthenticatedTokenProvider()
            ),
            database: database,
            clock: TestClock()
        )
    }

    /// Restored after each test: these write the same key the app does, and a
    /// test that leaves it set has already polluted a simulator once.
    private func withCleanDefaults(_ body: () async throws -> Void) async rethrows {
        let previous = UserDefaults.standard.string(forKey: Self.key)
        UserDefaults.standard.removeObject(forKey: Self.key)
        defer { UserDefaults.standard.set(previous, forKey: Self.key) }
        try await body()
    }

    @Test("Relaunching with the id the cache was built under keeps the cache")
    func relaunchKeepsTheCache() async throws {
        // The bug this replaces: the id always differed from the nil a fresh
        // process starts with, so every launch by a signed-in reader deleted
        // the whole feed cache before the first screen drew.
        try await withCleanDefaults {
            UserDefaults.standard.set("reader-one", forKey: Self.key)
            let repository = Self.repository(try AppDatabase.inMemory())
            _ = await repository.feed(.rising, forceRefresh: false)
            let before = URLProtocolStub.requests.count

            await repository.updateLibraryExclusion(userID: "reader-one")
            _ = await repository.feed(.rising, forceRefresh: false)

            #expect(URLProtocolStub.requests.count == before, "the cache was written under this id")
        }
        URLProtocolStub.reset()
    }

    @Test("Signing in after browsing signed out discards the cache")
    func signingInDiscards() async throws {
        try await withCleanDefaults {
            let repository = Self.repository(try AppDatabase.inMemory())
            _ = await repository.feed(.rising, forceRefresh: false)
            let before = URLProtocolStub.requests.count

            await repository.updateLibraryExclusion(userID: "reader-one")
            _ = await repository.feed(.rising, forceRefresh: false)

            #expect(
                URLProtocolStub.requests.count == before + 1,
                "those blends hold series the reader already tracks"
            )
        }
        URLProtocolStub.reset()
    }
}
