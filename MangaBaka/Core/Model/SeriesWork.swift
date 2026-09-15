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

    /// The catalogue blurb, wire shape `{"desc": "...", "source": "..."}`.
    /// Only `desc` is kept — `source` (a publisher/site attribution string,
    /// e.g. "Ize Press") is not shown anywhere yet and would need its own
    /// design pass before it is.
    struct Description: Codable, Sendable, Equatable {
        let desc: String?
    }

    /// The physical trim size, in millimetres. Verified against
    /// `series-2060-works-2026-09-15.json`: every row carries the same
    /// `146.049…× 209.549…`, i.e. 5.75 × 8.25 inches, a standard manga
    /// paperback trim — so the two-decimal noise is a unit-conversion
    /// artifact upstream, not per-volume precision worth keeping.
    ///
    /// UNSURE: typed from three rows of one series, all identical. Both
    /// fields optional and decoded leniently — `try?` per field rather than
    /// the synthesised decoder — so a row from a different series that sends
    /// `null` or an unexpected shape for one of them costs that one
    /// dimension, not the whole edition via `LossyArray` (wire review
    /// W9/W12/P9/P12, 2026-09-15). `trimLine` already handles either being
    /// nil.
    struct Trim: Codable, Sendable, Equatable {
        let wMm: Double?
        let hMm: Double?

        private enum CodingKeys: String, CodingKey { case wMm, hMm }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            wMm = try? container.decodeIfPresent(Double.self, forKey: .wMm)
            hMm = try? container.decodeIfPresent(Double.self, forKey: .hMm)
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encodeIfPresent(wMm, forKey: .wMm)
            try container.encodeIfPresent(hMm, forKey: .hMm)
        }
    }

    struct Link: Codable, Sendable, Equatable {
        let type: String?
        let link: String?
    }

    /// A cover for this edition. The `image` object is the same shape `Cover`
    /// already decodes from `/v1/my/*`, so it needs no second decoder.
    ///
    /// UNSURE: `series-2060-works-2026-09-15.json` has `images: []` on all
    /// three sampled rows, so no live payload has actually exercised this
    /// decode. `image` is decoded leniently — `try?`, not the synthesised
    /// decoder — so a row whose `image` object `Cover.init(from:)` cannot
    /// parse drops just that field to nil rather than the whole edition
    /// (wire review W12/P12, 2026-09-15).
    struct Image: Codable, Sendable, Equatable {
        let image: Cover?
        let type: String?

        /// Memberwise, because the hand-written `init(from:)` below replaces
        /// the synthesised one and the test factories build images directly.
        init(image: Cover?, type: String?) {
            self.image = image
            self.type = type
        }

        private enum CodingKeys: String, CodingKey { case image, type }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            image = try? container.decodeIfPresent(Cover.self, forKey: .image)
            type = try? container.decodeIfPresent(String.self, forKey: .type)
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encodeIfPresent(image, forKey: .image)
            try container.encodeIfPresent(type, forKey: .type)
        }
    }

    /// `inc_chapters` is `null` in every row of
    /// `series-2060-works-2026-09-15.json`, and no other live payload has
    /// been checked (2026-09-15). UNSURE: modeled leniently as a string that
    /// also accepts a bare number, matching the pattern
    /// `KeyedDecodingContainer.lenientDouble` in Series.swift uses for the
    /// same problem elsewhere — a guess at the eventual shape, not a
    /// verified one. Decoded only; nothing displays it yet.
    struct IncludedChapters: Codable, Sendable, Equatable {
        let raw: String

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let string = try? container.decode(String.self) {
                raw = string
            } else {
                raw = String(try container.decode(Double.self))
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(raw)
        }
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
    /// The catalogue blurb. Absent on old cached rows (pre-2026-09-15).
    ///
    /// Defaulted to `nil` — not just optional — so the memberwise
    /// initializer stays source-compatible with the fixed call sites in
    /// `VolumeEditionMergeTests`, `DetailFidelityTests` and
    /// `NextVolumeSnapshotTests`, none of which are in scope for this change
    /// and none of which pass this field.
    var description: Description?
    /// The physical trim size. Absent on old cached rows.
    var trim: Trim?
    /// "main" or "extra" — the only two values seen live, in
    /// `series-2060-works-2026-09-15.json` (every sampled row is "main"; the
    /// series' own collection metadata puts `count_extra` at 0, so this
    /// fixture never exercises "extra" — `SeriesWorkFieldsTests` covers it
    /// with hand-written JSON instead).
    var countType: String?
    /// Non-nil when this edition is bound together with another volume
    /// (an omnibus naming the volume it is *part of*). `null` in the
    /// fixture; tested with hand-written JSON.
    var partOfVolume: String?
    /// See `IncludedChapters` — decoded, shown nowhere.
    var incChapters: IncludedChapters?
    /// A catalogue note from the publisher/source, shown verbatim.
    ///
    /// These six are `var` with no initial value, not `let … = nil`: a `let`
    /// with a default is skipped by the synthesised decoder, so every one of
    /// them decoded as nil on the first run (2026-09-15) and the memberwise
    /// init still needs them optional-with-default for the older call sites.
    var note: String?

    enum CodingKeys: String, CodingKey {
        case id, sequenceString, sequenceNumeric, subTitle, releaseDate
        case pages, identifiers, links, images
        case prices = "price"
        case description, trim, countType, partOfVolume, incChapters, note
    }

    /// The ISBN, where the publisher registered one. It is also what tells two
    /// editions of the same volume apart.
    var isbn: String? {
        identifiers?.first { $0.name?.lowercased() == "isbn" }?.id
    }

    /// Which of several prices to show, given the reader's own currency code
    /// (lowercased ISO, e.g. `"cad"`) — the reader's own currency if the
    /// publisher listed one in it, otherwise whichever the publisher listed
    /// first. A pure function of the list, not `Locale.current` itself, so
    /// `SeriesWorkFieldsTests` can inject a currency without depending on the
    /// test machine's locale.
    static func pickPrice(from prices: [Price], preferredCurrencyCode: String?) -> Price? {
        let priced = prices.filter { $0.value != nil }
        guard let preferredCurrencyCode else { return priced.first }
        return priced.first { $0.isoCode?.lowercased() == preferredCurrencyCode.lowercased() }
            ?? priced.first
    }

    /// The publisher's list price, in one currency, formatted.
    ///
    /// Prefers the reader's own currency (`Locale.current.currency`), falling
    /// back to whichever the publisher listed first when theirs is not one of
    /// the options — see `pickPrice`. Never converted — this is someone
    /// else's shop's price in the currency they set it in, just picked to
    /// match the reader rather than always defaulting to USD.
    var price: String? {
        let preferred = Locale.current.currency?.identifier.lowercased()
        guard let chosen = Self.pickPrice(from: prices ?? [], preferredCurrencyCode: preferred),
              let value = chosen.value
        else { return nil }
        var format = FloatingPointFormatStyle<Double>.Currency(code: chosen.isoCode ?? "usd")
        format = format.locale(Locale(identifier: "en_US"))
        return value.formatted(format)
    }

    /// "146 × 210 mm", rounded to whole millimetres — the fixture's own
    /// `146.049… × 209.549…` printed to two decimals would read as false
    /// precision nobody asked for.
    ///
    /// `Int(_:)` traps outside roughly ±9.2e18; a server value that large
    /// for a millimetre trim is absurd but not something the wire type
    /// guards against, and `Int(wholeOrClamped:)` is the same belt-and-
    /// braces fix already applied to the identical pattern in
    /// `CommunityPulse.swift:75` (wire review W9/P9, 2026-09-15).
    var trimLine: String? {
        guard let trim, let wMm = trim.wMm, let hMm = trim.hMm else { return nil }
        return "\(Int(wholeOrClamped: wMm.rounded())) × \(Int(wholeOrClamped: hMm.rounded())) mm"
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
    ///
    /// `yyyy-MM-dd` only: the spec gives `release_date` no `format` at all.
    /// Checked against `/v1/works/upcoming` live on 2026-09-13 — 50 of 50
    /// `release_date` values were exactly 10 characters, i.e. this shape —
    /// so a partial ("2026-11") or timestamped form has not been seen, but
    /// nothing rules it out for an announced-but-unscheduled volume, which is
    /// exactly the kind of release a reader is waiting on. If one ever shows
    /// up, `date` silently returns nil for it today rather than throwing.
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

        /// The catalogue blurb, from whichever edition carries one. Whether
        /// it duplicates the series' own description is not this type's call
        /// to make — `Volume` has no way to see the series record at all —
        /// so `VolumeSheet` does that comparison itself, against whatever
        /// series description its caller gives it (which may be none; see
        /// `VolumeSheet.seriesDescription`).
        var blurb: String? { editions.compactMap { $0.description?.desc }.first }

        /// "146 × 210 mm", from whichever edition carries a trim size.
        var trimLine: String? { editions.compactMap(\.trimLine).first }

        /// True when any edition is flagged `count_type == "extra"`. Values
        /// seen live: "main" for every sampled row in
        /// `series-2060-works-2026-09-15.json` — that fixture never
        /// exercises "extra", so this is covered by hand-written JSON in
        /// `SeriesWorkFieldsTests`. Checking "any" rather than "all" errs
        /// toward showing the chip: a volume mixing the two is not expected,
        /// but there is no reason to hide it if it happens.
        var isExtra: Bool { editions.contains { $0.countType == "extra" } }

        /// "Part of volume N", from whichever edition names one. `nil` in
        /// the live fixture; tested with hand-written JSON.
        var partOfVolumeLabel: String? {
            editions.compactMap(\.partOfVolume).first.map { "Part of volume \($0)" }
        }

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
