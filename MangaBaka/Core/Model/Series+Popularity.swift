import Foundation

// Split out of Series.swift to keep it under the 400-code-line lint ceiling
// (`file_length`, `.swiftlint.yml`) once the v1 record's popularity/published
// fields landed. Same module, same `Series`, just a second file.

/// `popularity`, from `/v1/series/{id}`. Two independent leaderboards: a
/// global rank across every series MangaBaka tracks, and a rank within this
/// series' own `type` (manga/manhwa/manhua/novel/...). Each carries a rank
/// history at fixed lookback windows.
///
/// Measured against series 2060 (`series-2060-record-2026-09-15.json`,
/// under `data.popularity`) on 2026-09-15:
/// `{"global":{"current":14,"history":{"1d":14,"1w":14,"1mo":14,"3mo":11,
/// "6mo":11,"1y":18}},"type":{"current":2,"history":{...same keys...}}}`.
struct Popularity: Codable, Equatable, Sendable, Hashable {
    /// One leaderboard position, current plus its recent history.
    struct Rank: Codable, Equatable, Sendable, Hashable {
        let current: Int?
        /// Keyed by literal lookback strings — "1d", "1w", "1mo", "3mo",
        /// "6mo", "1y" on every record seen so far. Kept as a dictionary
        /// rather than an enum: a new lookback window the API adds later
        /// decodes here with no model change, where an enum would throw the
        /// whole `Popularity` away over one unrecognised key.
        let history: [String: Int]?
    }

    let global: Rank?
    let type: Rank?

    /// "#14 overall · #2 among manhwa". `typeWord` is a plural noun for the
    /// series' own `type` — see `Series.popularityTypeWord`, a guess at
    /// wording since the API names no display form for its type strings.
    /// Nil when there is no rank to report at all.
    func trendLine(typeWord: String?) -> String? {
        var parts: [String] = []
        if let overall = global?.current {
            parts.append("#\(overall) overall")
        }
        if let withinType = type?.current {
            if let typeWord {
                parts.append("#\(withinType) among \(typeWord)")
            } else {
                parts.append("#\(withinType) in its category")
            }
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " · ")
    }

    /// "was #18 a year ago" — only when the year-old global rank is on
    /// record and differs from today's; a rank that hasn't moved is not a
    /// trend worth a line.
    var yearAgoLine: String? {
        guard let current = global?.current,
              let yearAgo = global?.history?["1y"],
              yearAgo != current
        else { return nil }
        return "was #\(yearAgo) a year ago"
    }
}

/// `published`, from `/v1/series/{id}`. Separate from the plain `year` field
/// (which `/v1/series/{id}` also sends): this carries the full start/end
/// dates and whether either is a guess, which `year` alone cannot say.
///
/// Measured against series 2060 on 2026-09-15: `{"start_date":"2020-05-26",
/// "end_date":null,"start_date_is_estimated":false,
/// "end_date_is_estimated":null}`.
struct Published: Codable, Equatable, Sendable, Hashable {
    /// "YYYY-MM-DD", per the fixture. Kept as a string rather than parsed to
    /// a `Date`: `rangeLine` only ever needs the leading year, and a
    /// malformed date string should not cost the whole field.
    let startDate: String?
    let endDate: String?
    let startDateIsEstimated: Bool?
    let endDateIsEstimated: Bool?

    private static func leadingYear(of dateString: String?) -> String? {
        guard let dateString, dateString.count >= 4 else { return nil }
        return String(dateString.prefix(4))
    }

    /// "2020 – ongoing", "2015 – 2021", or "c. 2020 – ongoing" when the start
    /// date is estimated ("c." for circa — a guess at wording, not API text).
    /// The end year gets the same "c." treatment when it, rather than the
    /// start, is the estimated half. Nil when there is no start date to
    /// anchor the line on at all.
    var rangeLine: String? {
        guard let startYear = Self.leadingYear(of: startDate) else { return nil }
        let startPrefix = startDateIsEstimated == true ? "c. " : ""
        if let endYear = Self.leadingYear(of: endDate) {
            let endPrefix = endDateIsEstimated == true ? "c. " : ""
            return "\(startPrefix)\(startYear) – \(endPrefix)\(endYear)"
        }
        return "\(startPrefix)\(startYear) – ongoing"
    }
}

/// One entry of `secondary_titles`, e.g. `{"type":"unknown","title":"ORV",
/// "note":null}`. `title` is the only field every entry actually carries.
struct SecondaryTitle: Codable, Equatable, Sendable, Hashable {
    let type: String?
    let title: String
    let note: String?
}

/// `relationships_v2`, decode-only for now — display is a follow-up.
///
/// Measured against series 2060 on 2026-09-15: `chronology` is `"unknown"`
/// on both of its entries, and on every entry in `library.json` and
/// `mix.json` too (grepped 2026-09-15) — no other value has been observed
/// live, so `"before"`/`"after"` above are the documented possibilities, not
/// confirmed ones. This is the reading-order hint the separate
/// `/relationships` endpoint does not carry.
struct RelationshipV2: Codable, Equatable, Sendable, Hashable {
    let id: String
    let toSeriesId: Int
    /// "source", "other", and similar — same vocabulary as `/relationships`.
    let relationType: String?
    let chronology: String?
    let note: String?
}

extension Series {
    /// A plural noun for this series' own `type`, for `popularityTrendLine`.
    /// A guess: the API gives no display name for its type strings, only the
    /// lowercase wire values ("manga", "manhwa", "manhua", "novel", "oel",
    /// "other") already used elsewhere in this file (`impliedLanguage`).
    var popularityTypeWord: String? {
        switch type?.lowercased() {
        case "manga": "manga"
        case "manhwa": "manhwa"
        case "manhua": "manhua"
        case "novel": "novels"
        default: nil
        }
    }

    /// The full popularity line for `DetailStatsStrip`: the rank trend, plus
    /// the year-ago comparison when there is one to show. Nil when
    /// `popularity` itself is nil, or carries no rank at all.
    var popularityTrendLine: String? {
        guard let popularity else { return nil }
        guard let trend = popularity.trendLine(typeWord: popularityTypeWord) else { return nil }
        guard let yearAgo = popularity.yearAgoLine else { return trend }
        return "\(trend) — \(yearAgo)"
    }
}
