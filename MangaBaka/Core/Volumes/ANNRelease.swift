import Foundation

/// One `<release>` element off Anime News Network's Encyclopedia API, exactly
/// as it arrives.
///
/// Recorded shape, `api.xml?title=17164`, fetched 2026-09-14 (HTTP 200,
/// 5,551 bytes, `text/xml;charset=UTF-8`):
///
/// ```xml
/// <release date="2017-05-23" href="https://www.animenewsnetwork.com/encyclopedia/releases.php?id=32917"
///          ean="9780316471855">Delicious in Dungeon (GN 1)</release>
/// ```
///
/// Fifteen of these came back in that one request, which is the whole reason
/// this source exists: GCD needs 1 + N for the same list.
struct ANNRelease: Sendable, Equatable {
    let date: String?
    /// The Encyclopedia entry for this release. **This is the link ANN's
    /// terms require on the row** — see
    /// `VolumeCatalogue.requiresPerEntryLink`.
    let href: URL?
    /// ISBN-13. ANN calls it `ean`; every value observed was a 13-digit ISBN.
    let ean: String?
    /// "Delicious in Dungeon (GN 1)".
    let text: String
}

/// One `<manga>` record, parsed.
struct ANNEntry: Sendable, Equatable {
    let id: Int?
    let name: String?
    let releases: [ANNRelease]
    /// ANN answers a lookup that matched nothing with `<warning>` rather than
    /// a 404, so a successful HTTP request can still be a miss. A non-nil
    /// warning with no releases is `notCatalogued`, not a failure.
    let warning: String?
}

/// Reading ANN's XML, and turning its releases into shelf volumes.
enum ANNEncyclopedia {
    /// Everything inside the last pair of parentheses, when the title ends
    /// with them. "Delicious in Dungeon (GN 1)" → "GN 1".
    ///
    /// ANN's release titles end in a format marker and usually a number:
    /// `(GN 1)`, `(eBook 12)`, `(Artbook 1)`, `(GN 91-111)` for a box set,
    /// and `(GN)` with no number at all. Everything before it is the series'
    /// own title as ANN writes it.
    ///
    /// Deliberately not a regex. The shape is "the bracket at the end", the
    /// split below is a whitespace split, and a pattern for it would have
    /// been three captures wide for no more accuracy — and the typed-capture
    /// tuple trips `large_tuple` besides.
    nonisolated static func trailingMarker(in title: String) -> Substring? {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasSuffix(")"), let open = trimmed.lastIndex(of: "(") else { return nil }
        let inner = trimmed[trimmed.index(after: open)..<trimmed.index(before: trimmed.endIndex)]
        return inner.isEmpty ? nil : inner
    }

    /// The parsed `<manga>` record, or nil when the document was not ANN XML
    /// at all.
    nonisolated static func parse(_ data: Data) -> ANNEntry? {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse(), delegate.sawRoot else { return nil }
        return ANNEntry(
            id: delegate.mangaID, name: delegate.mangaName,
            releases: delegate.releases, warning: delegate.warning
        )
    }

    /// Every release ANN listed, as shelf volumes on one English edition.
    ///
    /// **Language is hard-coded "en", and that is a measurement, not a
    /// shortcut.** ANN's Encyclopedia releases are the English licensed print
    /// market: every release observed across One Piece (232), The Apothecary
    /// Diaries (15) and Delicious in Dungeon (15) is an English-language
    /// edition with a US on-sale date (`docs/sources/publishers.md`,
    /// 2026-09-14). The element carries no language attribute to read, so
    /// claiming anything else would be inventing it.
    ///
    /// Releases with no `href` are dropped rather than shown: ANN's terms
    /// require the per-entry link on the row, so a row that cannot carry one
    /// cannot go on screen. None was observed missing it.
    ///
    /// - Parameter role: what "en" is to this series — `.english` for every
    ///   series whose original is not English, which is all of them in
    ///   practice. Passed in rather than decided here because the rule that
    ///   decides it lives on the series (`VolumeEditions.role(of:in:)`), and
    ///   this function does not have one.
    nonisolated static func volumes(in entry: ANNEntry, role: EditionLanguageRole) -> [EditionVolume] {
        let edition = VolumeEdition(
            catalogue: .animeNewsNetwork, language: "en",
            languageRole: role, editionTitle: entry.name
        )
        return entry.releases.compactMap { release in
            guard let href = release.href else { return nil }
            let parts = readMarker(in: release.text)
            return EditionVolume(
                number: parts.number,
                title: release.text,
                releaseDate: PartialDate.parse(release.date),
                isbn13: release.ean.flatMap(normalisedISBN),
                format: parts.format,
                edition: edition,
                sourceLink: href
            )
        }
    }

    /// The format marker and volume number at the end of an ANN release
    /// title.
    ///
    /// A box set is recognised two ways, because ANN writes it two ways and
    /// both are in the fifteen-release Delicious in Dungeon answer and the
    /// One Piece one:
    ///
    /// - a range inside the marker — `One Piece - Wano to Egghead Box Set
    ///   (GN 91-111)`, and
    /// - the words in the title with an unnumbered marker — `Delicious in
    ///   Dungeon [Complete Box Set] (GN)`.
    ///
    /// Neither gets a number. A range is not volume 91, and numbering it 91
    /// would hide the real volume 91 behind it on the shelf.
    nonisolated static func readMarker(in title: String) -> (format: VolumeFormat, number: Int?) {
        let saysBoxSet = title.range(of: "box set", options: .caseInsensitive) != nil
        guard let inner = trailingMarker(in: title) else {
            return (saysBoxSet ? .boxSet : .other, nil)
        }
        var words = inner.split(separator: " ").map(String.init)
        // The trailing word is the number when it is one — "GN 1", "GN
        // 91-111" — and part of the marker when it is not, as in a bare
        // "(GN)".
        let tail = words.last ?? ""
        let isNumeric = !tail.isEmpty && tail.allSatisfy { $0.isNumber || $0 == "-" }
        let digits = isNumeric ? words.removeLast() : nil
        let marker = words.joined(separator: " ").lowercased()
        let collected = (digits?.contains("-") ?? false) || saysBoxSet
        let format: VolumeFormat = switch marker {
        case "gn", "manga", "novel", "sc", "hc", "omnibus": collected ? .boxSet : .print
        case "ebook", "e-book", "digital": collected ? .boxSet : .digital
        default: collected ? .boxSet : .other
        }
        return (format, collected ? nil : digits.flatMap(Int.init))
    }

    /// Digits only, and only when there are thirteen of them. ANN's `ean`
    /// arrived bare on every release observed, but a hyphenated ISBN is the
    /// same identifier and `OpenLibraryCovers` is fed straight from this.
    nonisolated static func normalisedISBN(_ raw: String) -> String? {
        let digits = raw.filter(\.isNumber)
        return digits.count == 13 ? digits : nil
    }

    /// XMLParser's delegate, kept private: nothing outside needs it, and the
    /// class is not `Sendable` — `parse(_:)` creates, uses and discards one
    /// inside a single synchronous call, which is what makes that safe.
    private final class Delegate: NSObject, XMLParserDelegate {
        var mangaID: Int?
        var mangaName: String?
        var releases: [ANNRelease] = []
        var warning: String?
        var sawRoot = false

        /// A `<release>`'s attributes, held while its text is still being
        /// read. A named type rather than a tuple: three members is one past
        /// `large_tuple`'s limit, and this one has a real name.
        private struct Pending {
            let date: String?
            let href: URL?
            let ean: String?
        }

        private var pending: Pending?
        private var text = ""

        func parser(
            _ parser: XMLParser, didStartElement element: String,
            namespaceURI: String?, qualifiedName: String?, attributes: [String: String]
        ) {
            switch element {
            case "ann":
                sawRoot = true
            case "manga":
                // The first `<manga>` only. `api.xml?title=<id>` returns one,
                // but a name lookup can return several and the extra records
                // are other series with similar names, not this one.
                if mangaID == nil {
                    mangaID = attributes["id"].flatMap(Int.init)
                    mangaName = attributes["name"]
                }
            case "release":
                pending = Pending(
                    date: attributes["date"],
                    href: attributes["href"].flatMap { URL(string: $0) },
                    ean: attributes["ean"]
                )
                text = ""
            case "warning":
                text = ""
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            text += string
        }

        func parser(
            _ parser: XMLParser, didEndElement element: String,
            namespaceURI: String?, qualifiedName: String?
        ) {
            let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch element {
            case "release":
                if let pending {
                    releases.append(
                        ANNRelease(date: pending.date, href: pending.href, ean: pending.ean, text: body)
                    )
                }
                pending = nil
            case "warning":
                warning = body
            default:
                break
            }
            text = ""
        }
    }
}
