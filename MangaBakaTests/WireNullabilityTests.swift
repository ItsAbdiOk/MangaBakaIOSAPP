import Foundation
import Testing
@testable import MangaBaka

/// Fields the spec (`docs/schemas/mangabaka_openapi.json`) marks nullable that
/// were non-optional in Swift. One null on the wire threw the whole array —
/// and every one of these arrays is decoded behind a `try?`, so the section
/// simply vanished. The price one had already happened once, on the release
/// calendar, before this file existed.
@Suite("Nullable on the wire, optional in Swift")
struct WireNullabilityTests {
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    /// `V1_Price.value: ["number", "null"]`. An unpriced edition beside a
    /// priced one dropped the whole volumes section.
    @Test("A work whose price has no value still decodes")
    func priceWithoutValue() throws {
        let works = try decoder.decode([SeriesWork].self, from: Data("""
        [{"id": "a", "sequence_string": "1", "sequence_numeric": 1, "release_date": null,
          "price": [{"value": null, "iso_code": "usd"}, {"value": 12.5, "iso_code": "gbp"}],
          "identifiers": null}]
        """.utf8))
        #expect(works.count == 1)
        #expect(works.first?.price == "£12.50", "The priced currency is shown, the unpriced one skipped")
    }

    @Test("An upcoming work whose price has no value still decodes")
    func upcomingPriceWithoutValue() throws {
        let work = try decoder.decode(UpcomingWork.self, from: Data("""
        {"id": "a", "series_id": 1, "release_date": "2026-10-01", "sequence_string": "3",
         "collections": [{"title": "A Series"}], "price": [{"value": null, "iso_code": "usd"}]}
        """.utf8))
        #expect(work.price == nil)
    }

    /// `V1_News.id: ["number", "null"]`.
    @Test("A news item with a null id still decodes and stays distinguishable")
    func newsWithoutID() throws {
        let items = try decoder.decode([NewsItem].self, from: Data("""
        [{"id": null, "title": "One", "url": "https://example.test/one", "source_name": "ann",
          "primary": true},
         {"id": null, "title": "Two", "url": "https://example.test/two", "source_name": "ann",
          "primary": false}]
        """.utf8))
        #expect(items.count == 2)
        #expect(items[0].id != items[1].id, "Two id-less items must not collapse into one row")
    }

    /// `V1_Series_Cover_Image.id: ["number", "null"]`.
    @Test("A cover image with a null id still decodes")
    func imageWithoutID() throws {
        let images = try decoder.decode([SeriesImage].self, from: Data("""
        [{"id": null, "series_id": 1, "type": "volume", "index": "1", "language": "en",
          "content_rating": "safe",
          "image": {"raw": {"url": "https://example.invalid/raw.jpg"}, "x150": null, "x250": null, "x350": null}},
         {"id": null, "series_id": 1, "type": "volume", "index": "2", "language": "en",
          "content_rating": "safe",
          "image": {"raw": {"url": "https://example.invalid/raw2.jpg"}, "x150": null, "x250": null, "x350": null}}]
        """.utf8))
        #expect(images.count == 2)
        #expect(images[0].id != images[1].id)
    }

    /// `/v1/publishers/search` item: `id: ["number", "null"]`, and `aliases`
    /// is a list of title objects, not strings.
    @Test("A publisher with a null id and object aliases still decodes")
    func publisherWithoutID() throws {
        let publishers = try decoder.decode([PublisherRecord].self, from: Data("""
        [{"id": null, "type": "publisher", "sub_type": "both", "name": "Seven Seas",
          "aliases": [{"title": "Seven Seas Entertainment", "language": "en"}], "parent_id": null}]
        """.utf8))
        #expect(publishers.first?.name == "Seven Seas")
    }
}

/// Places where one bad element, or one missing field, cost more than itself.
@Suite("One bad element costs one element")
struct WireResilienceTests {
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    /// `tags_v2` was decoded as one array under `try?`: a single tag with a
    /// null name emptied all 146 of Solo Leveling's, and the flat fallback
    /// list hid that the rich ones had gone.
    @Test("One malformed tag drops that tag, not all of them")
    func oneBadTagCostsOneTag() throws {
        let series = try decoder.decode(Series.self, from: Data("""
        {"id": 1, "state": "active", "cover": {},
         "tags_v2": [{"id": 1, "name": "Action"}, {"id": 2, "name": null}, {"id": 3, "name": "Murim"}]}
        """.utf8))
        #expect(series.richTags.map(\.name) == ["Action", "Murim"])
    }

    /// The comment on `volumes(from:)` promised numberless works — a box set,
    /// a side story — would keep the API's order at the end. The loop dropped
    /// them.
    @Test("A work with no volume number is still listed, at the end")
    func numberlessWorksAreKept() throws {
        let works = try decoder.decode([SeriesWork].self, from: Data("""
        [{"id": "box", "sequence_string": null, "sequence_numeric": null, "release_date": null,
          "price": null, "identifiers": null},
         {"id": "v2", "sequence_string": "2", "sequence_numeric": 2, "release_date": null,
          "price": null, "identifiers": null},
         {"id": "v1", "sequence_string": "1", "sequence_numeric": 1, "release_date": null,
          "price": null, "identifiers": null}]
        """.utf8))
        let volumes = SeriesWork.volumes(from: works)
        #expect(volumes.map(\.label) == ["Vol. 1", "Vol. 2", "Other editions"])
        #expect(volumes.last?.editions.map(\.id) == ["box"])
    }

    /// The schema types every pulse figure as `number`, and a sibling field
    /// is measured to arrive fractional. `Int` throws on 290.0.
    @Test("A fractional count still decodes")
    func fractionalCountsDecode() throws {
        let pulse = try decoder.decode(CommunityPulse.self, from: Data("""
        {"active_series_count": 304108.0, "active_series_count_prev_week": 303800.5,
         "registered_user_count": 12000.0, "registered_user_count_prev_week": 11950.0,
         "chapters_read_count": 53975689.25981874, "chapters_read_count_prev_week": 53000000.0}
        """.utf8))
        #expect(pulse.activeSeriesCount == 304_108)
    }
}
