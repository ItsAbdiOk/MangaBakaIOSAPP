import Foundation

/// A publisher in full: `/v1/publishers/{id}/full`.
///
/// Verified live on Ize Press (21), 2026-09-11: an imprint of Yen Press (18),
/// US, both physical and digital, two social links, a one-line note, no
/// description, no founding year. Everything optional but the name, because
/// the smaller publishers carry almost none of it.
struct PublisherDetail: Decodable, Sendable, Equatable {
    struct Link: Decodable, Sendable, Equatable {
        let type: String?
        let link: String?
        let language: String?

        /// Only a web link is opened; see `SafeLink`.
        var safeURL: URL? { SafeLink.web(link.flatMap(URL.init(string:))) }
    }

    struct Parent: Decodable, Sendable, Equatable {
        let id: Int?
        let name: String
    }

    let id: Int
    let name: String
    /// "publisher" or "imprint".
    let type: String?
    /// "physical", "digital" or "both".
    let subType: String?
    let countryOfOrigin: String?
    /// `string|null, format: date` (`docs/schemas/mangabaka_openapi.json`,
    /// `/v1/publishers/{id}/full`) — live 2026-09-13, Kodansha USA sends
    /// `"2008-07-01"`. Typed as `Int?` until then, which was never observed
    /// wrong because Ize Press and Yen Press both happen to have
    /// `founded: null`; the whole detail decode was under `try?`
    /// (`CatalogueService.swift:126`), so a founded publisher's page opened
    /// with no record and no error. `summary` derives the year.
    let founded: String?
    /// Also `string|null, format: date`, not a `Bool`: the closing date, when
    /// known. Presence is "closed", not the value itself.
    let closed: String?
    let languages: [String]?
    let note: String?
    let description: String?
    let parent: Parent?
    let links: [Link]?

    /// "Imprint of Yen Press · US · Print and digital · Since 1994".
    var summary: String {
        var parts: [String] = []
        if let parent, type?.lowercased() == "imprint" {
            parts.append("Imprint of \(parent.name)")
        } else if let type, !type.isEmpty {
            parts.append(type.capitalized)
        }
        if let country = countryOfOrigin, !country.isEmpty {
            parts.append(Locale.current.localizedString(forRegionCode: country) ?? country)
        }
        switch subType?.lowercased() {
        case "both": parts.append("Print and digital")
        case "physical": parts.append("Print")
        case "digital": parts.append("Digital")
        default: break
        }
        if let year = Self.year(from: founded) { parts.append("Since \(year)") }
        if closed != nil { parts.append("Closed") }
        return parts.joined(separator: " · ")
    }

    /// The calendar year out of a `yyyy-MM-dd` (or any `yyyy`-prefixed) date
    /// string. `String(prefix(4))` rather than a `DateFormatter`: nothing here
    /// needs the day or month, and the wire has only ever shown the full date
    /// form, but a formatter would throw the whole field away if that ever
    /// changed to a bare year.
    private static func year(from date: String?) -> String? {
        guard let date, date.count >= 4 else { return nil }
        let year = date.prefix(4)
        return year.allSatisfy(\.isNumber) ? String(year) : nil
    }
}
