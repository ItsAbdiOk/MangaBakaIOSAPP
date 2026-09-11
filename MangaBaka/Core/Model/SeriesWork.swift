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
        /// Nullable on the wire (`V1_Price.value`). Non-optional here until
        /// 2026-09-11, when one unpriced edition threw the whole volumes
        /// array and the section vanished — the same bug the calendar had.
        let value: Double?
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
        let priced = (prices ?? []).filter { $0.value != nil }
        guard let chosen = priced.first(where: { $0.isoCode?.lowercased() == "usd" }) ?? priced.first,
              let value = chosen.value
        else { return nil }
        var format = FloatingPointFormatStyle<Double>.Currency(code: chosen.isoCode ?? "usd")
        format = format.locale(Locale(identifier: "en_US"))
        return value.formatted(format)
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

    /// The calendar year of a release date, fixed to UTC to match how
    /// `date` itself is parsed — a device-zone calendar can push a date
    /// west of UTC onto the previous year.
    fileprivate static func utcYear(of date: Date) -> Int {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        return utc.component(.year, from: date)
    }

    /// The median of an already-sorted, non-empty list of page counts.
    fileprivate static func median(of sorted: [Int]) -> Double {
        let count = sorted.count
        if count % 2 == 1 { return Double(sorted[count / 2]) }
        return Double(sorted[count / 2 - 1] + sorted[count / 2]) / 2
    }
}

extension SeriesWork {
    /// One volume, and every edition of it.
    struct Volume: Codable, Identifiable, Sendable, Equatable {
        /// "1", "11", or whatever is on the spine. Nil for the editions the
        /// API gave no number — a box set, a side story — which sit together
        /// at the end.
        let number: String?
        let editions: [SeriesWork]

        var id: String { number ?? "other" }

        /// The first edition that carries artwork. Editions of a volume share
        /// the same art often enough that picking the first is right, and when
        /// they do not, the cheapest is usually the one people recognise.
        var cover: Cover? { editions.compactMap(\.cover).first }

        /// The earliest date any edition of this volume was published.
        var date: Date? { editions.compactMap(\.date).min() }

        var subTitle: String? { editions.compactMap(\.subTitle).first }
        var pages: Int? { editions.compactMap(\.pages).first }

        /// "Vol. 1", or "Other editions" for the numberless.
        var label: String { number.map { "Vol. \($0)" } ?? "Other editions" }

        /// A short, honest label per edition, keyed by `SeriesWork.id`.
        ///
        /// `/v1/series/{id}/works` carries no format/binding field (verified
        /// 2026-09-11), so an edition can never be called "paperback" or
        /// "digital" — that would be invented. This leans only on what the
        /// API actually gives us and differs between editions: the release
        /// year, an oversized page count (a labelled GUESS at an omnibus),
        /// and, if editions still read identical after that, the ISBN
        /// suffix as a last resort — so two cards for the same volume never
        /// say the same thing. A volume with a single edition gets no
        /// labels: there is nothing to tell it apart from.
        var editionLabels: [String: String] {
            guard editions.count > 1 else { return [:] }

            let years = editions.compactMap { $0.date.map { SeriesWork.utcYear(of: $0) } }
            let yearsDiffer = Set(years).count > 1

            let pageCounts = editions.compactMap(\.pages).sorted()
            let medianPages = pageCounts.isEmpty ? nil : SeriesWork.median(of: pageCounts)

            var parts: [String: [String]] = [:]
            for edition in editions {
                var editionParts: [String] = []
                if yearsDiffer, let date = edition.date {
                    editionParts.append(String(SeriesWork.utcYear(of: date)))
                }
                if let pages = edition.pages, let medianPages,
                   Double(pages) >= 2.2 * medianPages {
                    // GUESS: there is no format field to confirm this. The
                    // 2.2x-median threshold is picked to catch Hunter x
                    // Hunter vol. 8's 616pp 3-in-1 against its ~195-200pp
                    // single editions, without flagging a volume that is
                    // merely long.
                    editionParts.append("likely an omnibus")
                }
                parts[edition.id] = editionParts
            }

            // If two editions still read the same after year and page-count
            // labelling, fall back to the ISBN suffix so no two cards ever
            // read identically — the reader's actual complaint.
            let counts = Dictionary(grouping: parts.values) { $0.joined(separator: " · ") }
            let duplicated = Set(counts.filter { $0.value.count > 1 }.keys)
            if !duplicated.isEmpty {
                for edition in editions {
                    guard let editionParts = parts[edition.id],
                          duplicated.contains(editionParts.joined(separator: " · ")),
                          let isbn = edition.isbn, isbn.count >= 4
                    else { continue }
                    parts[edition.id, default: []].append("ISBN …\(isbn.suffix(4))")
                }
            }

            var labels: [String: String] = [:]
            for (id, editionParts) in parts where !editionParts.isEmpty {
                labels[id] = editionParts.joined(separator: " · ")
            }
            return labels
        }
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
        var unnumbered: [SeriesWork] = []
        for work in works {
            guard let number = work.sequenceString, !number.isEmpty else {
                // Kept, as the comment above has always promised. The loop
                // used to `continue` past these, and the nil-handling in the
                // sort below was dead work.
                unnumbered.append(work)
                continue
            }
            if byNumber[number] == nil { order.append(number) }
            byNumber[number, default: []].append(work)
        }
        let volumes = order.map { Volume(number: $0, editions: byNumber[$0] ?? []) }
        let others = unnumbered.isEmpty ? [] : [Volume(number: nil, editions: unnumbered)]
        return volumes.sorted { lhs, rhs in
            let left = lhs.editions.compactMap(\.sequenceNumeric).min()
            let right = rhs.editions.compactMap(\.sequenceNumeric).min()
            switch (left, right) {
            case let (lhsValue?, rhsValue?): return lhsValue < rhsValue
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return false
            }
        } + others
    }
}
