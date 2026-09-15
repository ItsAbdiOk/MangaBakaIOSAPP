import Foundation

/// Which physical volume a reader said they own, on which series.
///
/// The identity is `VolumeEditions.merge`'s, not a new one. Merge collapses
/// rows on ISBN-13 alone — two catalogues describing one printing become one
/// row, and *which* catalogue wins the collapse depends on which answered
/// better that day (`population(of:)`). So a key that carried the winning
/// catalogue's `edition.id` beside the ISBN would forget the reader's tick the
/// morning Open Library timed out and ANN won instead. The ISBN is the whole
/// identity when there is one.
///
/// A row with no ISBN is never merged with anything, and merge tells it apart
/// from its neighbours by `EditionVolume.id` — the edition plus the title. That
/// is reused as-is: a second identity built from the volume number would come
/// apart from merge's the day one of them changed and the other did not.
///
/// **One exception, NDL only** (Abdi's call, 2026-09-15): an ISBN-less NDL
/// row with a stated `dcndl:volume` is keyed on its shelf and number, not its
/// title. NDL's 近刊 record and the catalogued record that replaces it are
/// titled differently (`薬屋のひとりごと～猫猫の後宮謎解き手帳～` against
/// `薬屋のひとりごと : 猫猫の後宮謎解き手帳. 22`, measured 2026-09-15), so a
/// title key lost the tick on every volume a reader ticked before it shipped.
/// NDL rows never merge with another catalogue's without an ISBN, so the
/// merge-identity argument above does not reach them.
struct OwnedVolumeKey: Hashable, Sendable, Codable {
    let seriesID: Int
    /// `isbn:<13 digits>` for a row with an ISBN, `ndl:<VolumeEdition.id>:<n>`
    /// for an ISBN-less NDL row with a number, `row:<EditionVolume.id>`
    /// otherwise. The prefix keeps the namespaces apart in one column: an
    /// ISBN can never look like an edition id and vice versa, but the column
    /// should say which it holds rather than leave a reader of the file to
    /// guess.
    let identity: String

    init(seriesID: Int, volume: EditionVolume) {
        self.seriesID = seriesID
        if let isbn = volume.isbn13 {
            // The same fold `datedISBNs(in:)` applies before comparing ISBNs
            // from two sources — hyphens out — so a tick taken on ANN's
            // `9780316471855` still matches the same printing arriving from
            // MangaBaka's works as `978-0-316-47185-5`.
            identity = "isbn:\(OpenLibraryEditions.normalise(isbn))"
        } else if let number = Self.ndlNumber(of: volume) {
            identity = "ndl:\(volume.edition.id):\(number)"
        } else {
            identity = "row:\(volume.id)"
        }
    }

    /// The number an ISBN-less NDL row is keyed on, or nil for any other row.
    static func ndlNumber(of volume: EditionVolume) -> Int? {
        guard volume.edition.catalogue == .nationalDietLibrary, volume.isbn13 == nil else { return nil }
        return volume.number
    }

    /// For reading a row back off disk. Not for building a key from a volume
    /// — that goes through `init(seriesID:volume:)` so the two namespaces are
    /// written in exactly one place.
    init(seriesID: Int, identity: String) {
        self.seriesID = seriesID
        self.identity = identity
    }
}
