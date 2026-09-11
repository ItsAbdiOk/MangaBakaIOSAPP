import Foundation

/// One published edition of one volume.
///
/// A "work" in MangaBaka's vocabulary is a physical or digital edition, not a
/// volume: Solo Leveling volume 1 appears twice in
/// `/v1/series/3397/works`, once at $9.99 and once at $20, distinguished only
/// by their ISBNs and their prices. Verified live on 2026-09-11. Anything that
/// lists these without grouping them looks duplicated and broken.
struct SeriesWork: Codable, Identifiable, Sendable, Equatable {
    struct Price: Codable, Sendable, Equatable {
        let value: Double
        let isoCode: String?
    }

    struct Identifier: Codable, Sendable, Equatable {
        let id: String?
        let name: String?
    }

    struct Link: Codable, Sendable, Equatable {
        let type: String?
        let link: String?
    }

    /// A cover for this edition. The `image` object is the same shape `Cover`
    /// already decodes from `/v1/my/*`, so it needs no second decoder.
    struct Image: Codable, Sendable, Equatable {
        let image: Cover?
        let type: String?
    }

    let id: String
    /// As printed on the spine, which is not always a number.
    let sequenceString: String?
    let sequenceNumeric: Double?
    let subTitle: String?
    /// ISO-8601 date, "2021-03-02".
    let releaseDate: String?
    let pages: Int?
    let prices: [Price]?
    let identifiers: [Identifier]?
    let links: [Link]?
    let images: [Image]?

    enum CodingKeys: String, CodingKey {
        case id, sequenceString, sequenceNumeric, subTitle, releaseDate
        case pages, identifiers, links, images
        case prices = "price"
    }

    /// The ISBN, where the publisher registered one. It is also what tells two
    /// editions of the same volume apart.
    var isbn: String? {
        identifiers?.first { $0.name?.lowercased() == "isbn" }?.id
    }

    /// The publisher's list price, in one currency, formatted.
    ///
    /// USD where offered, because every edition in the sample carried it.
    /// Never converted — this is someone else's shop's price in the currency
    /// they set it in.
    var price: String? {
        guard let prices, !prices.isEmpty else { return nil }
        let chosen = prices.first { $0.isoCode?.lowercased() == "usd" } ?? prices[0]
        var format = FloatingPointFormatStyle<Double>.Currency(code: chosen.isoCode ?? "usd")
        format = format.locale(Locale(identifier: "en_US"))
        return chosen.value.formatted(format)
    }

    var cover: Cover? { images?.compactMap(\.image).first }

    var date: Date? {
        guard let releaseDate else { return nil }
        return Self.formatter.date(from: releaseDate)
    }

    /// Where to buy it, when the publisher gave a link.
    var buyLink: URL? {
        guard let raw = links?.first(where: { $0.type == "publisher" })?.link else { return nil }
        return SafeLink.web(URL(string: raw))
    }

    /// Dates only, fixed to UTC — a release date is a calendar day rather than
    /// an instant, and parsing it in the device's zone puts it on the previous
    /// day west of UTC.
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

extension SeriesWork {
    /// One volume, and every edition of it.
    struct Volume: Codable, Identifiable, Sendable, Equatable {
        /// "1", "11", or whatever is on the spine.
        let number: String
        let editions: [SeriesWork]

        var id: String { number }

        /// The first edition that carries artwork. Editions of a volume share
        /// the same art often enough that picking the first is right, and when
        /// they do not, the cheapest is usually the one people recognise.
        var cover: Cover? { editions.compactMap(\.cover).first }

        /// The earliest date any edition of this volume was published.
        var date: Date? { editions.compactMap(\.date).min() }

        var subTitle: String? { editions.compactMap(\.subTitle).first }
        var pages: Int? { editions.compactMap(\.pages).first }

        /// "Vol. 1"
        var label: String { "Vol. \(number)" }
    }

    /// Editions gathered into volumes, in spine order.
    ///
    /// Sorted by `sequence_numeric` where the API gave one, because "10" sorts
    /// before "2" as a string and a volume list in that order is unreadable.
    /// Anything without a number keeps the API's own order at the end — a
    /// side story or a box set is still worth showing, just not worth
    /// pretending to place.
    static func volumes(from works: [SeriesWork]) -> [Volume] {
        var byNumber: [String: [SeriesWork]] = [:]
        var order: [String] = []
        for work in works {
            guard let number = work.sequenceString, !number.isEmpty else { continue }
            if byNumber[number] == nil { order.append(number) }
            byNumber[number, default: []].append(work)
        }
        let volumes = order.map { Volume(number: $0, editions: byNumber[$0] ?? []) }
        return volumes.sorted { lhs, rhs in
            let left = lhs.editions.compactMap(\.sequenceNumeric).min()
            let right = rhs.editions.compactMap(\.sequenceNumeric).min()
            switch (left, right) {
            case let (lhsValue?, rhsValue?): return lhsValue < rhsValue
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return false
            }
        }
    }
}
