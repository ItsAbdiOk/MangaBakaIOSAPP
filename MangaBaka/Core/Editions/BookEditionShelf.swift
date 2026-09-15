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
        withInheritedPublishers(rows).compactMap { row in editionVolume(from: row, in: series) }
    }

    /// A row that states no publisher takes the one every other row of the
    /// same work on the same page states — when they all agree.
    ///
    /// NDL's 近刊 (forthcoming) record carries no `dc:publisher` yet, so it
    /// sat on a shelf of its own beside Shogakukan's 1–17 (`docs/reviews/
    /// night/shelf.md`, "Needs Abdi"): the shelf's name is its group key and
    /// the missing word split the run. Abdi's call, 2026-09-15: inherit it.
    /// Only when the page's other rows for that work name exactly one
    /// publisher — a work printed by two houses leaves the row alone rather
    /// than guess between them. Not labelled as inferred on the shelf: the
    /// label would go into the shelf's name, which is the group key, and
    /// split the run again; this comment and `BookEditionShelfTests` are the
    /// record instead.
    static func withInheritedPublishers(_ rows: [BookEdition]) -> [BookEdition] {
        var publishers: [String?: Set<String>] = [:]
        for row in rows {
            if let publisher = row.publisher { publishers[row.workTitle, default: []].insert(publisher) }
        }
        return rows.map { row in
            guard row.publisher == nil, let stated = publishers[row.workTitle], stated.count == 1,
                  let publisher = stated.first
            else { return row }
            return BookEdition(
                id: row.id, title: row.title, isbn13: row.isbn13, publisher: publisher,
                language: row.language, published: row.published, coverID: row.coverID,
                volume: row.volume, source: row.source, format: row.format,
                formatEvidence: row.formatEvidence, edition: row.edition, workTitle: row.workTitle
            )
        }
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
                editionTitle: editionTitle(for: row)
            ),
            sourceLink: sourceLink(for: row)
        )
    }

    /// The shelf's name, and therefore its group key (`VolumeEdition.id`):
    /// `"<publisher> · <work> · <edition>"`, each part only when the record
    /// stated one.
    ///
    /// The publisher first, not a made-up name: it is the only thing either
    /// catalogue states that tells one printing's run from another's, and it
    /// is what the heading of a group of spines wants to say. Nil where the
    /// record did not state one — Open Library writes the literal string
    /// "unknown" for that and `EditionDocument.row` has already turned it
    /// into nil.
    ///
    /// The work, only when it is not the one asked for (`BookEdition.
    /// workTitle`), so a side story admitted by the prefix match gets its own
    /// shelf instead of a second "vol. 1" on the main run's.
    ///
    /// The edition note last, so the special printing of vol. 13 is a row of
    /// its own — one the reader who owns it can still tick, with the right
    /// ISBN — and the plain shelf counts one row per volume. Measured
    /// 2026-09-15: all nine `dcndl:edition` notes on the 薬屋のひとりごと page
    /// contain `特装版` and differ only in what is bundled (a booklet, a fan, a
    /// deck of cards), so they are folded to that one word rather than left
    /// as five one-volume shelves; a note without it is kept verbatim.
    static func editionTitle(for row: BookEdition) -> String? {
        let parts = [row.publisher, row.workTitle, row.edition.map(editionLabel)].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// `[マスキングテープ付特装版]` → `特装版`; `ドラマCD付き限定特装版` → `特装版`;
    /// anything without the word, bracket-stripped and verbatim.
    static func editionLabel(_ note: String) -> String {
        let trimmed = note.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
        return trimmed.contains(specialEdition) ? specialEdition : trimmed
    }

    /// "Special edition", NDL's own word for it on every note measured.
    static let specialEdition = "特装版"

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
        // Full-width first: NDL writes `１３` on some records (measured
        // 2026-09-15, `薬屋のひとりごと １３`), and `Int("１３")` is nil.
        let folded = raw.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? raw
        let digits = folded.trimmingCharacters(in: CharacterSet(charactersIn: "[ ")).prefix { $0.isNumber }
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
