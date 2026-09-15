import Foundation

/// The work a catalogued volume belongs to, read back out of NDL's title.
///
/// `dcterms:title` is `<work>. <dcndl:volume>` on every one of the 50 records
/// measured 2026-09-15 (`薬屋のひとりごと. 13`, `薬屋のひとりごと外伝小蘭回想録. 1`,
/// `薬屋のひとりごと : 猫猫の後宮謎解き手帳. 22`), with three variants in the same
/// page: a space instead of the dot (`薬屋のひとりごと １３`), brackets (`薬屋の
/// ひとりごと [1]`, volume `[1]`), and no suffix at all on the one 近刊 record
/// (`薬屋のひとりごと～猫猫の後宮謎解き手帳～`, volume `22`). So the rule is the
/// title *ending in* the catalogued volume string, not a regex over
/// punctuation.
///
/// **Why this exists:** the prefix admission in `titleMatches` is right and
/// stays — Solo Leveling's forthcoming row is `…外伝　01` and a phrase match
/// would lose it. But it admits the side story onto the main run's shelf as
/// a second "vol. 1", and "You own 12 of 13 · missing vol. 1" to a reader who
/// owns the whole run is a false sentence. The work title is what tells the
/// two apart; `BookEditionShelf` folds it into the edition's name.
extension NDLClient.Query {
    /// The title with its catalogued volume suffix removed, or the whole
    /// title when the volume is not a suffix of it.
    static func workTitle(title: String?, volume: String?) -> String? {
        guard let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
            return nil
        }
        guard let volume = volume?.trimmingCharacters(in: .whitespacesAndNewlines),
              !volume.isEmpty, title.hasSuffix(volume)
        else { return title }
        let stripped = title.dropLast(volume.count)
        // The separator: `. `, ` `, U+3000, or nothing. `:` is *not* trimmed
        // — `薬屋のひとりごと : 猫猫の後宮謎解き手帳` keeps its colon, which sits
        // inside the work title, not at the seam.
        let work = String(stripped).trimmingCharacters(in: Self.seam)
        return work.isEmpty ? title : work
    }

    private static let seam = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "."))

    /// What two titles must agree on to be the same work: letters and digits
    /// after `normalise`, punctuation dropped.
    ///
    /// Measured 2026-09-15: NDL writes the Shogakukan manga as
    /// `薬屋のひとりごと : 猫猫の後宮謎解き手帳` on 26 records and as
    /// `薬屋のひとりごと～猫猫の後宮謎解き手帳～` on the one 近刊 record — the same
    /// work under two punctuation habits. A key that kept the punctuation
    /// would put volume 22 on a shelf of its own.
    static func workKey(_ title: String) -> String {
        normalise(title).filter { $0.isLetter || $0.isNumber }
    }

    /// One spelling per work, across a page: the spelling most of that work's
    /// records use, so the shelf is named the way NDL usually writes it.
    ///
    /// - Returns: for each record, in order, its work title with the page's
    ///   majority spelling — or nil when the record's work *is* the queried
    ///   title, so `BookEdition.workTitle` can mean "a different work" and
    ///   nothing else. Ties break on the shorter, then the earlier, spelling.
    func workTitles(for records: [NDLRecordParser.Record]) -> [String?] {
        let raw = records.map { Self.workTitle(title: $0.title, volume: $0.volume) }
        var spellings: [String: [String: Int]] = [:]
        for case let work? in raw {
            spellings[Self.workKey(work), default: [:]][work, default: 0] += 1
        }
        let asked = Self.workKey(title)
        return raw.map { work in
            guard let work else { return nil }
            let key = Self.workKey(work)
            guard key != asked, let counts = spellings[key] else { return nil }
            return counts.max { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value < rhs.value }
                if lhs.key.count != rhs.key.count { return lhs.key.count > rhs.key.count }
                return lhs.key > rhs.key
            }?.key ?? work
        }
    }
}
