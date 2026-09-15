import Foundation
import GRDB

extension OwnedVolumes {
    /// Moves a tick taken on an ISBN-less row to the ISBN the same row now
    /// carries.
    ///
    /// `OwnedVolumeKey` is `isbn:` when the row has one and `row:<edition>-
    /// <title>` when it does not — and a row can gain an ISBN later: NDL's
    /// 近刊 record replaced by the catalogued one, Open Library filling in
    /// `isbn_13`, a different catalogue winning the merge. The key changes,
    /// the tick vanishes, and the orphan stays in the reader's file and in
    /// Settings' "erase N" count. The key itself is right (`OwnedVolumeKey`'s
    /// doc comment says why); this is the repair.
    ///
    /// For every current row *with* an ISBN, the key it would have had
    /// without one is computed; if that identity is ticked, the row is
    /// rewritten to the `isbn:` identity with its original `ownedAt` and the
    /// orphan is dropped. **A row whose title also changed stays an orphan**:
    /// it is genuinely a different string, and matching on anything looser
    /// is the title-matching this family of sources was built to avoid.
    /// Measured 2026-09-15, the NDL 近刊 record is titled
    /// `薬屋のひとりごと～猫猫の後宮謎解き手帳～` and its catalogued successor
    /// `薬屋のひとりごと : 猫猫の後宮謎解き手帳. 22` — which is why an NDL row
    /// with a number is keyed `ndl:<shelf>:<n>` instead (`OwnedVolumeKey`,
    /// Abdi's call the same day), and this repair checks that identity too.
    ///
    /// - Returns: how many ticks moved, so the caller re-reads only when one
    ///   did.
    func reconcile(shelves: [EditionShelf], for seriesID: Int) throws -> Int {
        let owned = try owned(for: seriesID)
        guard !owned.isEmpty else { return 0 }
        let moves = shelves.flatMap(\.volumes).compactMap { volume -> Move? in
            guard volume.isbn13 != nil else { return nil }
            let orphan = Self.orphanIdentities(of: volume)
                .map { OwnedVolumeKey(seriesID: seriesID, identity: $0) }
                .first { owned.contains($0) }
            guard let orphan else { return nil }
            return (orphan, OwnedVolumeKey(seriesID: seriesID, volume: volume))
        }
        guard !moves.isEmpty else { return 0 }
        try write(moves)
        return moves.count
    }

    /// The `row:` identity `OwnedVolumeKey.init(seriesID:volume:)` writes for
    /// a volume with no ISBN — computed here for a volume that *has* one, by
    /// building the same key off a copy with the ISBN removed, so the
    /// namespace prefix is still written in exactly one place.
    static func rowIdentity(of volume: EditionVolume) -> String {
        OwnedVolumeKey(seriesID: 0, volume: Self.bare(volume)).identity
    }

    /// Every identity a tick on this row could have been written under
    /// before the row had an ISBN: the ISBN-less key (`ndl:` for a numbered
    /// NDL row, `row:` otherwise) and, for the NDL row, the `row:` form too —
    /// a tick taken before 2026-09-15 was written that way.
    static func orphanIdentities(of volume: EditionVolume) -> [String] {
        let bare = Self.bare(volume)
        var identities = [OwnedVolumeKey(seriesID: 0, volume: bare).identity]
        if OwnedVolumeKey.ndlNumber(of: bare) != nil { identities.append("row:\(bare.id)") }
        return identities
    }

    private static func bare(_ volume: EditionVolume) -> EditionVolume {
        EditionVolume(
            number: volume.number, title: volume.title, releaseDate: volume.releaseDate,
            isbn13: nil, format: volume.format, edition: volume.edition,
            sourceLink: volume.sourceLink, alsoFrom: volume.alsoFrom, dateFrom: volume.dateFrom
        )
    }

    private typealias Move = (from: OwnedVolumeKey, to: OwnedVolumeKey)

    private func write(_ moves: [Move]) throws {
        try database.libraryWriter.write { db in
            for move in moves {
                guard let orphan = try Self.row(move.from).fetchOne(db) else { continue }
                // `.ignore`: the reader may have ticked the ISBN row too, in
                // which case the earlier tick is the one that stands.
                try OwnedVolumeRow(
                    seriesId: move.to.seriesID, identity: move.to.identity, ownedAt: orphan.ownedAt
                ).insert(db, onConflict: .ignore)
                _ = try Self.row(move.from).deleteAll(db)
            }
        }
    }

    private static func row(_ key: OwnedVolumeKey) -> QueryInterfaceRequest<OwnedVolumeRow> {
        OwnedVolumeRow.filter(Column("seriesId") == key.seriesID && Column("identity") == key.identity)
    }
}
