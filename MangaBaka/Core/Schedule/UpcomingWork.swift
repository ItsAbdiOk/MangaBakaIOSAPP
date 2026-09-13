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
    /// `main | extra | other` (`docs/schemas/mangabaka_openapi.json`,
    /// `V1_Work_Default.count_type`). 50 of 50 works in the live window were
    /// `main` on 2026-09-13, so an `extra`/`other` work has not actually been
    /// seen there, but the schema promises the other two exist, and calling
    /// every one of them "Vol." — an art book or guidebook included — is a
    /// wrong claim, not a missing nicety. See `volume`.
    let countType: String?

    enum CodingKeys: String, CodingKey {
        case id, seriesId, releaseDate, sequenceString, sequenceNumeric
        case pages, identifiers, links, collections, countType
        case prices = "price"
    }

    /// The series' title, which this endpoint carries under its collection
    /// rather than on the work itself.
    var title: String? {
        collections?.compactMap(\.title).first
    }

    /// "Vol. 11" for a main-run volume, "Extra 3" or "Other 1" for the two
    /// other `count_type`s the schema allows — calling an art book or a
    /// guidebook "Vol." would be a wrong claim, not a missing nicety. Nothing
    /// when the publisher did not number it at all.
    var volume: String? {
        guard let sequenceString, !sequenceString.isEmpty else { return nil }
        switch countType?.lowercased() {
        case "extra": return "Extra \(sequenceString)"
        case "other": return "Other \(sequenceString)"
        default: return "Vol. \(sequenceString)"
        }
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
    ///
    /// Gap 101: this used to hand back whatever `URL(string:)` accepted, with
    /// no scheme check — the same contributed-data risk `SeriesLink.safeURL`
    /// and `NewsItem.safeURL` already guard against, and the one this field
    /// had been missing. `SafeLink.web` refuses anything that is not an
    /// ordinary `http`/`https` link with a host, so a `javascript:` or
    /// schemeless value some publisher entry carries cannot become a live
    /// `Link` in `AnnouncedSection`.
    var publisherLink: URL? {
        guard let raw = links?.first(where: { $0.type == "publisher" })?.link else { return nil }
        return SafeLink.web(URL(string: raw))
    }

    /// The release day as a day in the reader's own calendar: local midnight
    /// of the printed date. For scheduling, where `date` — midnight UTC — is
    /// already in the past for a release dated today once UTC midnight has
    /// gone by, which is how "out today" was dropped on the only day it could
    /// fire.
    func localDay(calendar: Calendar = .current) -> Date? {
        guard let releaseDate else { return nil }
        let parts = releaseDate.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
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
