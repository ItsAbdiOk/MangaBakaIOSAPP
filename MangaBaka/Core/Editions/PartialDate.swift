import Foundation

/// A publication date that knows how precise it is.
///
/// Both catalogues this folder talks to answer dates at three different
/// precisions in one response, and collapsing them loses the only thing a
/// reader cares about. Measured 2026-09-14, one Open Library editions call
/// (`/works/OL19921538W/editions.json`, Solo Leveling) returned all three:
///
/// ```
/// Solo Leveling, Vol. 1 | 2021-03-02
/// Solo Leveling T01     | Apr 07, 2021
/// Solo leveling         | 2012
/// ```
///
/// NDL is tidier but still bimodal — `dcterms:issued` was `2026-09-18` on the
/// forthcoming volume and a bare `2022` on an older one, same response, same
/// query (measured 2026-09-14).
///
/// Storing `Date` alone would print "1 January 2012" for the third row, which
/// is a fact the catalogue never asserted. `precision` is what lets a view say
/// "2012" there and "2 March 2021" above it.
struct PartialDate: Codable, Sendable, Equatable, Comparable {
    /// How much of `date` the source actually stated. Anything below the
    /// stated precision is the start of the period, not a claim.
    enum Precision: Int, Codable, Sendable, Comparable {
        case year
        case month
        case day

        static func < (lhs: Precision, rhs: Precision) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// The first instant of the stated period, in UTC. A year-precision 2012
    /// is 2012-01-01; that is a representation, not a publication day.
    let date: Date
    let precision: Precision

    static func < (lhs: PartialDate, rhs: PartialDate) -> Bool { lhs.date < rhs.date }

    /// True when the catalogue has the book but the book is not out yet.
    ///
    /// The reason `NDLClient` exists: NDL ingests 近刊 (forthcoming) records,
    /// and the Solo Leveling side-story volume came back dated `2026-09-18`
    /// against a clock reading 2026-09-14 (measured that day). Nothing else
    /// in the bibliographic family carries an unpublished volume.
    func isForthcoming(now: Date) -> Bool { date > now }

    // MARK: - Parsing

    /// Reads the formats both catalogues were measured to send, and nothing
    /// else. An unrecognised string is nil — "we don't know when" — never a
    /// silently defaulted 1 January.
    ///
    /// - Note: no `DateFormatter` with a lenient setting and no locale-aware
    ///   parse. Both were rejected: a lenient formatter turned `2012` into
    ///   2012-01-01 at day precision, which is the exact fabrication this type
    ///   exists to prevent.
    static func parse(_ raw: String?) -> PartialDate? {
        guard let raw else { return nil }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return iso(text) ?? longForm(text)
    }

    /// `2021-03-02`, `2021-03`, `2021` — Open Library's tidy rows, and every
    /// NDL `dcterms:issued` (which is documented as W3CDTF, i.e. exactly
    /// this family).
    private static func iso(_ text: String) -> PartialDate? {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard let year = Int(parts[0]), parts[0].count == 4, (1000...9999).contains(year) else {
            return nil
        }
        var components = DateComponents(year: year, month: 1, day: 1)
        var precision = Precision.year

        if parts.count >= 2 {
            guard let month = Int(parts[1]), (1...12).contains(month) else { return nil }
            components.month = month
            precision = .month
        }
        if parts.count >= 3 {
            guard let day = Int(parts[2]), (1...31).contains(day) else { return nil }
            components.day = day
            precision = .day
        }
        guard parts.count <= 3, let date = utc.date(from: components) else { return nil }
        return PartialDate(date: date, precision: precision)
    }

    /// `Apr 07, 2021` and `April 2021` — the shape Open Library's French row
    /// arrived in (measured 2026-09-14). Month names are matched against a
    /// fixed English table rather than the device locale: this is someone
    /// else's database writing English, and a phone set to French must read
    /// it identically.
    private static func longForm(_ text: String) -> PartialDate? {
        let cleaned = text.replacingOccurrences(of: ",", with: " ")
        let words = cleaned.split(separator: " ").map(String.init)
        guard words.count >= 2, let month = monthNumber(words[0]) else { return nil }

        // "Apr 07 2021" or "April 2021": the year is always the last word.
        guard let year = Int(words[words.count - 1]), words[words.count - 1].count == 4 else {
            return nil
        }
        var components = DateComponents(year: year, month: month, day: 1)
        var precision = Precision.month
        if words.count >= 3, let day = Int(Self.withoutOrdinal(words[1])), (1...31).contains(day) {
            components.day = day
            precision = .day
        }
        guard let date = utc.date(from: components) else { return nil }
        return PartialDate(date: date, precision: precision)
    }

    /// `24th` → `24`. Open Library's rows are hand-entered and one of the
    /// eighteen One Piece editions measured on 2026-09-14 reads
    /// `Mar 24th 2003`; without this it drops to month precision and loses a
    /// day the catalogue actually stated.
    ///
    /// Not extended to `23/04/2016` — another row in the same response.
    /// That one is genuinely ambiguous (23 April or an impossible month), and
    /// a date this app cannot read is left unknown rather than guessed at.
    private static func withoutOrdinal(_ word: String) -> String {
        let suffixes = ["st", "nd", "rd", "th"]
        for suffix in suffixes where word.lowercased().hasSuffix(suffix) {
            return String(word.dropLast(2))
        }
        return word
    }

    private static func monthNumber(_ word: String) -> Int? {
        let key = word.lowercased().prefix(3)
        let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
        guard let index = months.firstIndex(of: String(key)) else { return nil }
        return index + 1
    }

    /// A fixed UTC Gregorian calendar. A publication date off a catalogue is
    /// not an instant in the reader's timezone, and building these against
    /// `Calendar.current` would shift a Tokyo release by a day for a reader
    /// in Los Angeles.
    private static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        // A locale-independent calendar: `TimeZone(identifier:)` is optional
        // and `!` is banned here, so the failure falls back to the device's
        // zone rather than trapping. `"UTC"` is a fixed string, so the
        // fallback is unreachable in practice.
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar
    }
}
