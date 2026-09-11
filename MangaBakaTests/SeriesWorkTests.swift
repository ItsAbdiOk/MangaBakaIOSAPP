import Testing
import Foundation
@testable import MangaBaka

/// Volumes, gathered from editions.
///
/// A "work" is an edition, not a volume. Solo Leveling volume 1 appears twice
/// in `/v1/series/3397/works` — once at $9.99 and once at $20, paperback and
/// hardcover, distinguished only by their ISBNs. Verified live on 2026-09-11.
/// A list that does not group them looks duplicated and broken.
@Suite("Volumes")
struct SeriesWorkTests {
    private func work(
        _ id: String,
        number: String?,
        numeric: Double? = nil,
        date: String? = nil,
        price: Double? = nil,
        isbn: String? = nil
    ) -> SeriesWork {
        // Built in pieces rather than as one interpolated literal: six
        // optionals in a single string expression defeats the type checker
        // outright ("failed to produce diagnostic for expression").
        let numberJSON = number.map { "\"\($0)\"" } ?? "null"
        let numericJSON = numeric.map { String($0) } ?? "null"
        let dateJSON = date.map { "\"\($0)\"" } ?? "null"
        let priceJSON = price.map { "[{\"value\": \($0), \"iso_code\": \"usd\"}]" } ?? "null"
        let isbnJSON = isbn.map { "[{\"id\": \"\($0)\", \"name\": \"isbn\"}]" } ?? "null"
        let json = """
        {"id": "\(id)", "sequence_string": \(numberJSON),
         "sequence_numeric": \(numericJSON), "release_date": \(dateJSON),
         "price": \(priceJSON), "identifiers": \(isbnJSON)}
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            return try decoder.decode(SeriesWork.self, from: Data(json.utf8))
        } catch {
            fatalError("the fixture does not decode, which is a broken test: \(error)")
        }
    }

    @Test("Two editions of one volume are one volume")
    func editionsAreGathered() {
        let volumes = SeriesWork.volumes(from: [
            work("a", number: "1", numeric: 1, price: 9.99, isbn: "9781975319441"),
            work("b", number: "1", numeric: 1, price: 20, isbn: "9781975319434")
        ])

        #expect(volumes.count == 1)
        #expect(volumes.first?.editions.count == 2)
        #expect(volumes.first?.label == "Vol. 1")
    }

    @Test("Volume 10 comes after volume 2")
    func spineOrderIsNumeric() {
        // "10" sorts before "2" as a string, and a volume list in that order is
        // unreadable.
        let volumes = SeriesWork.volumes(from: [
            work("a", number: "10", numeric: 10),
            work("b", number: "2", numeric: 2),
            work("c", number: "1", numeric: 1)
        ])
        #expect(volumes.map(\.number) == ["1", "2", "10"])
    }

    @Test("Something with no number is kept, at the end")
    func unnumberedWorksSortLast() {
        // A box set or a side story is still worth showing; it is just not
        // worth pretending to place among the numbered volumes.
        let volumes = SeriesWork.volumes(from: [
            work("a", number: "Box", numeric: nil),
            work("b", number: "1", numeric: 1)
        ])
        #expect(volumes.map(\.number) == ["1", "Box"])
    }

    @Test("A work with no sequence at all is kept, under its own label")
    func unsequencedWorksAreKept() {
        // This asserted `.isEmpty` — the loop dropped them — under the
        // function's own promise that "a side story or a box set is still
        // worth showing". A row reading "Vol. " helps nobody, so the label is
        // its own.
        let volumes = SeriesWork.volumes(from: [work("a", number: nil)])
        #expect(volumes.map(\.label) == ["Other editions"])
    }

    @Test("A volume takes the earliest date any of its editions was published")
    func earliestEditionDates() throws {
        let volumes = SeriesWork.volumes(from: [
            work("a", number: "1", numeric: 1, date: "2021-07-20"),
            work("b", number: "1", numeric: 1, date: "2021-03-02")
        ])
        let date = try #require(volumes.first?.date)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        #expect(utc.component(.month, from: date) == 3)
    }

    @Test("Prices are formatted in the currency the publisher set them in")
    func pricesAreNotConverted() {
        let edition = work("a", number: "1", price: 9.99)
        #expect(edition.price == "$9.99")
    }

    @Test("An ISBN is what tells two editions apart")
    func isbnIsRead() {
        #expect(work("a", number: "1", isbn: "9781975319441").isbn == "9781975319441")
        #expect(work("b", number: "1").isbn == nil)
    }
}
