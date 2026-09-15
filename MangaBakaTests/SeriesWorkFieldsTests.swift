import Testing
import Foundation
@testable import MangaBaka

/// The `/v1/series/{id}/works` fields `SeriesWork` did not decode until
/// 2026-09-15: `description`, `trim`, `count_type`, `part_of_volume`,
/// `inc_chapters`, and `note`. Decode tests run against the live capture
/// `series-2060-works-2026-09-15.json`; `SeriesWorkTests` and
/// `EditionLabelTests` already cover the fields that existed before this.
@Suite("SeriesWork's new /works fields")
struct SeriesWorkFieldsTests {
    /// `/v1/series/{id}/works` wraps its rows in `{"status", "data", "pagination"}`
    /// — `SeriesWork` itself only ever decodes the elements of `data`.
    private struct WorksEnvelope: Decodable {
        let data: [SeriesWork]
    }

    private func decodeFixtureWorks() throws -> [SeriesWork] {
        let data = try Fixture.data("series-2060-works-2026-09-15")
        return try Fixture.decoder().decode(WorksEnvelope.self, from: data).data
    }

    /// Builds a single `/works` row with only the keys a given test cares
    /// about, matching the old-shape JSON in `SeriesWorkTests`/
    /// `EditionLabelTests` — those two omit every field this suite adds, and
    /// that omission is itself what `oldShapeRowStillDecodes` below checks.
    private func rowJSON(sequence: String, extra: String = "") -> String {
        """
        {"id": "\(sequence)", "sequence_string": "\(sequence)",
         "sequence_numeric": \(sequence), "release_date": null, "pages": null,
         "price": null, "identifiers": null\(extra)}
        """
    }

    private func decode(_ json: String) throws -> SeriesWork {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(SeriesWork.self, from: Data(json.utf8))
    }

    @Test("The blurb decodes from the fixture's description.desc")
    func descriptionDecodes() throws {
        let first = try #require(try decodeFixtureWorks().first)
        // Avoids the curly apostrophe in "Dokja Kim's" in the fixture text,
        // which would make a literal comparison fragile to re-encoding.
        #expect(first.description?.desc?.hasPrefix("As a struggling office worker") == true)
    }

    @Test("Trim decodes from the fixture, and trimLine rounds to whole millimetres")
    func trimDecodesAndRounds() throws {
        let first = try #require(try decodeFixtureWorks().first)
        #expect(first.trim?.wMm == 146.04999999999998)
        #expect(first.trim?.hMm == 209.54999999999998)
        // Fails on the pre-2026-09-15 code with "value of type 'SeriesWork'
        // has no member 'trimLine'" — there was no such field to round.
        #expect(first.trimLine == "146 × 210 mm")
    }

    @Test("count_type decodes as \"main\" for every sampled row")
    func countTypeIsMainInFixture() throws {
        // The only value seen live in this capture. "extra" is exercised
        // below with hand-written JSON since this fixture's three sampled
        // rows (of the series' 13) are all main-line volumes.
        #expect(try decodeFixtureWorks().allSatisfy { $0.countType == "main" })
    }

    @Test("part_of_volume, inc_chapters and note are null in the fixture, and decode as nil")
    func nullFieldsDecodeAsNilInFixture() throws {
        let works = try decodeFixtureWorks()
        #expect(works.allSatisfy { $0.partOfVolume == nil })
        #expect(works.allSatisfy { $0.incChapters == nil })
        #expect(works.allSatisfy { $0.note == nil })
    }

    @Test("An old-shape row, with none of these keys at all, still decodes with them all nil")
    func oldShapeRowStillDecodes() throws {
        // Every cached row from before 2026-09-15 has this exact shape — no
        // description/trim/count_type/part_of_volume/inc_chapters/note keys,
        // not even as explicit nulls. Before the `= nil` defaults this threw
        // `keyNotFound` the moment the new `CodingKeys` cases were added,
        // which is what made this the two-line control the old-row promise
        // in the brief actually needed, not just an assertion on the happy path.
        let work = try decode(rowJSON(sequence: "1"))
        #expect(work.description == nil)
        #expect(work.trim == nil)
        #expect(work.countType == nil)
        #expect(work.partOfVolume == nil)
        #expect(work.incChapters == nil)
        #expect(work.note == nil)
    }

    @Test("part_of_volume decodes when present, and the volume shows it")
    func partOfVolumeDecodesWhenPresent() throws {
        let work = try decode(rowJSON(sequence: "5", extra: #", "part_of_volume": "4""#))
        #expect(work.partOfVolume == "4")
        let volume = SeriesWork.Volume(number: "5", editions: [work])
        #expect(volume.partOfVolumeLabel == "Part of volume 4")
    }

    @Test("A count_type of \"extra\" flags the volume's Extra chip")
    func extraCountTypeFlagsTheChip() throws {
        let work = try decode(rowJSON(sequence: "3.5", extra: #", "count_type": "extra""#))
        #expect(work.countType == "extra")
        let volume = SeriesWork.Volume(number: "3.5", editions: [work])
        #expect(volume.isExtra)
    }

    @Test("A count_type of \"main\" does not show the Extra chip")
    func mainCountTypeDoesNotFlagTheChip() throws {
        let work = try decode(rowJSON(sequence: "1", extra: #", "count_type": "main""#))
        let volume = SeriesWork.Volume(number: "1", editions: [work])
        #expect(!volume.isExtra)
    }

    @Test("note decodes and is kept verbatim")
    func noteDecodesVerbatim() throws {
        let work = try decode(rowJSON(sequence: "1", extra: #", "note": "Includes a bonus poster.""#))
        #expect(work.note == "Includes a bonus poster.")
    }

    @Test("inc_chapters accepts a bare number as well as a string")
    func incChaptersAcceptsNumberOrString() throws {
        let stringWork = try decode(rowJSON(sequence: "1", extra: #", "inc_chapters": "12""#))
        let numberWork = try decode(rowJSON(sequence: "1", extra: ", \"inc_chapters\": 12"))
        #expect(stringWork.incChapters?.raw == "12")
        #expect(numberWork.incChapters?.raw == "12.0")
    }

    @Test("The reader's currency is picked when the publisher listed it")
    func pricePicksReadersCurrency() {
        let prices = [
            SeriesWork.Price(value: 20, isoCode: "usd"),
            SeriesWork.Price(value: 26, isoCode: "cad")
        ]
        #expect(SeriesWork.pickPrice(from: prices, preferredCurrencyCode: "cad")?.isoCode == "cad")
        #expect(SeriesWork.pickPrice(from: prices, preferredCurrencyCode: "usd")?.isoCode == "usd")
    }

    @Test("An unmatched or missing currency falls back to the publisher's first listed price")
    func priceFallsBackToFirstEntry() {
        let prices = [
            SeriesWork.Price(value: 20, isoCode: "usd"),
            SeriesWork.Price(value: 26, isoCode: "cad")
        ]
        #expect(SeriesWork.pickPrice(from: prices, preferredCurrencyCode: "eur")?.isoCode == "usd")
        #expect(SeriesWork.pickPrice(from: prices, preferredCurrencyCode: nil)?.isoCode == "usd")
    }
}
