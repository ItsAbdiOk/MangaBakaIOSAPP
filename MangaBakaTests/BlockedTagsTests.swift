import Foundation
import Testing
@testable import MangaBaka

/// Blocking a tag hides content everywhere, so getting it wrong either shows
/// someone what they asked not to see, or silently hides half the catalogue.
@Suite("Blocked tags", .serialized)
@MainActor
struct BlockedTagsTests {
    private func makeDefaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "blocked.tests.\(UUID().uuidString)"))
    }

    @Test("Blocking and unblocking are the same control")
    func toggles() {
        var blocked = BlockedTags.none
        blocked.toggle(id: 467, name: "Kuudere")
        #expect(blocked.contains(467))
        #expect(blocked.ids == [467])

        blocked.toggle(id: 467, name: "Kuudere")
        #expect(!blocked.contains(467))
        #expect(blocked.isEmpty)
    }

    /// A count alone would leave the reader unable to work out why something is
    /// missing from their own app.
    @Test("The summary names what is blocked, not just how many")
    func summaryNamesThem() {
        var blocked = BlockedTags.none
        #expect(blocked.summary == "Nothing blocked")

        blocked.toggle(id: 1, name: "Incest")
        blocked.toggle(id: 2, name: "Rape")
        #expect(blocked.summary == "Incest, Rape")
    }

    @Test("The list survives a relaunch")
    func persists() async throws {
        let defaults = try makeDefaults()
        let store = BlockedTagsStore(defaults: defaults)
        await store.toggle(id: 467, name: "Kuudere")

        let reloaded = BlockedTagsStore(defaults: defaults)
        #expect(reloaded.blocked.contains(467))
        #expect(reloaded.blocked.summary == "Kuudere")
    }

    /// Cached feeds were fetched without the block and still hold what the
    /// reader has just chosen not to see.
    @Test("Changing the list notifies whoever owns the cache")
    func notifiesOnChange() async throws {
        let store = BlockedTagsStore(defaults: try makeDefaults())
        let recorder = Recorder()
        store.onChange = { await recorder.record($0) }

        await store.toggle(id: 5, name: "A")
        #expect(await recorder.values == [[5]])

        // Unblocking is also a change: the cache is now over-filtered.
        await store.toggle(id: 5, name: "A")
        #expect(await recorder.values.count == 2)
    }

    private actor Recorder {
        private(set) var values: [[Int]] = []
        func record(_ value: [Int]) { values.append(value) }
    }
}

/// The block has to reach the wire, on every surface, or it is decoration.
@Suite("Blocked tags reach the request", .serialized)
struct BlockedTagsRequestTests {
    private let baseURL = URL(string: "https://api.example.invalid").unsafeTestURL
    private let empty = Data(#"{"status":200,"data":[]}"#.utf8)

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

    @Test("A feed excludes blocked tags")
    func feedExcludes() async throws {
        URLProtocolStub.setHandler { [payload = empty] _ in .respond(.init(body: payload)) }
        defer { URLProtocolStub.reset() }

        let repository = try makeRepository()
        await repository.updateBlockedTags([11, 22])
        _ = await repository.feed(.rising, forceRefresh: true)

        let sent = try items(from: URLProtocolStub.requests.first)
        #expect(sent.filter { $0.name == "tag_not" }.compactMap(\.value) == ["11", "22"])
    }

    @Test("Search excludes them too")
    func searchExcludes() async throws {
        URLProtocolStub.setHandler { [payload = empty] _ in .respond(.init(body: payload)) }
        defer { URLProtocolStub.reset() }

        let repository = try makeRepository()
        await repository.updateBlockedTags([7])
        _ = await repository.search(SearchQuery(text: "solo"))

        let sent = try items(from: URLProtocolStub.requests.first)
        #expect(sent.contains { $0.name == "tag_not" && $0.value == "7" })
    }

    /// A blend takes `blocked_tag`, the parameter meant for a standing block,
    /// verified live: blocking the top strand changed 12 of 20 results.
    @Test("A blend uses the endpoint's own blocking parameter")
    func blendUsesBlockedTag() async throws {
        URLProtocolStub.setHandler { [payload = empty] _ in .respond(.init(body: payload)) }
        defer { URLProtocolStub.reset() }

        let repository = try makeRepository()
        await repository.updateBlockedTags([467])
        _ = await repository.mix(seeds: [1], filters: SearchQuery(), excludedTags: [])

        let sent = try items(from: URLProtocolStub.requests.first)
        #expect(sent.contains { $0.name == "blocked_tag" && $0.value == "467" })
    }

    /// Cached results were fetched without the block.
    @Test("Blocking discards the cache")
    func blockingDiscardsCache() async throws {
        let payload = Data(#"{"status":200,"data":[{"id":1,"state":"active","cover":{}}]}"#.utf8)
        URLProtocolStub.setHandler { _ in .respond(.init(body: payload)) }
        defer { URLProtocolStub.reset() }

        let repository = try makeRepository()
        // Applied once first, the way the app does at launch. A first
        // application is not a change: the repository starts with no filters,
        // so treating that as one discarded the whole feed cache on every
        // single launch and offline support never worked once.
        await repository.updateBlockedTags([])
        _ = await repository.feed(.rising, forceRefresh: false)
        let before = URLProtocolStub.requests.count
        _ = await repository.feed(.rising, forceRefresh: false)
        #expect(URLProtocolStub.requests.count == before, "control: served from cache")

        await repository.updateBlockedTags([3])
        _ = await repository.feed(.rising, forceRefresh: false)
        #expect(URLProtocolStub.requests.count == before + 1)
    }
}

/// A blocked list the reader cannot find is indistinguishable from a broken
/// app: things are missing and there is no way to learn why.
@Suite("Blocked tags are findable", .enabled(if: SourceTree.isAvailable))
struct BlockedTagsDiscoverabilityTests {
    @Test("Settings lists what has been blocked, and can unblock it")
    func settingsListsThem() throws {
        // Moved to its own file when the section stopped hiding itself while
        // empty — the one place a reader looks to find out what they have
        // hidden used to disappear exactly when the answer was "nothing".
        let source = try SourceTree.read("MangaBaka/Features/Settings/BlockedTagsSection.swift")
        #expect(source.contains("Blocked tags"))
        #expect(source.contains("blockedTags.toggle"))
        #expect(source.contains("Unblock"))
        #expect(
            !source.contains("if !blockedTags.blocked.isEmpty"),
            "the section has to be there when the list is empty, or the feature looks absent"
        )
    }

    /// Blocking happens where the tags are; the list lives where a reader looks
    /// for what they have hidden. Both routes have to exist.
    @Test("Blocking is offered from the tag list itself")
    func browseOffersBlocking() throws {
        let source = try SourceTree.read("MangaBaka/Features/Browse/BrowseView.swift")
        #expect(source.contains("blockLabel"))
        #expect(source.contains("blocked.toggle"))
    }
}
