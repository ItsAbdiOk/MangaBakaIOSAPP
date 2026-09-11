import Foundation
import Testing
@testable import MangaBaka

/// Putting the reader's own interests at the front of a series' tag list.
///
/// The point is not the ordering, it is the cap. A series carries up to 116
/// tags and the page shows twelve, so without this the twelve are whichever the
/// API listed first — and a reader who reads fantasy and action can have both
/// sitting behind "+104 more" on a series that is exactly what they like.
@Suite("Tags lead with what the reader likes")
@MainActor
struct TagOrderingTests {
    private let mine: Set<String> = ["fantasy", "action"]

    @Test("Favoured tags move to the front")
    func favouredFirst() {
        let tags = ["Politics", "Dungeon", "Action", "Webtoons", "Fantasy"]
        #expect(
            TagOrdering.favouredFirst(tags, favoured: mine)
                == ["Action", "Fantasy", "Politics", "Dungeon", "Webtoons"]
        )
    }

    /// A stable partition, not a sort. The API leads with the tags most
    /// characteristic of the series, so reshuffling within each group would
    /// trade one meaningful order for an arbitrary one.
    @Test("Order within each group is untouched")
    func stableWithinGroups() {
        let tags = ["Action", "Fantasy", "Politics", "Dungeon"]
        #expect(
            TagOrdering.favouredFirst(tags, favoured: mine)
                == ["Action", "Fantasy", "Politics", "Dungeon"]
        )
    }

    /// The API's casing and the profile's need not agree, and a reader whose
    /// profile says "fantasy" should not miss a tag spelled "Fantasy".
    @Test("Matching ignores case", arguments: ["Fantasy", "fantasy", "FANTASY"])
    func caseInsensitive(_ spelling: String) {
        #expect(TagOrdering.isFavoured(spelling, favoured: mine))
        #expect(TagOrdering.favouredFirst(["Politics", spelling], favoured: mine).first == spelling)
    }

    /// A reader with no account or an empty library has no profile. That is
    /// correct rather than broken: with nothing to learn from, no tag is more
    /// theirs than another, so the API's own order stands untouched.
    @Test("An empty profile changes nothing")
    func emptyProfileIsIdentity() {
        let tags = ["Politics", "Dungeon", "Action"]
        #expect(TagOrdering.favouredFirst(tags, favoured: []) == tags)
    }

    @Test("A series with no matching tags is left alone")
    func noMatches() {
        let tags = ["Politics", "Dungeon"]
        #expect(TagOrdering.favouredFirst(tags, favoured: mine) == tags)
    }

    /// No tag may be dropped or duplicated by the reordering.
    @Test("Every tag survives, exactly once")
    func lossless() {
        let tags = (1...116).map { "Tag \($0)" } + ["Action", "Fantasy"]
        let ordered = TagOrdering.favouredFirst(tags, favoured: mine)
        #expect(ordered.count == tags.count)
        #expect(Set(ordered) == Set(tags))
    }

    /// The whole reason this exists: the reader's tags have to survive the cap.
    @Test("A favoured tag buried at position 100 reaches the visible twelve")
    func survivesTheCap() {
        var tags = (1...99).map { "Filler \($0)" }
        tags.append("Fantasy")
        let view = DetailTags(tags: tags, favoured: mine) { _ in }
        #expect(view.visible.first == "Fantasy")
        #expect(view.visible.count == DetailTags.collapsedLimit)
    }
}

/// The cost, which is the part that decides whether this is worth having.
@Suite("The profile is cheap")
struct TasteProfileCostTests {
    /// An actor, not a lock: `NSLock` is unavailable from an async context and
    /// the counter is read from one.
    private actor Counter {
        private(set) var value = 0
        func increment() { value += 1 }
    }

    private final class CountingLibrary: LibraryProviding, @unchecked Sendable {
        let counter = Counter()

        func recommendationStatus() async -> RecommendationStatus? { nil }
        func recommendations(
            limit: Int, page: Int, excluding: [Int]
        ) async -> [PersonalRecommendation] { [] }
        func library(page: Int, limit: Int) async -> [LibraryEntry] { [] }
        func hiddenTagIDs() async -> Set<Int>? { [] }
        func add(seriesId: Int, state: LibraryEntry.State) async throws(APIError) -> Bool { true }
        func remove(seriesId: Int) async throws(APIError) {}
        func update(seriesId: Int, change: LibraryChange) async throws(APIError) {}

        func topGenres() async -> [TopGenre]? {
            await counter.increment()
            return [
                TopGenre(tagId: 1, tagName: "Fantasy", affinityScore: 90),
                TopGenre(tagId: 2, tagName: "Action", affinityScore: 80)
            ]
        }
    }

    /// One request per launch, not one per series page. Opening twenty series
    /// pages must not cost twenty requests against a rate limit shared with
    /// strangers.
    @Test("The profile is fetched once and reused")
    func fetchedOnce() async {
        let library = CountingLibrary()
        let profile = TasteProfile(library: library)

        _ = await profile.favouredTagNames()
        _ = await profile.favouredTagNames()
        _ = await profile.favouredTagNames()

        #expect(await library.counter.value == 1)
    }

    /// Two series pages opening at once must not both start a request.
    @Test("Concurrent callers share one request")
    func concurrentCallersShare() async {
        let library = CountingLibrary()
        let profile = TasteProfile(library: library)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask { _ = await profile.favouredTagNames() }
            }
        }

        #expect(await library.counter.value == 1)
    }

    @Test("Names are lowercased once, at the source")
    func lowercasedAtSource() async {
        let names = await TasteProfile(library: CountingLibrary()).favouredTagNames()
        #expect(names == ["fantasy", "action"])
    }

    /// One failed request used to be cached as "this reader likes nothing" for
    /// the session: every tag list after it went back to the API's own order.
    @Test("A failed fetch is not cached; the next page asks again")
    func failureIsRetried() async {
        let library = FlakyLibrary()
        let profile = TasteProfile(library: library)

        #expect(await profile.favouredTagNames().isEmpty)
        #expect(await profile.favouredTagNames() == ["fantasy"], "The retry must reach the library")
    }

    /// Fails the first ask and answers the second.
    private final class FlakyLibrary: LibraryProviding, @unchecked Sendable {
        let counter = Counter()

        func recommendationStatus() async -> RecommendationStatus? { nil }
        func recommendations(
            limit: Int, page: Int, excluding: [Int]
        ) async -> [PersonalRecommendation] { [] }
        func library(page: Int, limit: Int) async -> [LibraryEntry] { [] }
        func hiddenTagIDs() async -> Set<Int>? { [] }
        func add(seriesId: Int, state: LibraryEntry.State) async throws(APIError) -> Bool { true }
        func remove(seriesId: Int) async throws(APIError) {}
        func update(seriesId: Int, change: LibraryChange) async throws(APIError) {}

        func topGenres() async -> [TopGenre]? {
            await counter.increment()
            let first = await counter.value == 1
            return first ? nil : [TopGenre(tagId: 1, tagName: "Fantasy", affinityScore: 90)]
        }
    }

    /// A library that changed should be reflected without a relaunch.
    @Test("Invalidating re-fetches")
    func invalidation() async {
        let library = CountingLibrary()
        let profile = TasteProfile(library: library)

        _ = await profile.favouredTagNames()
        await profile.invalidate()
        _ = await profile.favouredTagNames()

        #expect(await library.counter.value == 2)
    }
}
