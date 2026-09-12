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

    @Test("A closed publisher with a founding year says both")
    func closedAndFounded() throws {
        let json = Data(
            #"{"id": 5, "name": "Tokyopop", "type": "publisher", "founded": 1997, "closed": true}"#.utf8
        )
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let detail = try decoder.decode(PublisherDetail.self, from: json)
        #expect(detail.summary == "Publisher · Since 1997 · Closed")
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
        let story = credits.rows.first { $0.id == "Story & art" }
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
        // The header is the count endpoint's total, not the page's length,
        // and the grid pages: Shueisha said "100" when it is thousands.
        #expect(view.contains("async let counted = repository.count(query)"))
        #expect(view.contains("Text((total ?? series.count).formatted())"))
        #expect(view.contains("hasMore = result.series.count >= query.limit"))
        #expect(view.contains(".task(id: order) { await load() }"))
        let credits = try SourceTree.read("MangaBaka/Features/Detail/DetailCredits.swift")
        #expect(credits.contains("onOpenPublisher(publishers[0].name)"))
        let root = try SourceTree.read("MangaBaka/App/RootView.swift")
        #expect(root.contains(".navigationDestination(item: $openPublisher)"))
    }
}
