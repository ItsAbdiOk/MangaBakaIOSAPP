import Foundation

/// The boundary where a library catalogue's record becomes a shelf row.
///
/// `BookEdition` stays what `OpenLibraryEditions` and `NDLClient` return — it
/// is a bibliographic record, with a cataloguer's genre field and the evidence
/// behind it, and neither client is rewritten to speak the shelf's vocabulary.
/// `VolumeEdition`/`EditionVolume`/`EditionShelf` is what the app draws,
/// because it already models the grouping the shelf needs. This one function is
/// the whole seam between them (decision taken 2026-09-14, not re-litigated
/// here).
///
/// **What is lost crossing it, stated rather than hidden:** the publisher (kept
/// as the edition's name, so a shelf can say "Yen Press" rather than "English
/// edition"), the cover id, and `formatEvidence`. The evidence is read *here*,
/// to decide `VolumeFormat`, and then dropped — a shelf row has no slot for
/// "why we think this is a comic", and `VolumeEditions.merge` is the caller
/// that acts on the answer.
enum BookEditionShelf {
    /// Library rows as shelf rows, in the order the catalogue gave them.
    ///
    /// - Parameter series: read for the language roles only. The language
    ///   *filter* is not applied here — `VolumeEditions.merge` applies
    ///   `Series.coverLanguages` to every source at once, so there is one place
    ///   that decides what "English plus the original" means and no source can
    ///   quietly disagree with it.
    static func editionVolumes(from rows: [BookEdition], in series: Series) -> [EditionVolume] {
        rows.compactMap { row in editionVolume(from: row, in: series) }
    }

    /// - Returns: nil for a row with no title at all. Open Library's `title` is
    ///   optional on the wire and `EditionDocument.row` defaults it to `""`; a
    ///   spine with no name is not a row a reader can do anything with, and
    ///   `EditionVolume.title` is documented as shown as-is or not at all.
    static func editionVolume(from row: BookEdition, in series: Series) -> EditionVolume? {
        guard !row.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let language = twoLetter(row.language)
        return EditionVolume(
            number: row.volume.flatMap(number(from:)),
            title: row.title,
            releaseDate: row.published,
            isbn13: row.isbn13.map(OpenLibraryEditions.normalise),
            format: format(of: row),
            edition: VolumeEdition(
                catalogue: catalogue(of: row.source),
                language: language,
                languageRole: VolumeEditions.role(of: language, in: series),
                // The publisher, not a made-up name: it is the only thing
                // either catalogue states that tells one printing's run from
                // another's, and it is what the heading of a group of spines
                // wants to say. Nil where the record did not state one — Open
                // Library writes the literal string "unknown" for that and
                // `EditionDocument.row` has already turned it into nil.
                editionTitle: row.publisher
            ),
            sourceLink: sourceLink(for: row)
        )
    }

    private static func catalogue(of source: BookEdition.Source) -> VolumeCatalogue {
        switch source {
        case .openLibrary: .openLibrary
        case .nationalDietLibrary: .nationalDietLibrary
        }
    }

    /// A library record is a printing of a physical book, so `.print` — with
    /// one exception that carries the whole reason the Wikidata table exists.
    ///
    /// A `.prose` row becomes `.other`, whose own doc comment reads "a light
    /// novel beside the comic — carried rather than dropped so a caller can
    /// choose, but never a volume of the series itself". `VolumeEditions.merge`
    /// is that caller. `.unknown` becomes `.print`: no field said, and "did not
    /// say" is not "is a novel" — treating it as one would hide real volumes,
    /// which is the mirror image of the bug and just as wrong.
    private static func format(of row: BookEdition) -> VolumeFormat {
        row.format == .prose ? .other : .print
    }

    /// `dcndl:volume` is `"1"`, `"01"`, `"12"` and occasionally `"1, 2"` for a
    /// bound pair (measured 2026-09-14). The leading integer is taken and
    /// anything else is nil — a number this cannot read leaves the row
    /// unnumbered, which sorts it after the numbered ones rather than
    /// inventing a place for it.
    ///
    /// Open Library states no volume field at all (`EditionDocument.row` keeps
    /// it nil deliberately: the number lives inside the title string and
    /// parsing it out of two languages' punctuation is a guess), so in practice
    /// every row this numbers is an NDL one.
    static func number(from raw: String) -> Int? {
        let digits = raw.prefix { $0.isNumber }
        guard !digits.isEmpty else { return nil }
        return Int(digits)
    }

    /// The catalogue's own page for this record.
    ///
    /// Neither source's terms require this per row — only ANN's do, and ANN
    /// does not come through here. It is carried because a reader who wants to
    /// check a date has somewhere to go, and because a credit that can be
    /// followed is a better credit than one that cannot.
    ///
    /// Open Library's `id` is an edition key (`/books/OL32184952M`) and
    /// resolves under openlibrary.org. NDL's is already an absolute record URI,
    /// so it is parsed rather than composed — and through `SafeLink.web`, which
    /// is the app's one rule about what a URL out of a third party's payload is
    /// allowed to be.
    private static func sourceLink(for row: BookEdition) -> URL? {
        switch row.source {
        case .openLibrary:
            let path = row.id.hasPrefix("/") ? String(row.id.dropFirst()) : row.id
            guard path.hasPrefix("books/") else { return nil }
            return SafeLink.web(URL(string: "https://openlibrary.org/\(path)"))
        case .nationalDietLibrary:
            return SafeLink.web(URL(string: row.id))
        }
    }

    /// ISO 639-2/B, which is what both catalogues speak, to the two-letter form
    /// `Series.coverLanguages` is written in.
    ///
    /// Only the codes these two sources were actually measured to return are
    /// here. **An unmapped code is passed through unchanged**, which means it
    /// fails the language filter and the row is dropped — the right failure,
    /// because the alternative is placing a book on an "English" or a
    /// "Japanese" shelf on the strength of a code nobody checked. A nil
    /// language is `"und"` for the same reason: measured 2026-09-14, the rows
    /// with no stated language were the French, Spanish and second French
    /// printings, so "did not say" correlates with "not one of the two".
    static func twoLetter(_ code: String?) -> String {
        guard let code = code?.lowercased() else { return "und" }
        // Measured on the five test series, 2026-09-14: `eng`, `jpn`, `fre`,
        // `spa`. `kor` and `chi`/`zho` are here because the app's library is
        // majority manhwa and they are the original languages it will ask
        // about, not because either was seen in that sample.
        let table = [
            "eng": "en", "jpn": "ja", "kor": "ko", "chi": "zh", "zho": "zh",
            "fre": "fr", "fra": "fr", "spa": "es", "ger": "de", "deu": "de",
            "por": "pt", "ita": "it"
        ]
        return table[code] ?? code
    }
}
