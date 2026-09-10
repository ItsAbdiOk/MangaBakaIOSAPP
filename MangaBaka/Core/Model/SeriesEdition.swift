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
struct SeriesEdition: Decodable, Identifiable, Sendable, Equatable {
    struct Language: Decodable, Sendable, Equatable {
        let iso: String?
        /// "English (English)" — the API's own doubled form.
        let language: String?
    }

    struct Publisher: Decodable, Sendable, Equatable {
        let id: Int?
        let name: String?
        /// "imprint", "publisher".
        let type: String?
    }

    let id: String
    let title: String?
    let language: Language?
    let publisher: Publisher?
    /// "digital", "print".
    let medium: String?
    /// "complete", "ongoing", "cancelled".
    let status: String?
    /// Whether it is an official licensed release rather than a scanlation.
    let licensed: Bool?
    /// Volumes in the main run, as opposed to extras and side stories.
    let countMain: Int?
    let countExtra: Int?
    let startDate: String?
    let endDate: String?

    /// "English · Ize Press", the two things a reader is looking for.
    var headline: String {
        let parts = [
            language?.iso?.uppercased(),
            publisher?.name
        ].compactMap { $0 }
        return parts.isEmpty ? (title ?? "Edition") : parts.joined(separator: " · ")
    }

    /// "12 volumes · print · complete". Only what the API answered — a missing
    /// field is left out rather than printed as unknown.
    var detail: String? {
        var parts: [String] = []
        if let countMain, countMain > 0 {
            parts.append("\(countMain) volume\(countMain == 1 ? "" : "s")")
        }
        if let medium, !medium.isEmpty { parts.append(medium) }
        if let status, !status.isEmpty { parts.append(status) }
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
