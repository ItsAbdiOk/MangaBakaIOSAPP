import Foundation

/// A published edition of a series: one publisher's release, in one language.
///
/// The API calls these "collections", and the mockup has an "In collections"
/// row on the series page — drawing *other series' covers* in it. That row
/// could never have worked: checked against the live endpoint on 2026-09-10,
/// `/v1/series/{id}/collections` returns editions of the series you asked
/// about, every one carrying the same `series_id`. The mockup's row was built
/// from a hardcoded list of unrelated series, so it was showing placeholder
/// content that happened to look like a feature.
///
/// What the data actually answers is a better question anyway, and one nothing
/// else in the app answers: *can I buy this in my language, and how far along
/// is it?*
struct SeriesEdition: Codable, Identifiable, Sendable, Equatable {
    struct Language: Codable, Sendable, Equatable {
        let iso: String?
        /// "English (English)" — the API's own doubled form.
        let language: String?
    }

    struct Publisher: Codable, Sendable, Equatable {
        let id: Int?
        let name: String?
        /// "imprint", "publisher".
        let type: String?
    }

    /// The named release within a collection ("Standard Edition", a deluxe
    /// reprint, ...). Decoded from the `edition` object on each collections
    /// row.
    struct Detail: Codable, Sendable, Equatable {
        let id: String?
        let name: String?
        let language: Language?
        let description: String?
        let overrideText: String?
    }

    /// A link attached to one collection row. Shaped differently from
    /// `SeriesLink` — `link` rather than `url`, no id or display name — so it
    /// is its own type rather than a reuse that would decode the wrong keys.
    struct CollectionLink: Codable, Sendable, Equatable {
        let type: String?
        let link: URL?
        let language: String?
    }

    /// The long-form blurb on a collection row. Decoded only: it duplicates
    /// the series blurb shown elsewhere on the measured page, so nothing
    /// displays it here.
    struct Blurb: Codable, Sendable, Equatable {
        let desc: String?
    }

    let id: String
    let title: String?
    let language: Language?
    let publisher: Publisher?
    /// `digital | paperback | hardcover` — the spec's enum
    /// (`docs/schemas/mangabaka_openapi.json`, `/v1/series/{id}/collections`).
    /// This comment used to say "digital", "print", values the spec does not
    /// have.
    let medium: String?
    /// The series-status vocabulary (`completed | releasing | hiatus |
    /// cancelled | upcoming | unknown`), not "complete", "ongoing",
    /// "cancelled" as this comment used to claim. See `SeriesStatus`, which
    /// already turns these into words a reader uses; `detail` below reads it
    /// through that rather than printing the raw value.
    let status: String?
    /// Whether it is an official licensed release rather than a scanlation.
    let licensed: Bool?
    /// Volumes in the main run, as opposed to extras and side stories.
    let countMain: Int?
    let countExtra: Int?
    let startDate: String?
    let endDate: String?
    // These six are new (2026-09-15). Each is `var` rather than `let` and
    // carries no explicit initializer: an optional `var` with no initializer
    // is implicitly `nil`, and — unlike an optional `let` in the same
    // state — Swift's synthesized memberwise init treats it as defaulted,
    // which is what keeps `EditionLabelTests`'s existing call site (built
    // before any of this existed) compiling untouched. Writing `= nil`
    // explicitly trips SwiftLint's `implicit_optional_initialization`.
    /// "ltr" or "rtl", as seen on series 2060's collections row
    /// (2026-09-15). Any other value is left unlabelled by `readingLabel`
    /// rather than guessed at.
    var reading: String?
    /// "paged" or "webtoon", as seen on series 2060's collections row
    /// (2026-09-15). Shown capitalised by `formatLabel` only for those two
    /// values.
    var format: String?
    /// The named release ("Standard Edition", a deluxe reprint, ...).
    var edition: Detail?
    /// Links attached to this row — a publisher page, most usefully.
    var links: [CollectionLink]?
    /// How many releases beyond the main run and its extras exist for this
    /// edition. Decoded only; no design has asked for it yet.
    var countOther: Int?
    /// Freeform note on the row, shown verbatim when present.
    var note: String?
    /// The long blurb the row carries. Decoded only — it duplicates the
    /// series blurb shown elsewhere on the measured page, so nothing here
    /// displays it.
    var description: Blurb?

    /// "Left to right" / "Right to left", or nothing for a value not seen on
    /// the wire — an unrecognised direction is not worth guessing at.
    var readingLabel: String? {
        switch reading {
        case "ltr": "Left to right"
        case "rtl": "Right to left"
        default: nil
        }
    }

    /// "Paged" / "Webtoon", capitalised only for the two values verified
    /// against series 2060 (2026-09-15).
    var formatLabel: String? {
        switch format {
        case "paged": "Paged"
        case "webtoon": "Webtoon"
        default: nil
        }
    }

    /// The first publisher link on the row, opened only if it is an ordinary
    /// web link — this is community-maintained data. Same reasoning as
    /// `SeriesLink.safeURL`.
    var publisherLinkURL: URL? {
        links?.first { $0.type == "publisher" }.flatMap { SafeLink.web($0.link) }
    }

    /// "English · Ize Press · Standard Edition", the edition name added only
    /// when it says more than the API's own default. "Standard Edition" adds
    /// nothing a reader didn't already know.
    var headline: String {
        var parts = [
            language?.iso?.uppercased(),
            publisher?.name
        ].compactMap { $0 }
        if let name = edition?.name, !name.isEmpty, name != "Standard Edition" {
            parts.append(name)
        }
        return parts.isEmpty ? (title ?? "Edition") : parts.joined(separator: " · ")
    }

    /// "12 volumes · paged · Completed · Left to right". Only what the API
    /// answered — a missing field is left out rather than printed as unknown.
    var detail: String? {
        var parts: [String] = []
        if let countMain, countMain > 0 {
            parts.append("\(countMain) volume\(countMain == 1 ? "" : "s")")
        }
        if let medium, !medium.isEmpty { parts.append(medium) }
        if let formatLabel { parts.append(formatLabel) }
        if let label = SeriesStatus.label(for: status) { parts.append(label) }
        if let readingLabel { parts.append(readingLabel) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Year the edition began, when the API gave a date at all.
    var startYear: String? {
        guard let startDate, startDate.count >= 4 else { return nil }
        return String(startDate.prefix(4))
    }
}

extension [SeriesEdition] {
    /// Official releases first, then the biggest runs, then by language so the
    /// order is stable.
    ///
    /// Official first because that is the one a reader can actually buy, and a
    /// scanlation listed above the licensed English release would be the wrong
    /// answer to the question the section exists to answer.
    var presentable: [SeriesEdition] {
        sorted { lhs, rhs in
            let leftLicensed = lhs.licensed == true
            let rightLicensed = rhs.licensed == true
            if leftLicensed != rightLicensed { return leftLicensed }

            let leftCount = lhs.countMain ?? 0
            let rightCount = rhs.countMain ?? 0
            if leftCount != rightCount { return leftCount > rightCount }

            return (lhs.language?.iso ?? "") < (rhs.language?.iso ?? "")
        }
    }
}
