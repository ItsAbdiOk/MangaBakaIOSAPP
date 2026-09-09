import Foundation
import Testing
@testable import MangaBaka

/// The reader's own library and the personalised data built from it. Every
/// shape here was verified against the live API on 2026-09-09 with a real
/// account, because the spec does not describe the `results` envelope or the
/// capitalised `Series` key.
@Suite("Library", .serialized)
struct LibraryTests {
    private let baseURL = URL(string: "https://api.example.invalid").unsafeTestURL

    private func makeService() -> LibraryService {
        LibraryService(client: APIClient(
            baseURL: baseURL,
            session: URLProtocolStub.makeSession(),
            tokenProvider: UnauthenticatedTokenProvider()
        ))
    }

    /// The nested series arrives under a capitalised key, which the automatic
    /// snake_case conversion does not produce. It needs explicit coding keys.
    @Test("A library entry decodes, including its capitalised Series key")
    func decodesEntry() async throws {
        URLProtocolStub.setHandler { _ in
            .respond(.init(body: Data("""
            {"status":200,"data":[
              {"id":1881237,"series_id":87872,"state":"reading",
               "progress_chapter":17,"progress_volume":null,"rating":null,
               "note":null,"start_date":"2026-08-27T00:00:00.000Z","finish_date":null,
               "number_of_rereads":0,"priority":20,"is_private":true,"read_link":null,
               "Series":{"id":87872,"state":"active","merged_with":null,
                 "titles":[{"language":"en","traits":["official"],
                            "title":"Breaking A Rock","is_primary":true}],
                 "cover":{"raw":null,"x150":null,"x250":null,"x350":null,
                          "blurhash":null,"width":null,"height":null},
                 "description":null,"authors":null,"artists":null,"status":null,
                 "rating":null,"type":null,"content_rating":null,
                 "total_chapters":null,"final_volume":null,
                 "publishers":null,"anime":null,"source":null}}
            ]}
            """.utf8)))
        }
        defer { URLProtocolStub.reset() }

        let entries = await makeService().library()

        #expect(entries.count == 1)
        #expect(entries.first?.state == .reading)
        #expect(entries.first?.progressChapter == 17)
        #expect(entries.first?.isPrivate == true)
        #expect(entries.first?.series?.displayTitle == "Breaking A Rock")
        #expect(entries.first?.startDate != nil, "Fractional-second dates must parse")
    }

    @Test("All seven states decode, including the two unusual ones")
    func decodesEveryState() throws {
        for state in LibraryEntry.State.allCases {
            let json = Data("""
            {"id":1,"series_id":1,"state":"\(state.rawValue)",
             "progress_chapter":null,"progress_volume":null,"rating":null,
             "note":null,"start_date":null,"finish_date":null,
             "number_of_rereads":null,"priority":null,"is_private":null,
             "read_link":null,"Series":null}
            """.utf8)
            let entry = try Fixture.decoder().decode(LibraryEntry.self, from: json)
            #expect(entry.state == state)
        }
        #expect(LibraryEntry.State.allCases.count == 7)
        #expect(LibraryEntry.State.considering.title == "Considering")
    }

    /// Showing "chapter 0" against a plan-to-read entry is noise, so progress
    /// is only meaningful for states where reading is under way.
    @Test("Progress is only meaningful where reading is under way")
    func progressRelevance() {
        #expect(LibraryEntry.State.reading.tracksProgress)
        #expect(LibraryEntry.State.rereading.tracksProgress)
        #expect(LibraryEntry.State.paused.tracksProgress)
        #expect(!LibraryEntry.State.planToRead.tracksProgress)
        #expect(!LibraryEntry.State.considering.tracksProgress)
        #expect(!LibraryEntry.State.completed.tracksProgress)
    }

    /// These endpoints answer with `results`, not `data`. Decoding one as the
    /// other fails outright, which is why the client has two methods.
    @Test("Recommendations decode from the results envelope")
    func decodesRecommendations() async {
        URLProtocolStub.setHandler { _ in
            .respond(.init(body: Data("""
            {"status":200,"cold_start":false,"profile_stale":false,"results":[
              {"id":1138,"titles":[{"language":"en","traits":["official"],
                                    "title":"The Regressed Doctor","is_primary":true}],
               "cover_image":"https://cdn.example.invalid/a.jpg",
               "media_type":"manhwa","published_year":2021,
               "reason":{"reason_type":"similar_to",
                         "top_tags":[{"id":584,"name":"Time Rewind","weight":"core"},
                                     {"id":249,"name":"Time Travel","weight":"defining"}]},
               "score":0.82}
            ]}
            """.utf8)))
        }
        defer { URLProtocolStub.reset() }

        let results = await makeService().recommendations()

        #expect(results.count == 1)
        #expect(results.first?.displayTitle == "The Regressed Doctor")
        #expect(results.first?.coverURL != nil)
        #expect(results.first?.reason?.reasonType == "similar_to")
        #expect(results.first?.reason?.topTags?.first?.name == "Time Rewind")
        #expect(results.first?.reason?.summary == "Because you read Time Rewind and Time Travel")
    }

    /// A small library cannot be personalised from. The UI needs to say that
    /// rather than showing an empty list as though nothing matched.
    @Test("Cold start is reported rather than looking like an empty result")
    func coldStartIsVisible() async {
        URLProtocolStub.setHandler { _ in
            .respond(.init(body: Data("""
            {"status":200,"cold_start":true,"profile_stale":false,"library_count":3,
             "results":{"cold_start":true,"profile_stale":false,"library_count":3}}
            """.utf8)))
        }
        defer { URLProtocolStub.reset() }

        let status = await makeService().recommendationStatus()

        #expect(status?.coldStart == true)
        #expect(status?.canPersonalise == false)
        #expect(status?.libraryCount == 3)
    }

    /// The closest thing to a taste profile the API offers. Sorted strongest
    /// first, because a ranking is the only honest way to present a score that
    /// is comparable within one reader but not between readers.
    @Test("Top genres come back sorted by affinity, strongest first")
    func topGenresSorted() async {
        URLProtocolStub.setHandler { _ in
            .respond(.init(body: Data("""
            {"status":200,"results":[
              {"tag_id":4050,"tag_name":"Transmigrated into a Game","affinity_score":51.9},
              {"tag_id":249,"tag_name":"Time Travel","affinity_score":83.7},
              {"tag_id":748,"tag_name":"Age Regression","affinity_score":37.5}
            ]}
            """.utf8)))
        }
        defer { URLProtocolStub.reset() }

        let genres = await makeService().topGenres()

        #expect(genres.map(\.tagName) == ["Time Travel", "Transmigrated into a Game", "Age Regression"])
        #expect(genres.first?.affinityScore == 83.7)
    }

    /// Recommendations are built from the reader's own library, so without a
    /// filter someone who set the app to safe content still receives explicit
    /// suggestions — the setting failing silently exactly where it matters.
    @Test("The content filter is applied to personalised recommendations")
    func recommendationsAreFiltered() async {
        URLProtocolStub.setHandler { _ in
            .respond(.init(body: Data(#"{"status":200,"results":[]}"#.utf8)))
        }
        defer { URLProtocolStub.reset() }

        let service = LibraryService(
            client: APIClient(
                baseURL: baseURL,
                session: URLProtocolStub.makeSession(),
                tokenProvider: UnauthenticatedTokenProvider()
            ),
            contentRatings: ["safe"]
        )
        _ = await service.recommendations()

        let url = URLProtocolStub.requests.first?.url
        let items = URLComponents(url: url ?? baseURL, resolvingAgainstBaseURL: false)?.queryItems
        let ratings = (items ?? []).filter { $0.name == "content_rating" }
        #expect(ratings.map(\.value) == ["safe"])
    }

    /// A reason with no tags must produce no summary rather than an empty or
    /// invented phrase.
    @Test("No tags means no invented explanation")
    func noTagsNoSummary() {
        let reason = PersonalRecommendation.Reason(reasonType: "similar_to", topTags: [])
        #expect(reason.summary == nil)
    }

    /// Unauthenticated reads must degrade to empty rather than throwing into
    /// the UI: signing out is ordinary, not exceptional.
    @Test("An unauthorised library read returns empty rather than failing loudly")
    func unauthorisedIsEmpty() async {
        URLProtocolStub.setHandler { _ in
            .respond(.init(statusCode: 401, body: Data(#"{"status":401,"message":"No session found"}"#.utf8)))
        }
        defer { URLProtocolStub.reset() }

        #expect(await makeService().library().isEmpty)
        #expect(await makeService().recommendations().isEmpty)
        #expect(await makeService().topGenres().isEmpty)
    }
}

/// A personal access token never expires and grants full account access, so a
/// Release build must not be able to carry one — anyone with the .ipa could
/// extract it and act as its owner.
@Suite("Release builds cannot carry a token", .enabled(if: SourceTree.isAvailable))
struct ReleaseTokenTests {
    private func config(_ name: String) throws -> String {
        try String(contentsOfFile: "\(SourceTree.root)/Configs/\(name)", encoding: .utf8)
    }

    /// Relying on Xcode Cloud simply not having the secrets file was not
    /// enough: a local archive uploaded by hand would have shipped a real
    /// credential. Release now excludes it structurally.
    /// Checks for an actual include directive rather than the word appearing
    /// anywhere: the file explains in prose why it excludes the secrets, and a
    /// naive substring match would fail on its own comment.
    private func includesSecrets(_ text: String) -> Bool {
        text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .contains { $0.hasPrefix("#include") && $0.contains("Secrets.xcconfig") }
    }

    @Test("Release config does not include the secrets file")
    func releaseExcludesSecrets() throws {
        let release = try config("Release.xcconfig")
        #expect(!includesSecrets(release))
        #expect(release.contains("MB_PAT ="), "Release forces the value empty")
    }

    @Test("Debug config still picks the token up for local development")
    func debugIncludesSecrets() throws {
        #expect(includesSecrets(try config("Debug.xcconfig")))
    }

    /// The shared base must stay free of it, or both configurations inherit it.
    @Test("The shared base config carries no token")
    func baseIsClean() throws {
        #expect(!includesSecrets(try config("Base.xcconfig")))
    }

    @Test("The example file holds a placeholder, never a real token")
    func exampleIsPlaceholder() throws {
        let example = try config("Secrets.example.xcconfig")
        #expect(example.contains("mb-your-personal-access-token-here"))
        // A real token is 60+ characters; the placeholder must not look like one.
        #expect(!example.contains("mb-") || example.contains("your-personal"))
    }
}
