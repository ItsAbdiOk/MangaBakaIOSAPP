import Foundation
import Testing
@testable import MangaBaka

@Suite("Content preferences")
@MainActor
struct ContentPreferencesTests {
    private func makeDefaults() throws -> UserDefaults {
        let suite = "test.\(UUID().uuidString)"
        return try #require(UserDefaults(suiteName: suite))
    }

    @Test("Defaults to safe and suggestive, matching the product decision")
    func defaultsAreModest() {
        #expect(ContentPreferences.default.allowed == [.safe, .suggestive])
        #expect(!ContentPreferences.default.includesAdultContent)
    }

    /// A reader who turned everything off would see an empty app and no
    /// explanation for it, so safe cannot be switched off.
    @Test("Safe cannot be turned off")
    func safeIsAlwaysOn() async throws {
        let store = ContentPreferencesStore(defaults: try makeDefaults())
        await store.set(.safe, allowed: false)
        #expect(store.preferences.allowed.contains(.safe))
    }

    @Test("Opting in adds the rating and marks the app as adult")
    func optInWorks() async throws {
        let store = ContentPreferencesStore(defaults: try makeDefaults())
        await store.set(.erotica, allowed: true)

        #expect(store.preferences.allowed.contains(.erotica))
        #expect(store.preferences.includesAdultContent)
        #expect(store.preferences.queryValues.contains("erotica"))
    }

    @Test("Only the two mild ratings avoid a deliberate opt-in")
    func optInClassification() {
        #expect(!ContentPreferences.Rating.safe.requiresOptIn)
        #expect(!ContentPreferences.Rating.suggestive.requiresOptIn)
        #expect(ContentPreferences.Rating.erotica.requiresOptIn)
        #expect(ContentPreferences.Rating.pornographic.requiresOptIn)
    }

    /// The subtle one: a cached feed was fetched under the previous filter, so
    /// leaving it in place would keep showing content just excluded.
    @Test("Changing the setting notifies the cache owner with the new values")
    func changeNotifiesWithNewValues() async throws {
        let store = ContentPreferencesStore(defaults: try makeDefaults())
        let received = Received()
        store.onChange = { values in await received.record(values) }

        await store.set(.erotica, allowed: true)

        let values = await received.values
        #expect(values.count == 1)
        #expect(values.first?.contains("erotica") == true)
    }

    /// Setting a value it already has must not throw away cached feeds for
    /// nothing — that would cost a full refetch against a shared rate limit.
    @Test("A no-op change does not notify")
    func noOpDoesNotNotify() async throws {
        let store = ContentPreferencesStore(defaults: try makeDefaults())
        let received = Received()
        store.onChange = { values in await received.record(values) }

        await store.set(.safe, allowed: true)

        #expect(await received.values.isEmpty)
    }

    @Test("The choice survives a relaunch")
    func persists() async throws {
        let defaults = try makeDefaults()
        let first = ContentPreferencesStore(defaults: defaults)
        await first.set(.erotica, allowed: true)

        let second = ContentPreferencesStore(defaults: defaults)
        #expect(second.preferences.allowed.contains(.erotica))
    }

    /// Safe is re-added on load, so a hand-edited or corrupt value cannot
    /// produce an app that shows nothing.
    @Test("A stored value missing safe is repaired on load")
    func repairsMissingSafe() throws {
        let defaults = try makeDefaults()
        defaults.set(["erotica"], forKey: "content.allowedRatings")

        let store = ContentPreferencesStore(defaults: defaults)
        #expect(store.preferences.allowed.contains(.safe))
    }

    @Test("Query values are ordered and never comma-joined")
    func queryValueShape() {
        let preferences = ContentPreferences(allowed: [.pornographic, .safe, .suggestive])
        #expect(preferences.queryValues == ["safe", "suggestive", "pornographic"])
        #expect(!preferences.queryValues.contains { $0.contains(",") })
    }

    private actor Received {
        var values: [[String]] = []
        func record(_ value: [String]) { values.append(value) }
    }
}

@Suite("Content filter and the cache", .serialized)
struct ContentFilterCacheTests {
    private let baseURL = URL(string: "https://api.example.invalid").unsafeTestURL

    private func makeRepository() throws -> SeriesRepository {
        SeriesRepository(
            client: APIClient(
                baseURL: baseURL,
                session: URLProtocolStub.makeSession(),
                tokenProvider: UnauthenticatedTokenProvider()
            ),
            database: try AppDatabase.inMemory(),
            clock: TestClock()
        )
    }

    private let payload = Data("""
    {"status":200,"data":[
      {"id":1,"state":"active","merged_with":null,
       "titles":[{"language":"en","traits":["official"],"title":"A","is_primary":true}],
       "cover":{"raw":null,"x150":null,"x250":null,"x350":null,
                "blurhash":null,"width":200,"height":300},
       "description":null,"authors":null,"artists":null,"status":null,
       "rating":null,"type":null,"content_rating":null,
       "total_chapters":null,"final_volume":null,
       "publishers":null,"anime":null,"source":null}
    ]}
    """.utf8)

    /// The whole reason the change notification exists.
    @Test("Changing the filter discards cached feeds so they are refetched")
    func changeInvalidatesCache() async throws {
        URLProtocolStub.setHandler { [payload] _ in .respond(.init(body: payload)) }
        defer { URLProtocolStub.reset() }

        let repository = try makeRepository()
        _ = await repository.feed(.rising, forceRefresh: false)
        #expect(await repository.feed(.rising, forceRefresh: false).origin == .cache)
        let before = URLProtocolStub.requests.count

        await repository.updateContentRatings(["safe", "suggestive", "erotica"])

        let after = await repository.feed(.rising, forceRefresh: false)
        #expect(after.origin == .network, "A feed fetched under the old filter must not be reused")
        #expect(URLProtocolStub.requests.count == before + 1)
    }

    /// Clearing the cache on every settings tap would cost a full refetch
    /// against a rate limit shared with strangers.
    @Test("Setting the same ratings does not discard the cache")
    func noOpKeepsCache() async throws {
        URLProtocolStub.setHandler { [payload] _ in .respond(.init(body: payload)) }
        defer { URLProtocolStub.reset() }

        let repository = try makeRepository()
        _ = await repository.feed(.rising, forceRefresh: false)

        await repository.updateContentRatings(["safe", "suggestive"])

        #expect(await repository.feed(.rising, forceRefresh: false).origin == .cache)
    }

    /// The shelf is the reader's own saves, not derived data. Losing it because
    /// a content toggle moved would be indefensible.
    @Test("Changing the filter never touches the reader's shelf")
    func shelfSurvives() async throws {
        let database = try AppDatabase.inMemory()
        let shelf = ShelfStore(database: database, clock: TestClock())
        let repository = SeriesRepository(
            client: APIClient(
                baseURL: baseURL,
                session: URLProtocolStub.makeSession(),
                tokenProvider: UnauthenticatedTokenProvider()
            ),
            database: database,
            clock: TestClock()
        )
        try await shelf.record(SeriesFactory.make(id: 42, title: "Kept"), as: .saved)

        await repository.updateContentRatings(["safe"])

        let saved = try await shelf.entries(.saved)
        #expect(saved.map(\.id) == [42], "A save is not derived data and must survive")
    }
}
