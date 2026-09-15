import Foundation
import Testing
@testable import MangaBaka

/// `docs/reviews/night/shelf.md` item 14: a partial date is a period, and
/// "forthcoming" is measured against its end.
@Suite("Partial date forthcoming")
struct PartialDateForthcomingTests {
    private func date(_ iso: String) throws -> Date {
        try #require(PartialDate.parse(iso)?.date)
    }

    /// EXPECTED TO FAIL before the change on the first `#expect`: a
    /// month-precision `2026-10` was `2026-10-01T00:00Z`, which is not after
    /// `2026-10-02`, so a book due the 25th stopped being announced on the
    /// 1st. Likewise the year: `2026` was never forthcoming after 1 January.
    @Test("A month- or year-precision date is forthcoming until its period ends")
    func periodEndDecides() throws {
        let october = try #require(PartialDate.parse("2026-10"))
        #expect(october.isForthcoming(now: try date("2026-10-02")))
        #expect(!october.isForthcoming(now: try date("2026-11-01")), "The control: November is after October")

        let year = try #require(PartialDate.parse("2026"))
        #expect(year.isForthcoming(now: try date("2026-09-15")))
        #expect(!year.isForthcoming(now: try date("2027-01-01")))

        // Day precision, the measured case, is unchanged: 2026-09-18 against
        // 2026-09-14 is ahead, and 2022 against the same clock is not.
        let day = try #require(PartialDate.parse("2026-09-18"))
        #expect(day.isForthcoming(now: try date("2026-09-14")))
        #expect(!day.isForthcoming(now: try date("2026-09-19")))
    }
}
