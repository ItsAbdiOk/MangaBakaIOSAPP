import Foundation

/// A volume with an announced release date.
///
/// **The difference between this and the rest of the Schedule screen is the
/// difference between a fact and an estimate.** Everything else there is
/// inferred from how often a series has published before; this is a publisher
/// saying "the 14th". Where both exist, this wins and the prediction goes away.
///
/// Checked against `/v1/works/upcoming` on 2026-09-10: 246 works in the window,
/// sorted by date ascending, each carrying a series id, a volume number and a
/// publisher link. The `days` parameter is accepted and appears to be ignored —
/// asking for 30 returned the same 246 as asking for nothing — so the window is
/// whatever they consider upcoming and the app does not pretend to set it.
struct UpcomingWork: Decodable, Identifiable, Sendable, Equatable {
    struct Collection: Decodable, Sendable, Equatable {
        let title: String?
    }

    struct Link: Decodable, Sendable, Equatable {
        let type: String?
        let link: String?
    }

    let id: String
    let seriesId: Int?
    /// ISO-8601 date, "2026-09-15".
    let releaseDate: String?
    /// "11" — as printed on the spine, which is not always a number.
    let sequenceString: String?
    let sequenceNumeric: Double?
    let pages: Int?
    let price: String?
    let links: [Link]?
    let collections: [Collection]?

    /// The series' title, which this endpoint carries under its collection
    /// rather than on the work itself.
    var title: String? {
        collections?.compactMap(\.title).first
    }

    /// "Vol. 11", or nothing when the publisher did not number it.
    var volume: String? {
        guard let sequenceString, !sequenceString.isEmpty else { return nil }
        return "Vol. \(sequenceString)"
    }

    var date: Date? {
        guard let releaseDate else { return nil }
        return Self.formatter.date(from: releaseDate)
    }

    /// Where to buy it, when the publisher gave a link.
    var publisherLink: URL? {
        guard let raw = links?.first(where: { $0.type == "publisher" })?.link else { return nil }
        return URL(string: raw)
    }

    /// Dates only, no times, and fixed to UTC.
    ///
    /// A release date is a calendar day rather than an instant: parsing
    /// "2026-09-15" in the device's own zone puts it at midnight local, which
    /// west of UTC is the 14th.
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
