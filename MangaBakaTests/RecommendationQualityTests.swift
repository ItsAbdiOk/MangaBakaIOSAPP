import Foundation
import Testing
@testable import MangaBaka

/// "The stack has some BAD recommendations, are you sure it's using my tastes?"
/// — a fair question, and the answer was no. These cover the three things that
/// were wrong about how the queue is built.
@Suite("Recommendation quality", .serialized)
struct RecommendationQualityTests {
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

    // MARK: - Excluding what the reader already tracks

    /// The single largest source of bad suggestions for a reader with a big
    /// library: being offered what they are already reading.
    @Test("A blend excludes the reader's own library once the id is known")
    func blendExcludesLibrary() async throws {
        URLProtocolStub.setHandler { [payload = emptyPayload] _ in .respond(.init(body: payload)) }
        defer { URLProtocolStub.reset() }

        let repository = try makeRepository()
        let userID = String(repeating: "a", count: 32)
        await repository.updateLibraryExclusion(userID: userID)
        _ = await repository.feed(.mix(seeds: [1]), forceRefresh: true)

        let sent = try items(from: URLProtocolStub.requests.first)
        #expect(sent.first { $0.name == "exclude_user_library" }?.value == userID)
    }

    /// Not a boolean, despite the name. The API rejects `true` outright:
    /// "expected string, received boolean", and separately requires at least 32
    /// characters — both verified against the live endpoint on 2026-09-09.
    @Test("The exclusion is sent as an id, never as a boolean")
    func exclusionIsNotABoolean() async throws {
        URLProtocolStub.setHandler { [payload = emptyPayload] _ in .respond(.init(body: payload)) }
        defer { URLProtocolStub.reset() }

        let repository = try makeRepository()
        await repository.updateLibraryExclusion(userID: String(repeating: "b", count: 32))
        _ = await repository.feed(.mix(seeds: [1]), forceRefresh: true)

        let value = try #require(
            items(from: URLProtocolStub.requests.first)
                .first { $0.name == "exclude_user_library" }?.value
        )
        #expect(value != "true")
        #expect(value.count >= 32)
    }

    /// Browsing is not blending. Finding something already on your shelf while
    /// searching is useful; being recommended it is not.
    @Test("Search and discovery are not narrowed by the library exclusion")
    func exclusionAppliesOnlyToBlends() async throws {
        URLProtocolStub.setHandler { [payload = emptyPayload] _ in .respond(.init(body: payload)) }
        defer { URLProtocolStub.reset() }

        let repository = try makeRepository()
        await repository.updateLibraryExclusion(userID: String(repeating: "c", count: 32))
        _ = await repository.search(SearchQuery(text: "solo"))
        _ = await repository.feed(.rising, forceRefresh: true)

        // Two requests went out, or the loop below asserts on nothing and
        // reports that no identity leaked without having looked.
        #expect(URLProtocolStub.requests.count == 2)
        for request in URLProtocolStub.requests {
            let names = try items(from: request).map(\.name)
            #expect(!names.contains("exclude_user_library"))
        }
    }

    /// A cached blend was built without the exclusion, so it still holds series
    /// the reader already tracks.
    @Test("Learning the reader's id discards blends built without it")
    func exclusionInvalidatesCache() async throws {
        let payload = Data(#"{"status":200,"data":[{"id":1,"state":"active","cover":{}}]}"#.utf8)
        URLProtocolStub.setHandler { _ in .respond(.init(body: payload)) }
        defer { URLProtocolStub.reset() }

        let repository = try makeRepository()
        _ = await repository.feed(.rising, forceRefresh: false)
        let before = URLProtocolStub.requests.count
        _ = await repository.feed(.rising, forceRefresh: false)
        #expect(URLProtocolStub.requests.count == before, "control: served from cache")

        await repository.updateLibraryExclusion(userID: String(repeating: "d", count: 32))
        _ = await repository.feed(.rising, forceRefresh: false)
        #expect(URLProtocolStub.requests.count == before + 1)
    }
}

/// The profile recommender: paging, exclusions, and saying why.
@Suite("Profile recommendations", .serialized)
struct ProfileRecommendationTests {
    private let baseURL = URL(string: "https://api.example.invalid").unsafeTestURL

    private func makeService() -> LibraryService {
        LibraryService(
            client: APIClient(
                baseURL: baseURL,
                session: URLProtocolStub.makeSession(),
                tokenProvider: UnauthenticatedTokenProvider()
            )
        )
    }

    private func items(from request: URLRequest?) throws -> [URLQueryItem] {
        let url = try #require(request?.url)
        return try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
    }

    private let emptyResults = Data(#"{"status":200,"results":[]}"#.utf8)

    /// A skip used to hide one series and teach the recommender nothing. Now
    /// every reaction is sent as an exclusion, so the next page is built around
    /// them rather than merely filtered afterwards — which is the difference
    /// between a page of twenty and a page of ten.
    @Test("Reactions are sent as exclusions, as repeated keys")
    func sendsExclusions() async throws {
        URLProtocolStub.setHandler { [payload = emptyResults] _ in .respond(.init(body: payload)) }
        defer { URLProtocolStub.reset() }

        _ = await makeService().recommendations(limit: 20, page: 2, excluding: [7, 8, 9])

        let sent = try items(from: URLProtocolStub.requests.first)
        #expect(sent.filter { $0.name == "exclude_ids" }.compactMap(\.value) == ["7", "8", "9"])
        #expect(sent.first { $0.name == "page" }?.value == "2")
        #expect(!sent.contains { $0.name == "exclude_ids" && ($0.value ?? "").contains(",") })
    }

    /// Page one sends no page parameter, matching every other paged call here.
    @Test("The first page is implicit")
    func firstPageIsImplicit() async throws {
        URLProtocolStub.setHandler { [payload = emptyResults] _ in .respond(.init(body: payload)) }
        defer { URLProtocolStub.reset() }

        _ = await makeService().recommendations()

        let names = try items(from: URLProtocolStub.requests.first).map(\.name)
        #expect(!names.contains("page"))
    }

    /// These are built from the reader's own library, so an unfiltered
    /// recommendation is the one place the content setting failing would be
    /// least forgivable. The API honours it — checked by reading back the
    /// content rating of what it returned, not by trusting the parameter.
    @Test("The content and format filters both reach the recommender")
    func appliesFilters() async throws {
        URLProtocolStub.setHandler { [payload = emptyResults] _ in .respond(.init(body: payload)) }
        defer { URLProtocolStub.reset() }

        let service = makeService()
        await service.updateFormats(["manga"])
        _ = await service.recommendations()

        let sent = try items(from: URLProtocolStub.requests.first)
        #expect(Set(sent.filter { $0.name == "content_rating" }.compactMap(\.value))
            == ["safe", "suggestive"])
        #expect(sent.filter { $0.name == "type" }.compactMap(\.value) == ["manga"])
    }

    /// The endpoint returns a cover object and no description, authors or
    /// status. The conversion must not invent them.
    @Test("A recommendation converts to a series without inventing fields")
    func conversionInventsNothing() throws {
        let decoder = Fixture.decoder()
        let recommendation = try decoder.decode(PersonalRecommendation.self, from: Data("""
        {"id":42,"titles":[{"language":"en","traits":["official"],
                            "title":"A Title","is_primary":true}],
         "cover_image":{"raw":{"url":"https://cdn.example.invalid/a.jpg",
                               "width":690,"height":1000}},
         "media_type":"manga","published_year":2020,"score":0.8}
        """.utf8))

        let series = recommendation.asSeries
        #expect(series.id == 42)
        #expect(series.displayTitle == "A Title")
        #expect(series.type == "manga")
        #expect(series.cover.raw != nil)
        // Absent at the endpoint, so absent here.
        #expect(series.description == nil)
        #expect(series.authors == nil)
        #expect(series.rating == nil)
        // The one assumption, stated in the model: the recommender only offers
        // series that can be read.
        #expect(series.isDiscoverable)
    }
}

/// Which source the swipe stack draws from, and whether it says so honestly.
@Suite("Stack source selection")
struct StackSourceTests {
    /// A library stub, so "which source was used" can be asked without going
    /// near a URL.
    private final class StubLibrary: LibraryProviding, @unchecked Sendable {
        var status: RecommendationStatus?
        var pages: [[PersonalRecommendation]] = []
        var libraryEntries: [LibraryEntry] = []
        private(set) var requestedPages: [Int] = []
        private(set) var sentExclusions: [[Int]] = []

        init(status: RecommendationStatus?) { self.status = status }

        func recommendationStatus() async -> RecommendationStatus? { status }

        func recommendations(
            limit: Int, page: Int, excluding: [Int]
        ) async -> [PersonalRecommendation] {
            requestedPages.append(page)
            sentExclusions.append(excluding)
            guard page <= pages.count else { return [] }
            return pages[page - 1]
        }

        func library(page: Int, limit: Int) async -> [LibraryEntry] { libraryEntries }
        func topGenres() async -> [TopGenre]? { [] }
        func update(seriesId: Int, change: LibraryChange) async throws(APIError) {}
        func add(seriesId: Int, state: LibraryEntry.State) async throws(APIError) -> Bool { true }
        func remove(seriesId: Int) async throws(APIError) {}

        /// Nil by default is deliberate: it is the "not known" case, and the
        /// tests below pin what happens then.
        var hiddenTags: Set<Int>? = []
        func hiddenTagIDs() async -> Set<Int>? { hiddenTags }
    }

    private func recommendation(_ id: Int, tags: [String] = []) throws -> PersonalRecommendation {
        let tagJSON = tags
            .map { #"{"id":1,"name":"\#($0)","weight":"core"}"# }
            .joined(separator: ",")
        return try Fixture.decoder().decode(PersonalRecommendation.self, from: Data("""
        {"id":\(id),"titles":[{"language":"en","traits":["official"],
                               "title":"Title \(id)","is_primary":true}],
         "cover_image":{"raw":{"url":"https://cdn.example.invalid/\(id).jpg"}},
         "media_type":"manga",
         "reason":{"reason_type":"similar_to","top_tags":[\(tagJSON)]}}
        """.utf8))
    }

    private final class SilentRepository: StubRepositoryBase, @unchecked Sendable {}

    private func makeShelf() throws -> ShelfStore {
        ShelfStore(database: try AppDatabase.inMemory())
    }

    /// The profile recommender wins wherever it is available: it draws on the
    /// whole library rather than three seeds, and it can explain itself.
    @Test("A reader with a profile gets profile recommendations, not a blend")
    func prefersProfile() async throws {
        let library = StubLibrary(
            status: try Fixture.decoder().decode(
                RecommendationStatus.self,
                from: Data(#"{"cold_start":false,"library_count":937}"#.utf8)
            )
        )
        library.pages = [[try recommendation(1), try recommendation(2)]]

        let model = await StackModel(
            repository: SilentRepository(), shelf: try makeShelf(), library: library
        )
        await model.loadIfNeeded()

        #expect(await model.source == .yourProfile)
        #expect(await model.queue.count == 2)
    }

    /// cold_start means the library is too small to build a profile from.
    /// Asking anyway spends a request against a shared limit to be told nothing.
    @Test("A cold-start profile is not asked for recommendations")
    func skipsColdStart() async throws {
        let library = StubLibrary(
            status: try Fixture.decoder().decode(
                RecommendationStatus.self,
                from: Data(#"{"cold_start":true,"library_count":2}"#.utf8)
            )
        )
        let model = await StackModel(
            repository: SilentRepository(), shelf: try makeShelf(), library: library
        )
        await model.loadIfNeeded()

        #expect(library.requestedPages.isEmpty)
        #expect(await model.source != .yourProfile)
    }

    /// A skip used to hide one series and teach the recommender nothing.
    @Test("Skips are sent back as exclusions on the next page")
    func skipsBecomeExclusions() async throws {
        let library = StubLibrary(
            status: try Fixture.decoder().decode(
                RecommendationStatus.self,
                from: Data(#"{"cold_start":false}"#.utf8)
            )
        )
        library.pages = [
            [try recommendation(1), try recommendation(2), try recommendation(3)],
            [try recommendation(4), try recommendation(5), try recommendation(6)]
        ]

        let shelf = try makeShelf()
        let model = await StackModel(
            repository: SilentRepository(), shelf: shelf, library: library
        )
        await model.loadIfNeeded()

        // One skip drops the queue to two, which is the refill threshold.
        await model.react(.skipped)

        #expect(library.requestedPages == [1, 2])
        let secondCall = try #require(library.sentExclusions.last)
        #expect(secondCall.contains(1), "a skipped series must be excluded, not just hidden")
    }

    /// A refill starts with two cards still in hand. Replacing the queue threw
    /// those two away unseen — every single time the stack topped up.
    @Test("Refilling adds to the queue instead of discarding what is left")
    func refillAppends() async throws {
        let library = StubLibrary(
            status: try Fixture.decoder().decode(
                RecommendationStatus.self,
                from: Data(#"{"cold_start":false}"#.utf8)
            )
        )
        library.pages = [
            [try recommendation(1), try recommendation(2), try recommendation(3)],
            [try recommendation(4), try recommendation(5)]
        ]

        let model = await StackModel(
            repository: SilentRepository(), shelf: try makeShelf(), library: library
        )
        await model.loadIfNeeded()
        await model.react(.skipped)

        // 2 unseen kept + 2 new, not 2 new alone.
        #expect(await model.queue.map(\.id) == [2, 3, 4, 5])
    }

    /// The recommender explains each pick. Showing that is the difference
    /// between "trust me" and an answer.
    @Test("A card carries the recommender's own reason, never an invented one")
    func showsReason() async throws {
        let library = StubLibrary(
            status: try Fixture.decoder().decode(
                RecommendationStatus.self,
                from: Data(#"{"cold_start":false}"#.utf8)
            )
        )
        library.pages = [[try recommendation(1, tags: ["Time Rewind", "Time Travel"])]]

        let model = await StackModel(
            repository: SilentRepository(), shelf: try makeShelf(), library: library
        )
        await model.loadIfNeeded()

        #expect(await model.currentReason == "Because you read Time Rewind and Time Travel")
    }

    /// The tags come from the reader's own library, not from the recommended
    /// series, so a card well inside a safe-and-suggestive setting was
    /// captioned "Because you read BDSM and Cunnilingus" on device. That is a
    /// reading history printed on a phone screen in public.
    @Test("A tag the reader has not opted into seeing is not named")
    func hidesExplicitTagNames() async throws {
        let library = StubLibrary(
            status: try Fixture.decoder().decode(
                RecommendationStatus.self,
                from: Data(#"{"cold_start":false}"#.utf8)
            )
        )
        library.pages = [[try recommendation(1, tags: ["Explicit Tag", "Boxing"])]]
        // The stub numbers every tag id 1, so hiding 1 hides both.
        library.hiddenTags = [1]

        let model = await StackModel(
            repository: SilentRepository(), shelf: try makeShelf(), library: library
        )
        await model.loadIfNeeded()

        #expect(await model.currentReason == nil)
        // The card itself is unaffected: the series was within the filter, only
        // the explanation is withheld.
        #expect(await model.queue.count == 1)
    }

    /// A failed lookup must not read as "nothing is explicit".
    @Test("An unknown answer withholds the reason rather than risking it")
    func unknownTagsWithholdReason() async throws {
        let library = StubLibrary(
            status: try Fixture.decoder().decode(
                RecommendationStatus.self,
                from: Data(#"{"cold_start":false}"#.utf8)
            )
        )
        library.pages = [[try recommendation(1, tags: ["Time Rewind", "Revenge"])]]
        library.hiddenTags = nil

        let model = await StackModel(
            repository: SilentRepository(), shelf: try makeShelf(), library: library
        )
        await model.loadIfNeeded()

        #expect(await model.currentReason == nil)
        #expect(await model.queue.count == 1)
    }

    /// Half a reason is still a reason: hidden tags are dropped, not replaced,
    /// and what is left is still shown.
    @Test("A partly hidden reason keeps the tags that are allowed")
    func partiallyHiddenReason() throws {
        let reason = try Fixture.decoder().decode(
            PersonalRecommendation.Reason.self,
            from: Data("""
            {"reason_type":"similar_to",
             "top_tags":[{"id":9,"name":"Explicit Tag","weight":"core"},
                         {"id":4,"name":"Boxing","weight":"core"}]}
            """.utf8)
        )

        #expect(reason.summary(hiding: [9]) == "Because you read Boxing")
        #expect(reason.summary(hiding: [9, 4]) == nil)
        #expect(reason.summary(hiding: []) == "Because you read Explicit Tag and Boxing")
    }

    /// A recommendation with no reason gets no caption rather than a filler one.
    @Test("No reason from the API means no reason shown")
    func noInventedReason() async throws {
        let library = StubLibrary(
            status: try Fixture.decoder().decode(
                RecommendationStatus.self,
                from: Data(#"{"cold_start":false}"#.utf8)
            )
        )
        library.pages = [[try recommendation(1)]]

        let model = await StackModel(
            repository: SilentRepository(), shelf: try makeShelf(), library: library
        )
        await model.loadIfNeeded()

        #expect(await model.currentReason == nil)
    }
}

/// A request that carries the reader's identity must not be written to the
/// shared on-disk URL cache, whatever its path says.
@Suite("Identity never reaches the disk cache", .serialized)
struct IdentityCachingTests {
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

    /// `/v1/series/mix` is public by path, so the path-prefix rule did not
    /// cover it. Once it carries `exclude_user_library` the URL holds a
    /// 32-character account id, and the URL is the cache key.
    @Test("A blend carrying the reader's id is not cached to disk")
    func blendWithIdentityIsNotCached() async throws {
        URLProtocolStub.setHandler { [payload = emptyPayload] _ in .respond(.init(body: payload)) }
        defer { URLProtocolStub.reset() }

        let repository = try makeRepository()
        await repository.updateLibraryExclusion(userID: String(repeating: "e", count: 32))
        _ = await repository.feed(.mix(seeds: [1]), forceRefresh: true)

        let request = try #require(URLProtocolStub.requests.first)
        #expect(request.cachePolicy == .reloadIgnoringLocalAndRemoteCacheData)
    }

    /// Control: an ordinary public request is still cacheable, or the 256MB
    /// cover cache would be pointless.
    @Test("An anonymous request is still cacheable")
    func anonymousRequestIsCacheable() async throws {
        URLProtocolStub.setHandler { [payload = emptyPayload] _ in .respond(.init(body: payload)) }
        defer { URLProtocolStub.reset() }

        let repository = try makeRepository()
        _ = await repository.feed(.rising, forceRefresh: true)

        let request = try #require(URLProtocolStub.requests.first)
        #expect(request.cachePolicy != .reloadIgnoringLocalAndRemoteCacheData)
    }
}
