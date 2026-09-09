import Foundation
import Testing
@testable import MangaBaka

/// The detail screen's onward paths. Each of these shapes was verified against
/// the live API on 2026-09-09; the spec does not describe several of them.
@Suite("Series extras", .serialized)
struct SeriesExtrasTests {
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

    private func route(_ handler: @escaping @Sendable (String) -> Data) {
        URLProtocolStub.setHandler { request in
            .respond(.init(body: handler(request.url?.path ?? "")))
        }
    }

    @Test("Links, news and relationships decode from real response shapes")
    func decodesExtras() async throws {
        route { path in
            if path.hasSuffix("/links") {
                return Data("""
                {"status":200,"data":[
                  {"id":"019d","url":"https://manta.net/en/series/solo-leveling",
                   "name":"manta.net","name_display":"Manta","type":"webplatform","language":"en"}
                ]}
                """.utf8)
            }
            if path.hasSuffix("/news") {
                return Data("""
                {"status":200,"data":[
                  {"id":167427,"title":"Ize Press Unveils Four New Titles",
                   "url":"https://www.animenewsnetwork.com/x","source_name":"ann",
                   "published_at":"2026-09-01T10:00:00.000Z","primary":true}
                ]}
                """.utf8)
            }
            if path.hasSuffix("/relationships") {
                return Data("""
                {"status":200,"data":[
                  {"id":"019e","relation_type":"source","note":null,
                   "series":{"id":85266,"state":"active","merged_with":null,
                     "titles":[{"language":"en","traits":["official"],
                                "title":"Solo Leveling (Novel)","is_primary":true}],
                     "cover":{"raw":null,"x150":null,"x250":null,"x350":null,
                              "blurhash":null,"width":200,"height":300},
                     "description":null,"authors":null,"artists":null,"status":null,
                     "rating":null,"type":null,"content_rating":null,
                     "total_chapters":null,"final_volume":null,
                     "publishers":null,"anime":null,"source":null}}
                ]}
                """.utf8)
            }
            return Data(#"{"status":200,"data":[]}"#.utf8)
        }
        defer { URLProtocolStub.reset() }

        let extras = try await makeRepository().extras(for: 3397)

        #expect(extras.links.first?.title == "Manta", "name_display is preferred over name")
        #expect(extras.links.first?.language == "en")
        #expect(extras.news.first?.sourceName == "ann")
        #expect(extras.news.first?.publishedAt != nil, "Fractional-second dates must parse")
        #expect(extras.relationships.first?.label == "Source")
        #expect(extras.relationships.first?.series.displayTitle == "Solo Leveling (Novel)")
    }

    /// One failing endpoint must not empty the others. On a shared per-IP rate
    /// limit, partial failure is ordinary rather than exceptional.
    @Test("A failing endpoint leaves the other sections intact")
    func partialFailureIsSurvivable() async throws {
        URLProtocolStub.setHandler { request in
            if request.url?.path.hasSuffix("/links") == true {
                return .respond(.init(statusCode: 500, body: Data(#"{"status":500}"#.utf8)))
            }
            return .respond(.init(body: Data(#"{"status":200,"data":[]}"#.utf8)))
        }
        defer { URLProtocolStub.reset() }

        let extras = try await makeRepository().extras(for: 1)

        #expect(extras.links.isEmpty)
        #expect(extras.news.isEmpty, "An empty list is a valid answer, not a failure")
    }

    /// A merged or deleted series must not be offered as an onward path.
    @Test("Non-active related series are filtered out")
    func filtersDeadRelations() async throws {
        route { path in
            guard path.hasSuffix("/relationships") else {
                return Data(#"{"status":200,"data":[]}"#.utf8)
            }
            return Data("""
            {"status":200,"data":[
              {"id":"a","relation_type":"sequel","note":null,
               "series":{"id":2,"state":"merged","merged_with":9,"titles":null,
                 "cover":{"raw":null,"x150":null,"x250":null,"x350":null,
                          "blurhash":null,"width":null,"height":null},
                 "description":null,"authors":null,"artists":null,"status":null,
                 "rating":null,"type":null,"content_rating":null,
                 "total_chapters":null,"final_volume":null,
                 "publishers":null,"anime":null,"source":null}}
            ]}
            """.utf8)
        }
        defer { URLProtocolStub.reset() }

        let extras = try await makeRepository().extras(for: 1)
        #expect(extras.relationships.isEmpty, "A merged series is a dead end")
    }

    @Test("Relation types read as words, not as snake_case keys")
    func relationLabels() throws {
        let json = { (type: String) in
            Data("""
            {"id":"a","relation_type":"\(type)","note":null,
             "series":{"id":1,"state":"active","merged_with":null,"titles":null,
               "cover":{"raw":null,"x150":null,"x250":null,"x350":null,
                        "blurhash":null,"width":null,"height":null},
               "description":null,"authors":null,"artists":null,"status":null,
               "rating":null,"type":null,"content_rating":null,
               "total_chapters":null,"final_volume":null,
               "publishers":null,"anime":null,"source":null}}
            """.utf8)
        }
        let decoder = Fixture.decoder()
        #expect(try decoder.decode(SeriesRelationship.self, from: json("spin_off")).label == "Spin Off")
        #expect(try decoder.decode(SeriesRelationship.self, from: json("sequel")).label == "Sequel")
    }
}

@Suite("Series metadata that the mockup guessed at")
struct SeriesMetadataTests {
    /// The mockup derived "has an anime" from rating > 8.4 and invented
    /// cross-tracker scores as offsets. Both are real fields; these assert the
    /// real ones decode, so nobody is tempted to fake them again.
    @Test("Publishers, anime adaptation and tracker scores decode")
    func decodesRealMetadata() throws {
        let json = Data("""
        {"id":3397,"state":"active","merged_with":null,"titles":null,
         "cover":{"raw":null,"x150":null,"x250":null,"x350":null,
                  "blurhash":null,"width":null,"height":null},
         "description":null,"authors":null,"artists":null,"status":null,
         "rating":null,"type":null,"content_rating":null,
         "total_chapters":null,"final_volume":null,
         "publishers":[{"name":"Ize Press (Yen Press)","type":"English",
                        "note":"13+2 Volumes; Complete"}],
         "anime":{"exists":true,"start":"Chap 0 (S1)","end":"Chap 45 (S1)"},
         "source":{"anilist":{"id":105398,"rating":8.4,"rating_normalized":84},
                   "anime_planet":{"id":"solo-leveling","rating":4.6,"rating_normalized":92}}}
        """.utf8)

        let series = try Fixture.decoder().decode(Series.self, from: json)

        #expect(series.publishers?.first?.type == "English")
        #expect(series.anime?.exists == true)
        #expect(series.source?["anilist"]?.ratingNormalized == 84)
        // The two trackers use different scales; only the normalised value is
        // comparable, which is why the UI shows that one.
        #expect(series.source?["anime_planet"]?.rating == 4.6)
        #expect(series.source?["anime_planet"]?.ratingNormalized == 92)
    }

    /// Tracker ids are a string on some trackers and a number on others. The
    /// model deliberately does not decode them; this proves both shapes pass.
    @Test("Mixed-type tracker ids do not break decoding")
    func toleratesMixedIdTypes() throws {
        let json = Data("""
        {"anilist":{"id":105398,"rating":8.4,"rating_normalized":84},
         "anime_planet":{"id":"solo-leveling","rating":4.6,"rating_normalized":92}}
        """.utf8)
        let entries = try Fixture.decoder().decode([String: Series.TrackerEntry].self, from: json)
        #expect(entries.count == 2)
    }
}
