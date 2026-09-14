import Foundation
import Testing
@testable import MangaBaka

/// The arithmetic and the matching behind a barcode read, without a camera.
///
/// Every test here fails on the code before this change with a compile error
/// — `ISBN13` and `ISBNScanSheet` did not exist. The assertions are what fail
/// once they do and a rule is wrong; each doc comment says which.
@Suite("ISBN scan")
struct ISBNScanTests {
    // MARK: - Check digit

    /// Five real ISBN-13s, each already in this repository with its source:
    ///
    /// - 9780316471855 — Delicious in Dungeon (GN 1), ANN's `ean` attribute,
    ///   quoted in `ANNRelease.swift` and `VolumeEdition.swift`.
    /// - 9784047301535 — ダンジョン飯 1, Open Library's answer quoted in
    ///   `OpenLibraryEditions.swift` and used in `VolumeEditionMergeTests`.
    /// - 9781975319434 — Solo Leveling, Vol. 1 (Yen Press), the anchor in
    ///   `OpenLibraryEditions.swift`'s measured request log.
    /// - 9784046604873 — the NDL record in `NDLRecordParser.swift`'s doc
    ///   comment (`R100000137-I9784046604873`).
    /// - 9798855400359 — a 979-prefixed one from ANN's recorded answer, in
    ///   `ANNVolumesTests`; the 979 prefix is the one a `978`-only check
    ///   would wrongly refuse.
    ///
    /// Fails on a validator with the weights the wrong way round (3,1,3,1,…):
    /// 9780316471855 sums to 156 that way and is refused.
    @Test("Five real ISBN-13s pass the check digit")
    func realISBNsPass() {
        for isbn in [
            "9780316471855", "9784047301535", "9781975319434", "9784046604873", "9798855400359"
        ] {
            #expect(ISBN13.isValidISBN13(isbn), Comment(rawValue: isbn))
        }
    }

    /// Five that must fail, each one edit away from a real one above:
    ///
    /// - 9780316471856 — the last digit of Delicious in Dungeon bumped by one.
    /// - 9780316417855 — two adjacent digits transposed (`…6471…` →
    ///   `…6417…`), the classic keying error a check digit exists to catch.
    /// - 978031647185 — twelve digits: the check digit missing.
    /// - 97803164718555 — fourteen digits.
    /// - 0316471852 — a syntactically plausible ISBN-10 (not asserted to be a
    ///   real one; it is ten characters and that alone must refuse it).
    ///
    /// Fails on a validator that only checks length: the first two are
    /// thirteen digits and would pass.
    @Test("Five near-misses fail the check digit")
    func nearMissesFail() {
        for isbn in ["9780316471856", "9780316417855", "978031647185", "97803164718555", "0316471852"] {
            #expect(!ISBN13.isValidISBN13(isbn), Comment(rawValue: isbn))
        }
    }

    // MARK: - Normalisation

    /// A printed ISBN has hyphens; a typed one may have spaces. Both fold to
    /// the digits a barcode would carry.
    @Test("Hyphens and spaces are stripped before the check")
    func hyphensAndSpacesAreStripped() {
        #expect(ISBN13.normalise("978-0-316-47185-5") == "9780316471855")
        #expect(ISBN13.normalise("978 0 316 47185 5") == "9780316471855")
        #expect(ISBN13.normalise("9780316471855") == "9780316471855")
    }

    /// ISBN-10 is refused rather than converted — recorded on `normalise`.
    /// `0316471852` is the ten-character shape; whether its own check digit
    /// is right is beside the point, because no conversion is attempted.
    @Test("ISBN-10 is refused, not converted")
    func isbn10IsRefused() {
        #expect(ISBN13.normalise("0316471852") == nil)
        #expect(ISBN13.normalise("0-316-47185-2") == nil)
    }

    /// An EAN-13 that is not a book's: a valid check digit under a prefix
    /// that is not 978 or 979. Retailer stickers and magazines look like
    /// this, and the sheet must say "not an ISBN", not "not on the shelf".
    ///
    /// `5012345678900` is a made-up UK-prefixed (`50`) product code whose
    /// check digit happens to be valid (weighted sum 90) — checked by hand
    /// when this test was written, not taken from any product.
    @Test("A non-book EAN-13 is refused even with a valid check digit")
    func nonBookEANIsRefused() {
        #expect(ISBN13.isValidISBN13("5012345678900"))
        #expect(ISBN13.normalise("5012345678900") == nil)
    }

    // MARK: - Matching

    /// The scan is scoped to the series page it came from: a row on *this*
    /// shelf matches, a row with the same ISBN on no shelf here does not.
    @Test("An ISBN on the shelf matches its row")
    func isbnOnTheShelfMatches() {
        let shelves = [
            EditionShelf(
                edition: annEdition, volumes: [volume(1, isbn: "9780316471855"), volume(2, isbn: nil)]
            )
        ]
        #expect(ISBN13.match("9780316471855", in: shelves)?.number == 1)
        #expect(ISBN13.match("9784047301535", in: shelves) == nil)
    }

    /// A row whose source hyphenated its ISBN still matches — the same fold
    /// `OwnedVolumeKey` applies. Fails on a comparison of the raw strings.
    @Test("A hyphenated row ISBN still matches the scan")
    func hyphenatedRowMatches() {
        let shelves = [
            EditionShelf(edition: annEdition, volumes: [volume(1, isbn: "978-0-316-47185-5")])
        ]
        #expect(ISBN13.match("9780316471855", in: shelves)?.number == 1)
    }

    // MARK: - The sheet's copy

    /// The line for a matched row names the volume and what just happened.
    @Test("A matched scan says which volume and that it is now owned")
    func matchedWording() {
        let owned = ISBNScanSheet.outcomeWording(.matched(title: "Vol. 7 (GN)", number: 7, nowOwned: true))
        #expect(owned == "Vol. 7 · now owned")
        let unowned = ISBNScanSheet.outcomeWording(.matched(title: "Guidebook", number: nil, nowOwned: false))
        #expect(unowned == "Guidebook · no longer owned")
    }

    /// A miss says it is a miss on *this* shelf and shows the ISBN — and
    /// offers nothing else, because there is nothing else it looked at.
    @Test("A miss names the ISBN and this series' shelf")
    func missWording() {
        let line = ISBNScanSheet.outcomeWording(.notOnShelf(isbn: "9784047301535"))
        #expect(line == "Not on this series' shelf — ISBN 9784047301535")
    }

    /// The simulator's line: no scanner, and a sentence rather than a blank.
    @Test("An unsupported device gets a sentence")
    func unsupportedWording() {
        #expect(!ISBNScanSheet.wording(.unsupported).isEmpty)
        #expect(!ISBNScanSheet.wording(.denied).isEmpty)
    }

    // MARK: - Helpers

    private var annEdition: VolumeEdition {
        VolumeEdition(
            catalogue: .animeNewsNetwork, language: "en", languageRole: .english,
            editionTitle: "Delicious in Dungeon"
        )
    }

    private func volume(_ number: Int, isbn: String?) -> EditionVolume {
        EditionVolume(
            number: number, title: "Delicious in Dungeon (GN \(number))", releaseDate: nil,
            isbn13: isbn, format: .print, edition: annEdition,
            sourceLink: URL(string: "https://www.animenewsnetwork.com/encyclopedia/manga.php?id=17164")
        )
    }
}
