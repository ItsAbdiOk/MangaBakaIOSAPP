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

    /// A suite of its own per test, never the app's `UserDefaults.standard` —
    /// see `SeriesRepository.defaults`. This suite used to be `.standard`,
    /// restored in a `defer`, and a crash mid-test (or a run stopped from the
    /// test navigator) skipped the `defer` and left `cache.libraryExclusionUserID`
    /// set for the next real launch: the app has already been polluted this way
    /// once.
    /// The suite *name*, not the instance. `UserDefaults` is not `Sendable`,
    /// so handing an existing one to an actor's initialiser is a "sending
    /// risks data races" error; one constructed inside the call is a fresh
    /// value in its own region and crosses cleanly. A test that also needs to
    /// read the suite makes its own handle from the same name — they address
    /// the same store, and `UserDefaults` is documented thread-safe.
    private static func testSuiteName() -> String { "test-\(UUID())" }

    private static func handle(_ suiteName: String) throws -> UserDefaults {
        try #require(UserDefaults(suiteName: suiteName))
    }

    private static func repository(_ database: AppDatabase, suiteName: String) throws -> SeriesRepository {
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
            clock: TestClock(),
            defaults: try #require(UserDefaults(suiteName: suiteName))
        )
    }

    @Test("Relaunching with the id the cache was built under keeps the cache")
    func relaunchKeepsTheCache() async throws {
        // The bug this replaces: the id always differed from the nil a fresh
        // process starts with, so every launch by a signed-in reader deleted
        // the whole feed cache before the first screen drew.
        let suiteName = Self.testSuiteName()
        try Self.handle(suiteName).set("reader-one", forKey: Self.key)
        let repository = try Self.repository(try AppDatabase.inMemory(), suiteName: suiteName)
        _ = await repository.feed(.rising, forceRefresh: false)
        let before = URLProtocolStub.requests.count

        await repository.updateLibraryExclusion(userID: "reader-one")
        _ = await repository.feed(.rising, forceRefresh: false)

        #expect(URLProtocolStub.requests.count == before, "the cache was written under this id")
        URLProtocolStub.reset()
    }

    @Test("Signing in after browsing signed out discards the cache")
    func signingInDiscards() async throws {
        let repository = try Self.repository(try AppDatabase.inMemory(), suiteName: Self.testSuiteName())
        _ = await repository.feed(.rising, forceRefresh: false)
        let before = URLProtocolStub.requests.count

        await repository.updateLibraryExclusion(userID: "reader-one")
        _ = await repository.feed(.rising, forceRefresh: false)

        #expect(
            URLProtocolStub.requests.count == before + 1,
            "those blends hold series the reader already tracks"
        )
        URLProtocolStub.reset()
    }

    /// A guard, not a reproduction: the old code wrote `UserDefaults.standard`
    /// and restored it in a `defer`, which reads back clean on a normal pass
    /// too — the failure mode it had (a crash, or a run stopped from the test
    /// navigator, skipping the `defer`) cannot be forced from in here. This
    /// only proves the new code has no such path to fail down.
    ///
    /// It used to assert `UserDefaults.standard.object(forKey:) == nil`
    /// outright, and failed: that asserts the *whole process and the
    /// simulator's stored defaults* are clean, which is not this suite's to
    /// promise — a value left behind by an earlier run of the old code (the
    /// pollution this scoping exists to stop) fails it forever, and clearing
    /// `.standard` to make it pass would be this suite writing the app's
    /// defaults, the exact thing it forbids. What this suite can honestly
    /// promise is that its own write lands in its own store and leaves
    /// `.standard` as it found it, which is what is asserted now.
    @Test("This suite's own write lands in its own suite, not in UserDefaults.standard")
    func doesNotTouchStandardDefaults() async throws {
        let suiteName = Self.testSuiteName()
        let before = UserDefaults.standard.object(forKey: Self.key) as? String

        let repository = try Self.repository(try AppDatabase.inMemory(), suiteName: suiteName)
        await repository.updateLibraryExclusion(userID: "reader-one")
        URLProtocolStub.reset()

        let handle = try Self.handle(suiteName)
        #expect(handle.string(forKey: Self.key) == "reader-one")
        let after = UserDefaults.standard.object(forKey: Self.key) as? String
        #expect(after == before, "this suite must leave the app's own defaults exactly as it found them")

        UserDefaults.standard.removePersistentDomain(forName: suiteName)
    }
}
