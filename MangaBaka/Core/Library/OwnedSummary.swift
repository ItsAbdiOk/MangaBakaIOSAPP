import Foundation

/// "You own 3 of 12 · missing vol. 4, 7" — one edition's tally against the
/// reader's ticks.
///
/// Pure and `nonisolated static`, like `EditionShelvesSection`'s other copy
/// helpers, so the arithmetic is tested without a view.
enum OwnedSummary {
    /// The line under one edition's heading, or nil when nothing on it is
    /// ticked. Nil rather than "You own 0 of 12": the unticked circles beside
    /// every row already say that, and a sentence repeating it on every
    /// edition of every series is noise the section's own "no date" rule
    /// (`dateLine(for:)`) already declines to add.
    nonisolated static func line(
        for shelf: EditionShelf, owned: Set<OwnedVolumeKey>, seriesID: Int
    ) -> String? {
        let ticked = shelf.volumes.filter {
            owned.contains(OwnedVolumeKey(seriesID: seriesID, volume: $0))
        }
        guard !ticked.isEmpty else { return nil }

        // A shelf built from part of a catalogue's answer cannot say "of M"
        // or "missing": NDL's page 1 for 薬屋のひとりごと holds Square Enix
        // volumes 1 and 10–14 of the 14 it lists (measured 2026-09-15), and
        // "missing vol. 2–9" to a reader holding them is a false sentence.
        // The count is the one thing still true.
        guard !shelf.isPartial else {
            // A total the catalogue actually stated reads as "still more to
            // come", which is the honest version of this sentence — see
            // `EditionShelf.totalRecords`. Falls back to the vaguer note
            // when the catalogue that answered (Open Library, today) does
            // not carry a total this far.
            guard let total = shelf.totalRecords else {
                return "\(ticked.count) owned · \(partialNote)"
            }
            return "\(ticked.count) owned · first \(shelf.volumes.count) of \(total) on record"
        }

        // An owned volume with no number cannot be placed in the sequence,
        // so "missing" would be a guess about where it sits. Say the count
        // and nothing else — the brief's rule, and the same refusal to print
        // what a catalogue never stated that `PartialDate` makes about dates.
        guard ticked.allSatisfy({ $0.number != nil }) else {
            return "\(ticked.count) owned"
        }

        var line = "You own \(ticked.count) of \(shelf.volumes.count)"
        let missing = missingNumbers(in: shelf, ticked: ticked)
        if !missing.isEmpty {
            line += " · missing vol. \(runs(missing))"
        }
        return line
    }

    /// What a partial shelf says instead of "of M". Public so the section's
    /// tests can assert the wording without restating it.
    static let partialNote = "more volumes on record than shown"

    /// Every number from 1 to the highest the edition lists that no ticked
    /// row carries.
    ///
    /// The ceiling is the highest number *this edition* records, not the
    /// series' final volume: the shelf is about printings the catalogues
    /// know, and a volume no catalogue has listed yet is `ForthcomingVolume`'s
    /// problem, not a gap on the reader's shelf. Numbers below 1 are
    /// ignored — a "volume 0" prologue is not a gap either.
    nonisolated static func missingNumbers(in shelf: EditionShelf, ticked: [EditionVolume]) -> [Int] {
        let highest = shelf.volumes.compactMap(\.number).max() ?? 0
        guard highest >= 1 else { return [] }
        let have = Set(ticked.compactMap(\.number))
        return (1...highest).filter { !have.contains($0) }
    }

    /// "4, 7–9, 12": consecutive numbers folded into a range, so owning one
    /// volume of a hundred reads as "missing vol. 2–100" rather than
    /// ninety-nine numbers.
    nonisolated static func runs(_ numbers: [Int]) -> String {
        var pieces: [String] = []
        var start: Int?
        var previous: Int?
        for number in numbers.sorted() {
            if let last = previous, number == last + 1 {
                previous = number
                continue
            }
            if let start, let previous { pieces.append(piece(start, previous)) }
            start = number
            previous = number
        }
        if let start, let previous { pieces.append(piece(start, previous)) }
        return pieces.joined(separator: ", ")
    }

    /// An en dash, not a hyphen: "7–9" is a range and "7-9" reads as a
    /// hyphenated number, the same distinction the date wording keeps.
    nonisolated private static func piece(_ start: Int, _ end: Int) -> String {
        start == end ? "\(start)" : "\(start)–\(end)"
    }
}
