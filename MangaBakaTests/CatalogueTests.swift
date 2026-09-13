import Foundation
import Testing
@testable import MangaBaka

@Suite("Catalogue", .serialized)
struct CatalogueTests {
    private let baseURL = URL(string: "https://api.example.invalid").unsafeTestURL

    private func makeService() -> CatalogueService {
        CatalogueService(client: APIClient(
            baseURL: baseURL,
            session: URLProtocolStub.makeSession(),
            tokenProvider: UnauthenticatedTokenProvider()
        ))
    }

    /// Captured 2026-09-13 22:33 UTC: `GET https://api.mangabaka.org/v1/genres`
    /// (`Fixtures/genres-2026-09-13.json`). Finding: the endpoint rejects any
    /// query argument at all — `?limit=5` answers 400 "This endpoint do not
    /// accept any query arguments, please remove them and try again" — so the
    /// fixture is the live, unfiltered 46-row list, not a trimmed page. The
    /// old hand-built payload only ever exercised 2 of those 46 rows.
    @Test("Genres decode from their live label/value pairs")
    func decodesGenres() async throws {
        let body = try Fixture.data("genres-2026-09-13")
        URLProtocolStub.setHandler { _ in .respond(.init(body: body)) }
        defer { URLProtocolStub.reset() }

        let genres = await makeService().genres().value ?? []
        #expect(genres.count == 46)
        #expect(genres.first == Genre(label: "Action", value: "action"))
        #expect(genres.last == Genre(label: "Yuri", value: "yuri"))
    }

    /// Genres and tags change rarely and the tag list is large. Re-fetching
    /// while browsing would spend a rate limit shared with strangers.
    @Test("The catalogue is fetched once, not per screen")
    func cachesAfterFirstFetch() async {
        URLProtocolStub.setHandler { _ in
            .respond(.init(body: Data(#"{"status":200,"data":[{"label":"Action","value":"action"}]}"#.utf8)))
        }
        defer { URLProtocolStub.reset() }

        let service = makeService()
        let first = await service.genres().value ?? []
        let second = await service.genres().value ?? []

        #expect(URLProtocolStub.requests.count == 1)
        // One request is only a saving if the second answer is the first one.
        // A cache that stored the response and returned [] passed this before.
        #expect(first.map(\.label) == ["Action"])
        #expect(second == first)
    }

    /// Shaped on the live `/v1/tags?limit=500` page captured 2026-09-13
    /// (`Fixtures/tags-page1.json`): a root is `level: 1`, not 0, and
    /// `content_rating` is never null on the wire — the 500 live rows were
    /// 496 `safe` and 4 `erotica`. The old hand-written rows said `level: 0`
    /// and `content_rating: null` for a root, and no test had ever noticed
    /// because nothing read `level`. `series_count` and the Boxing/Merged
    /// rows are invented to keep the tree small; the shape is the wire's.
    private let tagPayload = Data("""
    {"status":200,"data":[
      {"id":537,"parent_id":null,"merged_with":null,"name":"Activities",
       "name_path":"Activities","description":"Hobbies and pastimes.","level":1,
       "series_count":9000,"is_genre":false,"is_spoiler":false,"content_rating":"safe"},
      {"id":538,"parent_id":537,"merged_with":null,"name":"Boxing",
       "name_path":"Activities > Sports > Boxing","description":null,"level":3,
       "series_count":120,"is_genre":false,"is_spoiler":false,"content_rating":"safe"},
      {"id":539,"parent_id":537,"merged_with":700,"name":"Merged Away",
       "name_path":"Activities > Merged Away","description":null,"level":2,
       "series_count":5,"is_genre":false,"is_spoiler":false,"content_rating":"safe"}
    ]}
    """.utf8)

    @Test("Tags decode with their hierarchy intact")
    func decodesTagTree() async {
        URLProtocolStub.setHandler { [tagPayload] _ in .respond(.init(body: tagPayload)) }
        defer { URLProtocolStub.reset() }

        let tags = await makeService().tags().value ?? []

        let root = tags.first { $0.id == 537 }
        #expect(root?.isRoot == true)
        // The wire's root level is 1 (live 2026-09-13, all 4 roots on the
        // first page; the bundled file's 17 roots agree). Fails on the old
        // fixture, which said 0: expected to fail with `root?.level == 1`.
        #expect(root?.level == 1)
        #expect(root?.contentRating == "safe")
        let leaf = tags.first { $0.id == 538 }
        #expect(leaf?.parentId == 537)
        #expect(leaf?.namePath == "Activities > Sports > Boxing")
    }

    /// A merged tag points at a survivor. Showing it would send the reader to
    /// a dead end, and linking to it would query a tag nothing uses.
    @Test("Merged tags are excluded")
    func excludesMergedTags() async {
        URLProtocolStub.setHandler { [tagPayload] _ in .respond(.init(body: tagPayload)) }
        defer { URLProtocolStub.reset() }

        let tags = await makeService().tags().value ?? []
        #expect(!tags.contains { $0.id == 539 })
        #expect(tags.count == 2)
    }

    /// A tag on three series does not deserve the same row as one on nine
    /// thousand, so the list is ordered by how much it is actually used.
    @Test("Tags are ordered by how many series carry them")
    func ordersByUsage() async {
        URLProtocolStub.setHandler { [tagPayload] _ in .respond(.init(body: tagPayload)) }
        defer { URLProtocolStub.reset() }

        let tags = await makeService().tags().value ?? []
        #expect(tags.map(\.seriesCount) == [9000, 120])
    }

    @Test("Children are found by parent, for walking the tree")
    func findsChildren() async {
        URLProtocolStub.setHandler { [tagPayload] _ in .respond(.init(body: tagPayload)) }
        defer { URLProtocolStub.reset() }

        let service = makeService()
        #expect(await service.children(of: nil).map(\.id) == [537])
        #expect(await service.children(of: 537).map(\.id) == [538])
    }

    /// Finding: `searchTags` — the method the tag pickers actually call for
    /// `?q=` — had never been decoded against a captured `/v1/tags?q=` page;
    /// only the `?limit=` shape (`tagPayload` above) had a fixture. Captured
    /// 2026-09-13 22:33 UTC: `GET https://api.mangabaka.org/v1/tags?q=isekai&limit=5`
    /// (`Fixtures/tags-search-2026-09-13.json`). The five rows are already in
    /// series-count order on the wire, so this also confirms the sort is a
    /// no-op here rather than masking a bug the fixture happens not to show.
    @Test("A tag search decodes the live q= shape, ordered by series count")
    func searchTagsDecodesRealShape() async throws {
        let body = try Fixture.data("tags-search-2026-09-13")
        URLProtocolStub.setHandler { _ in .respond(.init(body: body)) }
        defer { URLProtocolStub.reset() }

        let found = await makeService().searchTags("isekai", limit: 5)
        #expect(found?.map(\.id) == [94, 2879, 3801, 5454, 5825])
        #expect(found?.first?.namePath == "Settings > Fantasy > Isekai")
        #expect(found?.first?.level == 3, "a wire root is level 1; Isekai sits three deep under it")
    }

    /// `founded`/`closed` are `string|null, format: date` on the wire, not the
    /// `Int?`/`Bool?` this used to type them as — verified live 2026-09-13,
    /// `/v1/publishers/search?q=Kodansha` sends `"founded": "2008-07-01"` on
    /// Kodansha USA. Fails without the fix: decoding `"founded":"2008-07-01"`
    /// into an `Int?` throws, `[PublisherRecord]` is one array under `try?`
    /// (`CatalogueService.swift:130`), and `searchPublishers` returns nil —
    /// expected to fail with: `publishers?.first?.name == "A-1 Pictures (English)"`,
    /// since `publishers` itself would be nil.
    @Test("Publishers decode a founding date, and a closing one")
    func decodesPublishers() async {
        URLProtocolStub.setHandler { _ in
            .respond(.init(body: Data("""
            {"status":200,"data":[
              {"id":84,"type":"publisher","sub_type":"both","aliases":null,
               "parent_id":null,"name":"A-1 Pictures (English)","languages":null,
               "country_of_origin":"JP","founded":"2008-07-01","closed":null},
              {"id":5,"type":"publisher","sub_type":"both","aliases":null,
               "parent_id":null,"name":"Tokyopop","languages":null,
               "country_of_origin":"US","founded":"1997-01-01","closed":"2011-05-01"}
            ]}
            """.utf8)))
        }
        defer { URLProtocolStub.reset() }

        let publishers = await makeService().searchPublishers("a-1")
        #expect(publishers?.first?.name == "A-1 Pictures (English)")
        #expect(publishers?.first?.countryOfOrigin == "JP")
        #expect(publishers?.first?.founded == "2008-07-01")
        #expect(publishers?.first?.closed == nil)
        #expect(publishers?.last?.closed == "2011-05-01")
    }

    /// `q=Ize Press (Yen Press)` answers `[]` live (measured 2026-09-13) — the
    /// directory does not index the composite string a series' English-print
    /// credit sometimes is. Fails without the fix: `findPublisher` gives up
    /// after that one empty search and returns nil, rather than also trying
    /// "Ize Press" and "Yen Press" on their own.
    @Test("A composite 'imprint (parent)' name is also tried as its two halves")
    func findsPublisherFromCompositeName() async {
        URLProtocolStub.setHandler { request in
            let query = request.url?.query ?? ""
            if query.contains("Yen%20Press") || query.contains("Yen+Press") {
                return .respond(.init(body: Data("""
                {"status":200,"data":[{"id":18,"name":"Yen Press"}]}
                """.utf8)))
            }
            return .respond(.init(body: Data(#"{"status":200,"data":[]}"#.utf8)))
        }
        defer { URLProtocolStub.reset() }

        let found = await makeService().findPublisher(named: "Ize Press (Yen Press)")
        #expect(found?.name == "Yen Press")
    }

    /// `q=Kodansha` answers `["Kodansha USA","Kodansha Manga","Kodansha"]`
    /// live — captured 2026-09-13 22:33 UTC:
    /// `GET https://api.mangabaka.org/v1/publishers/search?q=Kodansha&limit=5`
    /// (`Fixtures/publishers-search-2026-09-13.json`) — the exact match is
    /// third, not first. Fails without the fix: `?? hits.first` picks
    /// "Kodansha USA".
    @Test("An exact name match wins even when it is not the first result")
    func exactMatchBeatsFirstResult() async throws {
        let body = try Fixture.data("publishers-search-2026-09-13")
        URLProtocolStub.setHandler { _ in .respond(.init(body: body)) }
        defer { URLProtocolStub.reset() }

        let found = await makeService().findPublisher(named: "Kodansha")
        #expect(found?.name == "Kodansha")
        // The wire's exact-name row (id 32, JP) carries no founding date,
        // unlike the US imprint the old hand-built payload never modelled.
        #expect(found?.founded == nil)
    }

    /// Same fixture, a name none of its three rows are. Fails without the
    /// fix: `?? hits.first` decorates the page with "Kodansha USA", a
    /// different publisher that merely starts the same way.
    @Test("A name matching nothing in the results is nil, not the first result")
    func noMatchIsNilNotFirstResult() async throws {
        let body = try Fixture.data("publishers-search-2026-09-13")
        URLProtocolStub.setHandler { _ in .respond(.init(body: body)) }
        defer { URLProtocolStub.reset() }

        let found = await makeService().findPublisher(named: "Kodansha Comics")
        #expect(found == nil)
    }

    /// S9: the name is trimmed before it reaches the wire, even though the
    /// server also trims — being explicit here means the app does not depend
    /// on that.
    @Test("A publisher name is trimmed before it is sent")
    func findPublisherTrimsTheName() async {
        URLProtocolStub.setHandler { _ in
            .respond(.init(body: Data(#"{"status":200,"data":[{"id":1,"name":"Seven Seas"}]}"#.utf8)))
        }
        defer { URLProtocolStub.reset() }

        _ = await makeService().findPublisher(named: "  Seven Seas  ")
        let sentQuery = URLProtocolStub.requests.first?.url?.query ?? ""
        #expect(!sentQuery.contains("%20%20") && !sentQuery.contains("++"))
    }

    @Test("A failed catalogue fetch degrades to empty rather than throwing")
    func failureIsEmpty() async {
        URLProtocolStub.setHandler { _ in .fail(URLError(.notConnectedToInternet)) }
        defer { URLProtocolStub.reset() }

        #expect((await makeService().genres().value ?? []).isEmpty)
        #expect((await makeService().tags().value ?? []).isEmpty)
    }

    /// Gap 39/40/41/42 (FAILURES-SUMMARY.md §6, Batch 1): `genres()`/`tags()`
    /// used to answer `[]` on failure with a same-shaped `[]` for "nothing
    /// there", and a `genresFetchFailed`/`tagsFetchFailed` flag nothing read.
    /// `Fetched<[Genre]>`/`Fetched<[Tag]>` carry the distinction directly.
    /// Expected to fail without the fix: `genres()`/`tags()` returned a bare
    /// array with no `.failure` to read.
    @Test("A failed genres/tags fetch carries the error, not just an empty array")
    func fetchFailureIsCarried() async {
        URLProtocolStub.setHandler { _ in .fail(URLError(.notConnectedToInternet)) }
        defer { URLProtocolStub.reset() }

        let service = makeService()
        let genres = await service.genres()
        #expect(genres.value == nil)
        #expect(genres.error == .offline)
        let tags = await service.tags()
        #expect(tags.value == nil)
        #expect(tags.error == .offline)
    }

    @Test("A successful genres/tags fetch reports no failure")
    func fetchSuccessHasNoFailure() async {
        URLProtocolStub.setHandler { _ in
            .respond(.init(body: Data(#"{"status":200,"data":[]}"#.utf8)))
        }
        defer { URLProtocolStub.reset() }

        let service = makeService()
        #expect(await service.genres().error == nil)
        #expect(await service.tags().error == nil)
    }

    /// A failed search is nil, not empty: the screen says so instead of
    /// claiming no publisher has that name.
    @Test("A failed publisher search is distinguishable from no matches")
    func publisherFailureIsNil() async {
        URLProtocolStub.setHandler { _ in .fail(URLError(.networkConnectionLost)) }
        defer { URLProtocolStub.reset() }
        #expect(await makeService().searchPublishers("seven") == nil)
    }

    /// One dropped packet at launch used to cache an empty vocabulary for the
    /// whole process: every Browse screen after it showed no genres and no
    /// tags, and the only way back was to relaunch.
    @Test("A failed fetch is not cached; the next ask tries again")
    func failureIsRetried() async {
        let queue = ResponseQueue()
        URLProtocolStub.setHandler { _ in queue.next() }
        defer { URLProtocolStub.reset() }

        let service = makeService()
        queue.fail = true
        #expect((await service.genres().value ?? []).isEmpty)
        #expect((await service.tags().value ?? []).isEmpty)

        queue.fail = false
        #expect(await service.genres().value?.count == 1, "The retry must reach the network")
        #expect(await service.tags().value?.count == 1)
    }

    /// `TagTaxonomy.bundled()` answers `[]` both when the packaged resource
    /// is missing/corrupt and when it is genuinely empty; `loadFailed` is the
    /// additive signal that tells the two apart. Whatever the test bundle's
    /// `Bundle.main` actually holds, the two must agree: no rows only when
    /// the load itself failed.
    @Test("The bundled taxonomy's empty and failed states agree with each other")
    func bundledTaxonomyReportsFailureConsistently() {
        if TagTaxonomy.bundled().isEmpty {
            #expect(TagTaxonomy.loadFailed)
        } else {
            #expect(!TagTaxonomy.loadFailed)
        }
    }

    /// Switchable between failing and answering, from inside the stub's
    /// `@Sendable` handler.
    private final class ResponseQueue: @unchecked Sendable {
        private let lock = NSLock()
        private var failing = false
        var fail: Bool {
            get { lock.lock(); defer { lock.unlock() }; return failing }
            set { lock.lock(); defer { lock.unlock() }; failing = newValue }
        }

        func next() -> URLProtocolStub.Outcome {
            if fail { return .fail(URLError(.networkConnectionLost)) }
            // The real keys (`V1_Series_Tag`, matching `tagPayload` above):
            // `merged_with`, not `merged_into`; `name_path`, not `full_name`.
            // Every field is optional, so the wrong keys used to decode fine
            // and this retry proved itself against a payload that has never
            // existed on the wire.
            return .respond(.init(body: Data(#"""
            {"status":200,"data":[{"id":1,"name":"Action","label":"Action","value":"action",
             "name_path":"Action","level":0,"parent_id":null,"series_count":10,"merged_with":null}]}
            """#.utf8)))
        }
    }
}

/// Folding the live `/v1/tags` page into the bundled taxonomy.
///
/// The picker used to *replace* the bundled 2,686-row list with whatever the
/// live fetch answered — and `?limit=500` is the first 500 rows in root
/// alphabetical order, which is four of the seventeen roots (live
/// 2026-09-13: Activities, Audience Demographics, Character Archetype,
/// Character Traits). Online, the reader lost Themes, Settings, Relationship
/// and the rest; offline they kept them.
@Suite("Tag taxonomy merge")
struct TagTaxonomyMergeTests {
    private static func tag(
        _ id: Int, _ name: String, path: String? = nil, parent: Int? = nil,
        count: Int = 0, rating: String? = nil
    ) -> MangaBaka.Tag {
        MangaBaka.Tag(
            id: id, name: name, namePath: path ?? name, parentId: parent, level: nil,
            description: nil, seriesCount: count, isGenre: false, isSpoiler: false,
            mergedWith: nil, contentRating: rating
        )
    }

    /// Fails without the fix: `TagTaxonomy.merge` does not exist on HEAD, and
    /// the picker's `tags = live` would leave one root, not two.
    @Test("Bundled roots the live page did not cover survive the merge")
    func keepsUncoveredBundledRoots() {
        let bundled = [
            Self.tag(537, "Activities", count: 0),
            Self.tag(1, "Settings", count: 0),
            Self.tag(94, "Isekai", path: "Settings > Fantasy > Isekai", parent: 2, count: 8_890)
        ]
        let live = [Self.tag(537, "Activities", count: 0, rating: "safe")]

        let merged = TagTaxonomy.merge(bundled: bundled, live: live)

        #expect(merged.filter(\.isRoot).map(\.name).sorted() == ["Activities", "Settings"])
        #expect(merged.contains { $0.id == 94 })
    }

    /// The same idea at the real scale: the 24-row fixture slice over the
    /// bundled file keeps all 17 roots. Skipped, not failed, when the test
    /// host has no bundled taxonomy to read.
    @Test("Seventeen bundled roots stay seventeen after a four-root live page")
    func seventeenRootsAfterFourRootPage() throws {
        let bundled = TagTaxonomy.bundled()
        guard !bundled.isEmpty else { return }
        let page = try Fixture.data("tags-page1")
        let live = try Fixture.decoder().decode(APIEnvelope<[MangaBaka.Tag]>.self, from: page).data ?? []
        #expect(live.filter(\.isRoot).count == 4, "the slice must reproduce the live page's four roots")

        let merged = TagTaxonomy.merge(bundled: bundled, live: live)

        #expect(merged.filter(\.isRoot).count == 17)
        #expect(bundled.filter(\.isRoot).count == 17, "control: the bundled file itself has 17")
    }

    /// Where both have a row, the live one wins — it carries the rating and
    /// today's count, which the bundled row lacks.
    @Test("A live row replaces its bundled twin by id")
    func liveRowWinsById() {
        let bundled = [Self.tag(386, "Futanari", count: 100)]
        let live = [Self.tag(386, "Futanari", count: 1_215, rating: "erotica")]

        let merged = TagTaxonomy.merge(bundled: bundled, live: live)

        #expect(merged.count == 1)
        #expect(merged.first?.seriesCount == 1_215)
        #expect(merged.first?.contentRating == "erotica")
    }
}

/// What the picker withholds, and what it greys out.
///
/// Live 2026-09-13: `tag=Isekai&tag_not=94` answers 0 — picking a tag the
/// reader blocked in Settings sends both and finds nothing, and the empty
/// state then advises loosening a filter the reader cannot see.
@Suite("Tag audience")
struct TagAudienceTests {
    private static func tag(
        _ id: Int, _ name: String, path: String? = nil, rating: String? = nil, spoiler: Bool = false
    ) -> MangaBaka.Tag {
        MangaBaka.Tag(
            id: id, name: name, namePath: path ?? name, parentId: nil, level: nil,
            description: nil, seriesCount: 10, isGenre: false, isSpoiler: spoiler,
            mergedWith: nil, contentRating: rating
        )
    }

    /// Fails without the fix: `TagAudience` does not exist on HEAD; the
    /// picker had no notion of a blocked tag at all.
    @Test("A blocked id is marked blocked, and still shown so the reader sees why")
    func blockedIdIsMarked() {
        let audience = TagAudience(
            allowedRatings: ["safe", "suggestive"], showsSpoilers: false, blockedIds: [94]
        )
        let isekai = Self.tag(94, "Isekai", rating: "safe")
        let regression = Self.tag(1, "Regression", rating: "safe")

        #expect(audience.isBlocked(isekai))
        #expect(!audience.isBlocked(regression))
        #expect(
            audience.isShown(isekai),
            "blocked is greyed, not hidden — hiding it would be the old silent zero"
        )
    }

    @Test("A tag rated above the reader's setting is not offered")
    func ratingAboveSettingIsHidden() {
        let audience = TagAudience(
            allowedRatings: ["safe", "suggestive"], showsSpoilers: false, blockedIds: []
        )
        #expect(!audience.isShown(Self.tag(386, "Futanari", rating: "erotica")))
        #expect(audience.isShown(Self.tag(109, "Nudity", rating: "suggestive")))
        let permissive = TagAudience(
            allowedRatings: ["safe", "suggestive", "erotica"], showsSpoilers: false, blockedIds: []
        )
        #expect(permissive.isShown(Self.tag(386, "Futanari", rating: "erotica")))
    }

    /// Bundled rows carry no rating. Live 2026-09-13, `/v1/tags?q=Sexual
    /// Content&limit=60`: of 60 rows under that root, 37 pornographic, 18
    /// erotica, 2 suggestive, 3 safe — so an unrated row under it is treated
    /// as erotica until the live row says otherwise.
    @Test("An unrated row under Sexual Content is withheld unless erotica is allowed")
    func unratedSexualContentIsWithheld() {
        let audience = TagAudience(
            allowedRatings: ["safe", "suggestive"], showsSpoilers: false, blockedIds: []
        )
        #expect(!audience.isShown(Self.tag(10, "Hentai", path: "Sexual Content > Intensity > Hentai")))
        #expect(
            audience.isShown(Self.tag(94, "Isekai", path: "Settings > Fantasy > Isekai")),
            "control: the rest of the tree is shown unrated"
        )
        let permissive = TagAudience(
            allowedRatings: ["safe", "suggestive", "erotica"], showsSpoilers: false, blockedIds: []
        )
        #expect(permissive.isShown(Self.tag(10, "Hentai", path: "Sexual Content > Intensity > Hentai")))
    }

    @Test("Spoiler tags are withheld by default, as Browse already does")
    func spoilersHiddenByDefault() {
        let audience = TagAudience(allowedRatings: ["safe"], showsSpoilers: false, blockedIds: [])
        #expect(!audience.isShown(Self.tag(1, "Plot Twist", rating: "safe", spoiler: true)))
        let showing = TagAudience(allowedRatings: ["safe"], showsSpoilers: true, blockedIds: [])
        #expect(showing.isShown(Self.tag(1, "Plot Twist", rating: "safe", spoiler: true)))
    }
}

/// C#1: the picker offered "Match all" / "Match any", and "any" set `mode`
/// to nil — which the query never sends, and the API defaults to `and`.
/// Measured 2026-09-13: `tag=Isekai&tag=Regression` answers 164 with
/// `tag_mode=or`, with `tag_mode=and`, and with neither; `tag=isekai` alone
/// is 7,116, so a working OR would be far above 164. The control is dead on
/// both ends, so it is no longer presented.
@Suite("Tag picker match mode", .enabled(if: SourceTree.isAvailable))
struct TagPickerModeTests {
    /// Fails without the fix — expected to fail with:
    /// `!source.contains("Match any")`.
    @Test("The picker no longer offers a Match any control")
    func noMatchAnyControl() throws {
        let source = try SourceTree.read("MangaBaka/Features/Search/TagPickerSheet.swift")
        #expect(!source.contains("\"Match any\""))
        #expect(!source.contains("modeButton("))
    }

    /// Picking a tag settles the mode on the one value the API honours.
    @Test("A pick always writes the and-mode value")
    func pickWritesAnd() {
        #expect(TagPickerSheet.pickedTagMode == "and")
    }
}

/// Whether a tags page is the whole vocabulary or a slice of it.
///
/// Its own suite only because `CatalogueTests` sits at SwiftLint's
/// `type_body_length` ceiling; same stub, same service.
@Suite("Catalogue tag paging", .serialized)
struct CatalogueTagPagingTests {
    private func makeService() -> CatalogueService {
        CatalogueService(client: APIClient(
            baseURL: URL(string: "https://api.example.invalid").unsafeTestURL,
            session: URLProtocolStub.makeSession(),
            tokenProvider: UnauthenticatedTokenProvider()
        ))
    }

    /// One root in the wire's shape (see `CatalogueTests.tagPayload`), and
    /// no `pagination` block at all — as an unpaginated answer would be.
    private static let lastPage = Data("""
    {"status":200,"data":[
      {"id":537,"parent_id":null,"merged_with":null,"name":"Activities",
       "name_path":"Activities","description":null,"level":1,
       "series_count":9000,"is_genre":false,"is_spoiler":false,"content_rating":"safe"}
    ]}
    """.utf8)

    /// `/v1/tags?limit=500` answers 500 of 7,146 rows with `pagination.next`
    /// set (live 2026-09-13, `Fixtures/tags-page1.json` is a 24-row slice of
    /// that page with the pagination block kept verbatim). The service used
    /// to stamp `isPartial: false` on it regardless. Fails without the fix —
    /// expected to fail with: `isPartial == true`.
    @Test("A paginated tags page is reported as partial")
    func pagedTagsArePartial() async throws {
        let page = try Fixture.data("tags-page1")
        URLProtocolStub.setHandler { _ in .respond(.init(body: page)) }
        defer { URLProtocolStub.reset() }

        let fetched = await makeService().tags(limit: 500)
        guard case let .loaded(tags, _, isPartial) = fetched else {
            Issue.record("Expected .loaded, got \(fetched)")
            return
        }
        #expect(isPartial == true)
        // Control: the slice really is the live shape — four roots, all
        // `level: 1`, and the erotica rows carry their rating through.
        #expect(tags.filter(\.isRoot).count == 4)
        #expect(tags.filter(\.isRoot).allSatisfy { $0.level == 1 })
        #expect(tags.first { $0.id == 386 }?.contentRating == "erotica")
    }

    /// The same three-row payload with no `next` is the whole list.
    @Test("A last tags page is not partial")
    func lastTagsPageIsComplete() async {
        URLProtocolStub.setHandler { _ in .respond(.init(body: Self.lastPage)) }
        defer { URLProtocolStub.reset() }

        let fetched = await makeService().tags()
        guard case let .loaded(_, _, isPartial) = fetched else {
            Issue.record("Expected .loaded, got \(fetched)")
            return
        }
        #expect(isPartial == false)
    }

}
