import Foundation

/// One catalogued printing of one volume, from a library rather than a shop.
///
/// This is the row both clients in this folder produce, so a view can draw an
/// Open Library row and an NDL row in one list without knowing which is which
/// — except where it must, which is why `source` is on the row and not on the
/// call. Every row carries who said it and what language it is in, because
/// those are the two questions an edition list exists to answer.
///
/// Not `SeriesEdition`: that decodes MangaBaka's own `/v1/series/{id}/
/// collections`, which is a *publisher's run* ("English · Ize Press, 12
/// volumes"). This is a single physical printing with its own ISBN. They sit
/// at different levels and merging them would lose the ISBN.
struct BookEdition: Codable, Sendable, Equatable, Identifiable {
    /// Who catalogued this row. Never inferred from the data — set by the
    /// client that made the request.
    enum Source: String, Codable, Sendable {
        case openLibrary
        case nationalDietLibrary

        /// The credit a view must show next to this row.
        ///
        /// Both are obligations, not courtesies. Open Library names no licence
        /// at all for its database (their own licensing page concedes "the
        /// legal issues are, frankly, very confusing"), so attribution is what
        /// removes the argument; NDL's API terms make credit mandatory
        /// outright. See `docs/licences.md`.
        var credit: String {
            switch self {
            case .openLibrary: "Edition data from Open Library"
            case .nationalDietLibrary: "国立国会図書館サーチ"
            }
        }
    }

    /// What kind of book this row is — the manga-versus-light-novel question
    /// that decides whether a row belongs on a comic shelf at all.
    ///
    /// Three cases, and the third is load-bearing: `.unknown` means no field
    /// said, which is not the same as "not a comic". Apple Books filled the
    /// comic shelf with novels by treating an absent signal as a pass; a
    /// caller that wants only comics must filter to `.comic` explicitly and
    /// see what it is discarding.
    enum Format: String, Codable, Sendable {
        case comic
        case prose
        case unknown
    }

    /// Why `format` says what it says. Checked in tests, and available to a
    /// view that wants to explain itself.
    ///
    /// **The one thing that is never in here is Open Library's `form:` subject
    /// tag.** Measured 2026-09-14 (`docs/sources/bibliographic.md`): Solo
    /// Leveling is 0 of 100 documents tagged, and a title search for The
    /// Apothecary Diaries returns 16 `form:light novel` documents alongside 21
    /// untagged ones that mix the manga and the novels together. It is
    /// fan-curated, absent on whole series, and filtering on it reproduces the
    /// Apple Books failure in a new coat. It is a hint and this type has no
    /// case for hints.
    enum FormatEvidence: Codable, Sendable, Equatable {
        /// The lookup started from an ISBN whose format was already known —
        /// a volume out of MangaBaka's own `/v1/series/{id}/works`, on a
        /// series MangaBaka has already typed. The edition inherits it,
        /// because an ISBN identifies one printing and cannot be two formats.
        case anchorISBN(String)
        /// A cataloguer's own format field, quoted verbatim: NDL's
        /// `dcndl:genre`, e.g. `漫画`. A real field filled in by a national
        /// library, not a crowd.
        case catalogueGenre(String)
        /// The record states no genre, but its imprint is one that other
        /// records in the same answer carry alongside an explicit genre. The
        /// weakest of the three, and the only one that admits a forthcoming
        /// volume — a 近刊 record is catalogued before its genre is assigned.
        /// See `NDLClient.Query` for the measurement and for the failure mode
        /// (an imprint that publishes both manga and prose).
        case imprintCorroborated(imprint: String)
        /// Nothing in the record said, and nothing upstream did either.
        /// Always paired with `.unknown`.
        case unstated
    }

    /// The catalogue's own identifier — an Open Library edition key
    /// (`/books/OL32184952M`) or an NDL record URI. Stable, and unique per
    /// printing, which the ISBN is not: three rows in the measured Solo
    /// Leveling response had no ISBN at all.
    let id: String
    let title: String
    let isbn13: String?
    let publisher: String?
    /// ISO 639-2/B, three letters (`eng`, `jpn`, `fre`) — the form both
    /// catalogues speak. **Nil means the record did not say**, which is
    /// common and must never be shown as English: measured 2026-09-14, the
    /// French Solo Leveling edition (KBOOKS, 9782382880296) carries an empty
    /// `languages` array, so a default would have labelled it English.
    let language: String?
    let published: PartialDate?
    /// Open Library's numeric cover id, for `covers.openlibrary.org/b/id/…`.
    /// Nil on every NDL row — NDL publishes no cover images.
    let coverID: Int?
    /// The volume number as printed, where the catalogue broke it out as its
    /// own field. NDL does (`dcndl:volume`); Open Library leaves it inside
    /// the title string, so it is nil on those rows rather than parsed out of
    /// prose.
    let volume: String?
    let source: Source
    let format: Format
    let formatEvidence: FormatEvidence

    /// True when the catalogue holds the record and the book is not published
    /// yet. Only NDL has ever answered true here.
    func isForthcoming(now: Date) -> Bool {
        published?.isForthcoming(now: now) ?? false
    }
}

/// What a catalogue said when asked about a series.
///
/// The point of the type: `.notCatalogued` and `.editions([])` are different
/// answers and the app's standing rule is that an absent answer is "unknown",
/// never "none". A library that has never heard of a book is not evidence
/// that the book has no editions.
enum EditionAnswer: Sendable, Equatable {
    /// The catalogue has this work, and these are the printings under it.
    /// May legitimately be empty for a work with one printing already known.
    case editions([BookEdition])
    /// Asked, answered, and the catalogue holds no matching record. Distinct
    /// from a failure (which throws) and from an empty list.
    case notCatalogued

    /// The rows, or `[]` for `.notCatalogued`. Only for a caller that has
    /// already decided the distinction does not matter to it — a view that
    /// draws an empty state must switch on the case instead.
    var rows: [BookEdition] {
        if case let .editions(rows) = self { return rows }
        return []
    }
}
