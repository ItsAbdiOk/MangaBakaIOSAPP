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
