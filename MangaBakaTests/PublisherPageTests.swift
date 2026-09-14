import Foundation
import Testing
@testable import MangaBaka

/// A publisher's or studio's page: the record when the directory has one,
/// the series list either way.
@Suite("Publisher page")
struct PublisherPageTests {
    /// Ize Press (21) as `/v1/publishers/21/full` returned it, 2026-09-11.
    private let izePress = Data(#"""
    {"id": 21, "type": "imprint", "sub_type": "both", "aliases": null, "parent_id": 18, "name": "Ize Press",
     "languages": ["en"], "country_of_origin": "US", "founded": null, "closed": null,
     "links": [{"type": "news", "link": "https://x.com/izepress", "language": "en"},
               {"type": "news", "link": "https://www.instagram.com/izepress/", "language": "en"}],
     "parent": {"id": 18, "type": "publisher", "name": "Yen Press"},
     "description": null, "note": "Imprint of Yen Press for manhwa books."}
    """#.utf8)

    @Test("The live record decodes, and summarises as one line")
    func decodesAndSummarises() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let detail = try decoder.decode(PublisherDetail.self, from: izePress)
        #expect(detail.summary == "Imprint of Yen Press · United States · Print and digital")
        #expect(detail.links?.count == 2)
        #expect(PublisherView.label(for: try #require(detail.links?.first)) == "x.com")
        #expect(PublisherView.label(for: try #require(detail.links?.last)) == "instagram.com")
    }

    /// `founded`/`closed` are `string|null, format: date` on the wire
    /// (`docs/schemas/mangabaka_openapi.json`, `/v1/publishers/{id}/full`),
    /// not the `Int?`/`Bool?` this used to type them as. Fails without the
    /// fix: `JSONDecoder` throws decoding `"founded":"1997-01-01"` into an
    /// `Int?` — expected to fail with a `DecodingError` before ever reaching
    /// the `#expect`.
    @Test("A closed publisher with a founding date says both, as a year")
    func closedAndFounded() throws {
        let json = Data(
            #"""
            {"id": 5, "name": "Tokyopop", "type": "publisher",
             "founded": "1997-01-01", "closed": "2011-05-01"}
            """#.utf8
        )
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let detail = try decoder.decode(PublisherDetail.self, from: json)
        #expect(detail.summary == "Publisher · Since 1997 · Closed")
    }

    @Test("A publisher with neither date says neither")
    func neitherFoundedNorClosed() throws {
        let json = Data(#"{"id": 18, "name": "Yen Press", "type": "publisher"}"#.utf8)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let detail = try decoder.decode(PublisherDetail.self, from: json)
        #expect(detail.summary == "Publisher")
    }

    /// The series' Publishers row names several; the sheet labels each with
    /// its role so "REDICE STUDIO · Original" is told from "Manta · English".
    /// Both orders are ones the API sorts by (`sort_by=latest` checked live
    /// on REDICE STUDIO, 2026-09-11: ids descending, the newest entries).
    @Test("The page offers popularity and newest, as the API spells them")
    func orders() {
        #expect(PublisherView.Order.allCases.map(\.rawValue) == ["popularity_asc", "latest"])
        #expect(SortOrder.label(for: "latest") != nil)
        #expect(SortOrder.label(for: "popularity_asc") != nil)
        // The rank runs the other way; the app once sent desc everywhere
        // and every "Popularity" list led with the least-rated series.
        #expect(SortOrder.label(for: "popularity_desc") == nil)
    }

    /// `staff=` is the API's creator filter: Togashi answers 16 series, all
    /// his (live, 2026-09-11). The same page serves both, by search key.
    @Test("A creator page searches by staff; a publisher page by publisher")
    func kinds() {
        var byStaff = SearchQuery()
        byStaff.staff = "Yoshihiro Togashi"
        #expect(byStaff.queryItems.contains(URLQueryItem(name: "staff", value: "Yoshihiro Togashi")))
        #expect(!byStaff.isEmpty)
        #expect(byStaff.activeFilterCount == 1)
    }

    /// The credits rows name people the API repeats — an author who is also
    /// the artist — once each.
    @Test("The credits rows' creators are trimmed and distinct")
    @MainActor
    func creators() {
        let series = SeriesFactory.make(
            id: 1, authors: ["Chu-Gong ", "Chu-Gong"], artists: ["Seong-Rak Jang", "DUBU"]
        )
        let credits = DetailCredits(series: series)
        // Different artists, so the author row is "Story", not "Story & art".
        let story = credits.rows.first { $0.id == "Story" }
        let art = credits.rows.first { $0.id == "Art" }
        #expect(story.map(credits.creators(for:)) == ["Chu-Gong"])
        #expect(art.map(credits.creators(for:)) == ["Seong-Rak Jang", "DUBU"])
    }

    @Test("The choice sheet labels a publisher with its role")
    func choiceLabel() {
        #expect(DetailCredits.choiceLabel(.init(name: "REDICE STUDIO", type: "Original", note: nil))
                == "REDICE STUDIO · Original")
        #expect(DetailCredits.choiceLabel(.init(name: "Manta", type: nil, note: nil)) == "Manta")
    }
}

@Suite("A publisher page is reachable", .enabled(if: SourceTree.isAvailable))
struct PublisherWiringTests {
    /// The list comes from the series search, which knows studios the
    /// directory does not: REDICE STUDIO is 60 series there and absent here.
    @Test("The page lists series from search, and the credits row opens it")
    func wiring() throws {
        let view = try SourceTree.read("MangaBaka/Features/Detail/PublisherView.swift")
        // One page, two search keys: `publisher=` for a studio, `staff=` for a
        // person. The publisher-only directory lookup is skipped for a creator.
        #expect(view.contains("case .publisher: query.publisher = name"))
        #expect(view.contains("case .author: query.staff = name"))
        #expect(view.contains("if kind == .publisher, detail == nil,"))
        #expect(view.contains("query.sort = order.rawValue"))
        // The header's total comes from the search response itself; the
        // count endpoint is the fallback, not a second request per load —
        // see `PublisherLoadRequestTests` for the behaviour (F9).
        // Gap 57: this used to be `Text((total ?? series.count).formatted())`
        // unconditionally — `series.count` is the *page* size, and that is
        // exactly what printed "100" for a publisher with thousands. See
        // `PublisherHeaderCountTests` for the fixed decision itself.
        #expect(view.contains("Self.headerCount(total: total, seriesCount: series.count, hasMore: hasMore)"))
        #expect(view.contains("hasMore = result.hasMore"))
        // Guarded, not bare: `.task(id: order) { await load() }` re-ran on
        // every pop-back (F10). The guard's rule is `needsLoad`, tested below.
        #expect(view.contains(".task(id: order) {"))
        #expect(view.contains("guard Self.needsLoad(loadedOrder: loadedOrder, order: order,"))
        let credits = try SourceTree.read("MangaBaka/Features/Detail/DetailCredits.swift")
        #expect(credits.contains("onOpenPublisher(publishers[0].name.trimmingCharacters(in: .whitespaces))"))
        let root = try SourceTree.read("MangaBaka/App/RootView+Session.swift")
        #expect(root.contains(".navigationDestination(item: $openPublisher)"))
    }
}

/// Gap 56/57/58 (`FAILURES-SUMMARY.md` §6, batch 2): the publisher page used
/// to show a bare sentence for any failure, print the page size as the total
/// when the count endpoint failed, and let `.refreshable` and
/// `.task(id: order)` interleave their answers.
@Suite("The publisher page tells a failure apart from an empty answer")
struct PublisherScreenStateTests {
    @Test("A failed first page with nothing to fall back on is .failed")
    func failedWithNothingToShow() {
        #expect(
            PublisherView.state(series: [], origin: .staleAfter(.offline), isLoading: false)
                == .failed(.offline)
        )
    }

    @Test("Stale content that survived the failure is shown as .list, not .failed")
    func staleContentIsShown() {
        let series = SeriesFactory.make(id: 1)
        #expect(
            PublisherView.state(series: [series], origin: .staleAfter(.offline), isLoading: false) == .list
        )
    }

    @Test("A genuinely empty answer is .empty, not .failed")
    func emptyIsNotFailed() {
        #expect(PublisherView.state(series: [], origin: .network, isLoading: false) == .empty)
    }

    @Test("Loading wins while nothing has landed yet")
    func loadingWins() {
        #expect(PublisherView.state(series: [], origin: .network, isLoading: true) == .loading)
    }
}

@Suite("A publisher page can be followed", .enabled(if: SourceTree.isAvailable))
struct PublisherFollowWiringTests {
    /// A plain toggle, not `ConfirmDestructive`: unfollowing is reversible in
    /// one tap either way, unlike the destructive actions that pattern gates.
    @Test("The follow button toggles the right kind and never confirms an unfollow")
    func wiring() throws {
        let view = try SourceTree.read("MangaBaka/Features/Detail/PublisherView.swift")
        #expect(view.contains("follows.isFollowing(name, kind: followKind)"))
        #expect(view.contains("follows.follow(name, kind: followKind)"))
        #expect(view.contains("follows.unfollow(name, kind: followKind)"))
        #expect(!view.contains("ConfirmDestructive"))
    }
}

@Suite("The publisher header count is never the page size")
struct PublisherHeaderCountTests {
    @Test("The real total is shown when the count endpoint answered")
    func realTotalShown() {
        #expect(PublisherView.headerCount(total: 4_231, seriesCount: 100, hasMore: true) == 4_231)
    }

    /// The exact bug this replaces: falling back to the page's own count
    /// prints "100" for a publisher with thousands of series.
    @Test("An unknown total with more pages left is hidden, not guessed")
    func unknownTotalWithMoreHidden() {
        #expect(PublisherView.headerCount(total: nil, seriesCount: 100, hasMore: true) == nil)
    }

    @Test("An unknown total with every page in is the real count")
    func unknownTotalCompleteIsAccurate() {
        #expect(PublisherView.headerCount(total: nil, seriesCount: 42, hasMore: false) == 42)
    }
}

/// Counts what the publisher page asks the repository for, and answers with
/// or without the total the live search response carries.
private final class CountingPublisherRepository: StubRepositoryBase, @unchecked Sendable {
    private(set) var searchCalls = 0
    private(set) var countCalls = 0
    /// What `/v2/series/search` answers as `pagination.count` — 1,265 for
    /// `publisher=Seven Seas` live on 2026-09-10. Nil simulates a cached or
    /// failed page, which carries no pagination block.
    var total: Int? = 1_265

    override func search(_ query: SearchQuery) async -> FeedResult {
        searchCalls += 1
        return FeedResult(series: [SeriesFactory.make(id: 1)], origin: .network, hasMore: true, total: total)
    }

    override func count(_ query: SearchQuery) async -> Int? {
        countCalls += 1
        return 1_265
    }
}

/// Screens F9 (2026-09-14): `load()` ran `search` and `count` in parallel —
/// two requests from the same 30/min window for a number the first already
/// carried. E F1 fixed this on Search a day earlier; the source pin in
/// `PublisherWiringTests` used to assert the duplicate.
///
/// `load()` is driven on an unhosted view: its `@State` writes do not
/// persist off-screen (SwiftUI logs a warning, nothing more), but the
/// repository counts what was asked, which is the whole assertion.
@Suite("The publisher page spends one request per load")
@MainActor
struct PublisherLoadRequestTests {
    private func catalogue() -> CatalogueService {
        CatalogueService(client: APIClient(
            baseURL: URL(string: "https://api.example.invalid").unsafeTestURL,
            tokenProvider: UnauthenticatedTokenProvider()
        ))
    }

    /// `.author` so the directory lookup, which is publisher-only, is not
    /// reached — it would go to the network. Expected to fail before the fix
    /// with: `repository.countCalls == 0` → `1`.
    @Test("A search response that carries the total is not counted again")
    func totalFromSearchIsNotCountedAgain() async {
        let repository = CountingPublisherRepository()
        let view = PublisherView(
            name: "REDICE STUDIO", kind: .author, catalogue: catalogue(),
            repository: repository, path: .constant([])
        )

        await view.load()

        #expect(repository.searchCalls == 1)
        #expect(repository.countCalls == 0)
    }

    /// The control, and the fallback: a response with no pagination block
    /// still gets its header number from the count endpoint (gap 57 must
    /// not come back as a hidden count).
    @Test("A search response without a total falls back to one count request")
    func missingTotalIsCounted() async {
        let repository = CountingPublisherRepository()
        repository.total = nil
        let view = PublisherView(
            name: "REDICE STUDIO", kind: .author, catalogue: catalogue(),
            repository: repository, path: .constant([])
        )

        await view.load()

        #expect(repository.searchCalls == 1)
        #expect(repository.countCalls == 1)
    }
}

/// The two pure decisions behind F10 and F27.
@Suite("The publisher page's reload and paging rules")
struct PublisherPagingRuleTests {
    /// F10: `.task(id: order)` fires on every re-appearance; only an order
    /// change, the first appearance, or an empty grid is a load. Expected to
    /// fail before the fix with: no `needsLoad` existed — the task called
    /// `load()` unconditionally.
    @Test("A re-appearance with the grid answering the same order does not reload")
    func reappearanceDoesNotReload() {
        typealias Rule = PublisherView
        #expect(Rule.needsLoad(loadedOrder: .popular, order: .popular, seriesIsEmpty: false) == false)
        #expect(Rule.needsLoad(loadedOrder: nil, order: .popular, seriesIsEmpty: true), "First appearance")
        #expect(Rule.needsLoad(loadedOrder: .popular, order: .newest, seriesIsEmpty: false), "Order changed")
        #expect(
            PublisherView.needsLoad(loadedOrder: .popular, order: .popular, seriesIsEmpty: true),
            "A load cancelled or failed on the way out is asked again"
        )
    }

    /// F27: `page += 1` ran before the request, so a failed page 2 left
    /// `page` at 2 and the retry fetched page 3. Expected to fail before the
    /// fix with: no `nextPage` existed — the advance was unconditional.
    @Test("A failed page is asked for again, not skipped")
    func failedPageIsNotSkipped() {
        let failed = FeedResult(series: [], origin: .staleAfter(.offline), hasMore: true)
        #expect(PublisherView.nextPage(after: 1, result: failed) == 1)
        let landed = FeedResult(series: [SeriesFactory.make(id: 2)], origin: .network, hasMore: true)
        #expect(PublisherView.nextPage(after: 1, result: landed) == 2)
        // A page that landed with nothing new still advances: the API said
        // it was a page, and asking for it again would loop.
        let empty = FeedResult(series: [], origin: .network, hasMore: true)
        #expect(PublisherView.nextPage(after: 3, result: empty) == 4)
    }
}
