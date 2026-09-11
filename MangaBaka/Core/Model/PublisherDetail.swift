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
    let founded: Int?
    let closed: Bool?
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
        if let founded, founded > 0 { parts.append("Since \(founded)") }
        if closed == true { parts.append("Closed") }
        return parts.joined(separator: " · ")
    }
}
