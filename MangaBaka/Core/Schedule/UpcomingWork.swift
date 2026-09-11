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

    /// One currency's price for this volume.
    ///
    /// **Modelled as a `String` until 2026-09-11, which meant the calendar
    /// never worked.** The API sends a list —
    /// `[{"value": 1.99, "iso_code": "usd"}, {"value": 2.99, "iso_code": "cad"}]`
    /// — so every real response threw on decode, and the throw is caught and
    /// read as "no upcoming works". The screen was empty for a reason nobody
    /// could see. The test fixture said `String` too, so the tests agreed with
    /// the bug.
    struct Price: Decodable, Sendable, Equatable {
        /// Nullable on the wire too (`V1_Price.value`).
        let value: Double?
        let isoCode: String?
    }

    /// One identifier, which in practice is an ISBN.
    struct Identifier: Decodable, Sendable, Equatable {
        let id: String?
        let name: String?
    }

    let id: String
    let seriesId: Int?
    /// ISO-8601 date, "2026-09-15".
    let releaseDate: String?
    /// "11" — as printed on the spine, which is not always a number.
    let sequenceString: String?
    let sequenceNumeric: Double?
    let pages: Int?
    let prices: [Price]?
    let identifiers: [Identifier]?
    let links: [Link]?
    let collections: [Collection]?

    enum CodingKeys: String, CodingKey {
        case id, seriesId, releaseDate, sequenceString, sequenceNumeric
        case pages, identifiers, links, collections
        case prices = "price"
    }

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

    /// The price, in one currency, formatted.
    ///
    /// USD when it is offered, because it is the currency every edition in the
    /// sample carried; otherwise whatever came first. Deliberately not
    /// converted or localised — this is the publisher's list price in the
    /// currency they set it in, and quietly relabelling $9.99 as £9.99 would
    /// be a lie about someone else's shop.
    var price: String? {
        let priced = (prices ?? []).filter { $0.value != nil }
        guard let chosen = priced.first(where: { $0.isoCode?.lowercased() == "usd" }) ?? priced.first,
              let value = chosen.value
        else { return nil }
        var format = FloatingPointFormatStyle<Double>.Currency(code: chosen.isoCode ?? "usd")
        format = format.locale(Locale(identifier: "en_US"))
        return value.formatted(format)
    }

    /// The ISBN, where the publisher registered one.
    var isbn: String? {
        identifiers?.first { $0.name?.lowercased() == "isbn" }?.id
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
