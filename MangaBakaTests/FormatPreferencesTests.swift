import Foundation
import Testing
@testable import MangaBaka

/// The format filter — the answer to "why is there a novel in my manga app".
@Suite("Format preferences", .serialized)
@MainActor
struct FormatPreferencesTests {
    private func makeDefaults() throws -> UserDefaults {
        let suite = "format.tests.\(UUID().uuidString)"
        return try #require(UserDefaults(suiteName: suite))
    }

    @Test("Everything is on by default, and sends no filter")
    func defaultsToEverything() {
        let preferences = FormatPreferences.default
        #expect(preferences.allowed.count == FormatPreferences.Format.allCases.count)
        // All six values means the same as none, and none is one fewer
        // parameter to get wrong on an API that is inconsistent about how
        // repeated keys are encoded.
        #expect(preferences.queryValues.isEmpty)
        #expect(!preferences.isFiltering)
    }

    @Test("Switching a format off sends the remaining ones as repeated values")
    func narrowsToSelection() {
        var preferences = FormatPreferences.default
        preferences.setAllowed(.novel, false)
        preferences.setAllowed(.oel, false)
        preferences.setAllowed(.other, false)

        #expect(preferences.queryValues == ["manga", "manhwa", "manhua"])
        #expect(preferences.isFiltering)
    }

    /// The same trap the content rating avoids by pinning "safe" on: a reader
    /// who switched everything off would get an empty app with no visible cause.
    @Test("The last format on cannot be switched off")
    func keepsOneFormat() {
        var preferences = FormatPreferences(allowed: [.manga])
        preferences.setAllowed(.manga, false)
        #expect(preferences.allowed == [.manga])
    }

    @Test("The choice survives a relaunch")
    func persists() async throws {
        let defaults = try makeDefaults()
        let store = FormatPreferencesStore(defaults: defaults)
        await store.set(.novel, allowed: false)

        let reloaded = FormatPreferencesStore(defaults: defaults)
        #expect(!reloaded.preferences.allowed.contains(.novel))
        #expect(reloaded.preferences.allowed.contains(.manga))
    }

    /// Storing `queryValues` would be the obvious mistake: it is deliberately
    /// empty when everything is on, which on reload is indistinguishable from
    /// nothing being on.
    @Test("Everything-on survives a relaunch as everything-on, not as nothing")
    func persistsEverythingOn() async throws {
        let defaults = try makeDefaults()
        let store = FormatPreferencesStore(defaults: defaults)
        await store.set(.novel, allowed: false)
        await store.set(.novel, allowed: true)

        let reloaded = FormatPreferencesStore(defaults: defaults)
        #expect(reloaded.preferences == .default)
    }

    /// A cached feed was fetched under the previous filter, so keeping it would
    /// keep showing exactly what the reader has just excluded.
    @Test("Changing the filter notifies whoever owns the cache")
    func notifiesOnChange() async throws {
        let defaults = try makeDefaults()
        let store = FormatPreferencesStore(defaults: defaults)

        let recorder = Recorder()
        store.onChange = { await recorder.record($0) }

        await store.set(.novel, allowed: false)
        #expect(await recorder.values.count == 1)
        #expect(await recorder.values.first?.contains("novel") == false)

        // Setting a value it already holds must not invalidate: clearing the
        // cache on every settings tap costs a full refetch against a shared
        // rate limit.
        await store.set(.novel, allowed: false)
        #expect(await recorder.values.count == 1)
    }

    private actor Recorder {
        private(set) var values: [[String]] = []
        func record(_ value: [String]) { values.append(value) }
    }
}

/// The filter has to reach the wire, not just the model. This is the class of
/// bug that broke every feed once already: the setting was right and the URL
/// was not.
@Suite("Format filter reaches the request", .serialized)
struct FormatRequestTests {
    private let baseURL = URL(string: "https://api.example.invalid").unsafeTestURL
    private let emptyPayload = Data(#"{"status":200,"data":[]}"#.utf8)

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

    private func items(from request: URLRequest?) throws -> [URLQueryItem] {
        let url = try #require(request?.url)
        return try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
    }

    @Test("A feed sends the chosen formats as repeated type keys")
    func feedSendsFormats() async throws {
        URLProtocolStub.setHandler { [payload = emptyPayload] _ in .respond(.init(body: payload)) }
        defer { URLProtocolStub.reset() }

        let repository = try makeRepository()
        await repository.updateFormats(["manga", "manhwa"])
        _ = await repository.feed(.rising, forceRefresh: true)

        let sent = try items(from: URLProtocolStub.requests.first)
        #expect(sent.filter { $0.name == "type" }.map(\.value) == ["manga", "manhwa"])
        // Comma-joining is what the API rejects with HTTP 400.
        #expect(!sent.contains { $0.name == "type" && ($0.value ?? "").contains(",") })
    }

    @Test("Search sends the chosen formats too")
    func searchSendsFormats() async throws {
        URLProtocolStub.setHandler { [payload = emptyPayload] _ in .respond(.init(body: payload)) }
        defer { URLProtocolStub.reset() }

        let repository = try makeRepository()
        await repository.updateFormats(["manga"])
        _ = await repository.search(SearchQuery(text: "solo"))

        let sent = try items(from: URLProtocolStub.requests.first)
        #expect(sent.filter { $0.name == "type" }.map(\.value) == ["manga"])
    }

    /// Sending both would intersect them, so choosing "novel" in the filter
    /// sheet while novels are off in Settings would return nothing at all
    /// rather than what was asked for — a filter that silently lies.
    @Test("An explicit filter-sheet choice overrides the standing preference")
    func explicitChoiceWins() async throws {
        URLProtocolStub.setHandler { [payload = emptyPayload] _ in .respond(.init(body: payload)) }
        defer { URLProtocolStub.reset() }

        let repository = try makeRepository()
        await repository.updateFormats(["manga"])
        var query = SearchQuery(text: "solo")
        query.types = ["novel"]
        _ = await repository.search(query)

        let sent = try items(from: URLProtocolStub.requests.first)
        #expect(sent.filter { $0.name == "type" }.map(\.value) == ["novel"])
    }

    @Test("Changing the format filter discards cached feeds")
    func changeDiscardsCache() async throws {
        let payload = Data(#"{"status":200,"data":[{"id":1,"state":"active","cover":{}}]}"#.utf8)
        URLProtocolStub.setHandler { _ in .respond(.init(body: payload)) }
        defer { URLProtocolStub.reset() }

        let repository = try makeRepository()
        // Applied once first, the way the app does at launch. A first
        // application is not a change: the repository starts with no filters,
        // so treating that as one discarded the whole feed cache on every
        // single launch and offline support never worked once.
        await repository.updateFormats([])
        _ = await repository.feed(.rising, forceRefresh: false)
        let afterFirst = URLProtocolStub.requests.count

        // Cached: no second request.
        _ = await repository.feed(.rising, forceRefresh: false)
        #expect(URLProtocolStub.requests.count == afterFirst)

        await repository.updateFormats(["manga"])
        _ = await repository.feed(.rising, forceRefresh: false)
        #expect(URLProtocolStub.requests.count == afterFirst + 1)
    }
}
