import Testing
import Foundation
@testable import MangaBaka

/// Labels for editions of the same volume that otherwise read identically.
///
/// The bug report: Hunter x Hunter vol. 8's three editions each showed
/// "Price not listed" then a page count and nothing else — indistinguishable
/// cards. `/v1/series/{id}/works` has no format/binding field (verified
/// 2026-09-11), so a label can never claim "paperback" or "digital"; it can
/// only say what the data actually shows differs.
@Suite("Edition labels")
struct EditionLabelTests {
    private func work(
        _ id: String,
        number: String = "1",
        date: String? = nil,
        pages: Int? = nil,
        isbn: String? = nil
    ) -> SeriesWork {
        // Built in pieces, matching SeriesWorkTests: interpolating several
        // optionals into one string literal defeats the type checker
        // ("failed to produce diagnostic for expression").
        let dateJSON = date.map { "\"\($0)\"" } ?? "null"
        let pagesJSON = pages.map { String($0) } ?? "null"
        let isbnJSON = isbn.map { "[{\"id\": \"\($0)\", \"name\": \"isbn\"}]" } ?? "null"
        let json = """
        {"id": "\(id)", "sequence_string": "\(number)",
         "sequence_numeric": 1, "release_date": \(dateJSON),
         "pages": \(pagesJSON), "price": null, "identifiers": \(isbnJSON)}
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            return try decoder.decode(SeriesWork.self, from: Data(json.utf8))
        } catch {
            fatalError("the fixture does not decode, which is a broken test: \(error)")
        }
    }

    @Test("Editions with different release years get year labels")
    func differingYearsAreLabelled() {
        let volume = SeriesWork.Volume(number: "1", editions: [
            work("a", date: "2004-06-04"),
            work("b", date: "2018-11-13")
        ])
        let labels = volume.editionLabels
        #expect(labels["a"] == "2004")
        #expect(labels["b"] == "2018")
    }

    @Test("A page count far above the volume's median is flagged as a likely omnibus")
    func outsizedPageCountIsFlaggedAsOmnibus() {
        // Hunter x Hunter vol. 8: two ~195-200pp singles and a 616pp 3-in-1.
        let volume = SeriesWork.Volume(number: "8", editions: [
            work("a", pages: 195),
            work("b", pages: 200),
            work("c", pages: 616)
        ])
        let labels = volume.editionLabels
        #expect(labels["c"]?.contains("likely an omnibus") == true)
        #expect(labels["a"] == nil)
        #expect(labels["b"] == nil)
    }

    @Test("Identical editions fall back to distinct ISBN-suffix labels")
    func identicalEditionsFallBackToISBN() {
        // Same year, same page count, nothing else to go on — the label
        // must still tell the cards apart, or the original bug persists.
        let volume = SeriesWork.Volume(number: "1", editions: [
            work("a", date: "2021-01-01", pages: 200, isbn: "9781234562804"),
            work("b", date: "2021-01-01", pages: 200, isbn: "9781234569999")
        ])
        let labels = volume.editionLabels
        #expect(labels["a"] == "ISBN …2804")
        #expect(labels["b"] == "ISBN …9999")
        #expect(labels["a"] != labels["b"])
    }

    @Test("A volume with one edition gets no label")
    func singleEditionGetsNoLabel() {
        let volume = SeriesWork.Volume(number: "1", editions: [work("a", pages: 200)])
        #expect(volume.editionLabels.isEmpty)
    }
}
