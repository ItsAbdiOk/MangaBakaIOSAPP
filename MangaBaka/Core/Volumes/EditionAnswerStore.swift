import Foundation
import GRDB

/// The merged volumes answer a series page drew, kept on disk keyed by series
/// id, so the Next-volume widget can read it without a request.
///
/// **Why this exists.** `WidgetSnapshot+NextVolume.swift` recorded on
/// 2026-09-14 that the widget could see a forthcoming volume only from
/// MangaBaka's own `works`, and only for a series whose page was opened in the
/// last six hours — the ANN / Open Library / NDL answer a page merges
/// (`VolumeEditions.merge`) lived in that view's `@State` and nowhere else. A
/// reader who opened Solo Leveling last week got no "Vol. 12 · 3 Oct" tile
/// even though ANN had said so. The fix is to persist the *merged* answer, not
/// the three raw ones: re-running the dedupe and credit rules here would be
/// the second, drifting copy of `VolumeEditionMerge.swift` that file warns
/// against.
///
/// Writes to `cacheWriter`'s file: every row is re-fetchable from the three
/// catalogues the next time the page opens, so it does not belong in the
/// backup (the same rule `cadenceEntry` and `seriesDetail` follow).
actor EditionAnswerStore {
    private let database: AppDatabase
    private let clock: any Clock

    init(database: AppDatabase, clock: any Clock = SystemClock()) {
        self.database = database
        self.clock = clock
    }

    /// How long a stored answer is trusted for.
    ///
    /// **A guess.** Longer than `seriesDetail`'s six hours because a volume's
    /// date moves rarely: ANN's forthcoming rows in the 2026-09-14 survey sat
    /// about two months out (`docs/sources/publishers.md`), and a date that
    /// slips does so by weeks, not hours. Shorter than the 60-day widget
    /// window so an answer cannot outlive the whole period it was asked
    /// about. Not checked against how often a real date moved within 30 days.
    static let freshness: TimeInterval = 30 * 86_400

    /// How many answers are kept, newest first.
    ///
    /// **A guess.** Above `SeriesRepository+Cache.detailRowLimit` (200)
    /// because a merged answer is a few KB against a 204 KB median series
    /// page, so the same disk buys more rows; and a reader's reading-state
    /// library (the only entries `wantsNextVolume` admits) was a few hundred
    /// on the 945-row reference account. 300 covers that without holding a
    /// year of drive-by page opens forever.
    static let rowLimit = 300

    // MARK: - Write

    /// Stores `answer` for `seriesId`, replacing whatever was there.
    ///
    /// An empty answer is not written: it would overwrite a good one with
    /// "nothing", and — per `ForthcomingVolume` — no source can say nothing
    /// is coming, so there is no fact in an empty shelf worth persisting.
    func write(_ answer: VolumeEditionAnswer, for seriesId: Int) {
        guard !answer.isEmpty else { return }
        guard let payload = try? JSONEncoder().encode(StoredEditionAnswer(answer)) else { return }
        try? database.cacheWriter.write { db in
            try db.execute(
                sql: """
                INSERT INTO editionAnswer (seriesId, payload, fetchedAt) VALUES (?, ?, ?)
                ON CONFLICT(seriesId) DO UPDATE SET
                    payload = excluded.payload, fetchedAt = excluded.fetchedAt
                """,
                arguments: [seriesId, payload, clock.now]
            )
            try Self.trim(db)
        }
    }

    /// Newest-first by write time, the same shape as `trimDetail`.
    nonisolated static func trim(_ db: Database) throws {
        try db.execute(sql: """
            DELETE FROM editionAnswer WHERE seriesId NOT IN (
                SELECT seriesId FROM editionAnswer
                ORDER BY fetchedAt DESC, seriesId DESC LIMIT \(rowLimit)
            )
            """)
    }

    // MARK: - Read

    /// One forthcoming volume as the widget needs it, and nothing the widget
    /// does not.
    struct Forthcoming: Sendable, Equatable {
        /// "Vol. 12", or the source's own title when it has no number —
        /// the same rule as `SeriesWork.Volume.label`.
        let volumeLabel: String
        /// UTC start of the stated period (`PartialDate.date`).
        let date: Date
        /// `VolumeCatalogue.displayName` of the catalogue that owns the row.
        let sourceName: String
        /// The row's own entry on its catalogue. Never nil for an ANN row —
        /// `VolumeCatalogue.requiresPerEntryLink` is their terms, and a row
        /// without one is dropped here rather than shown uncredited.
        let sourceURL: URL?
    }

    /// The soonest forthcoming volume in each stored answer among `ids`, in
    /// one read. A series with no row, a row past `freshness`, or an answer
    /// with nothing dated ahead of the clock's now is absent from the result.
    ///
    /// Decodes only the keys the widget needs (`ForthcomingRows`), the same
    /// partial-decode trick `SeriesRepository+Cache.cachedExtrasField` uses so
    /// a whole library's worth of shelves is not rebuilt at launch.
    func forthcoming(for ids: [Int]) async -> [Int: Forthcoming] {
        guard !ids.isEmpty else { return [:] }
        // A typed record, not `Row`: GRDB's `Row` is not `Sendable`, and the
        // async `read` hands its result across the actor boundary.
        let rows = (try? await database.cacheWriter.read { db in
            try StoredRow.fetchAll(
                db,
                sql: "SELECT seriesId, payload, fetchedAt FROM editionAnswer WHERE seriesId IN "
                    + "(\(Array(repeating: "?", count: ids.count).joined(separator: ",")))",
                arguments: StatementArguments(ids)
            )
        }) ?? []
        let asOf = clock.now
        var out: [Int: Forthcoming] = [:]
        for row in rows {
            // Backwards-clock case treated as stale, as `readDetailCache` does.
            let age = asOf.timeIntervalSince(row.fetchedAt)
            guard age >= 0, age < Self.freshness else { continue }
            guard let decoded = try? JSONDecoder().decode(ForthcomingRows.self, from: row.payload),
                  let soonest = decoded.soonest(asOf: asOf)
            else { continue }
            out[row.seriesId] = soonest
        }
        return out
    }

    private struct StoredRow: FetchableRecord, Decodable, Sendable {
        let seriesId: Int
        let payload: Data
        let fetchedAt: Date
    }

    /// Just the fields `forthcoming(for:)` reads, named exactly as
    /// `StoredEditionAnswer` encodes them. Every other key is ignored by
    /// Foundation's decoder, which is the whole point.
    struct ForthcomingRows: Decodable {
        struct Shelf: Decodable {
            let edition: Edition
            let volumes: [Volume]
        }

        struct Edition: Decodable {
            let catalogue: VolumeCatalogue
        }

        struct Volume: Decodable {
            let number: Int?
            let title: String
            let releaseDate: PartialDate?
            let sourceLink: URL?
        }

        let shelves: [Shelf]

        /// Mirrors `VolumeEditionAnswer.forthcoming(asOf:)` — soonest
        /// `PartialDate` still forthcoming across every shelf — on the partial
        /// shape, and drops an ANN row with no link (see `Forthcoming.sourceURL`).
        func soonest(asOf now: Date) -> Forthcoming? {
            var best: (Forthcoming, PartialDate)?
            for shelf in shelves {
                let catalogue = shelf.edition.catalogue
                for volume in shelf.volumes {
                    guard let date = volume.releaseDate, date.isForthcoming(now: now) else { continue }
                    if catalogue.requiresPerEntryLink, volume.sourceLink == nil { continue }
                    if let current = best, current.1 <= date { continue }
                    best = (Forthcoming(
                        volumeLabel: volume.number.map { "Vol. \($0)" } ?? volume.title,
                        date: date.date, sourceName: catalogue.displayName, sourceURL: volume.sourceLink
                    ), date)
                }
            }
            return best?.0
        }
    }
}

/// The on-disk shape of a `VolumeEditionAnswer`.
///
/// Its own type rather than `Codable` on the answer, because the answer
/// carries `failures: [VolumeCatalogue: APIError]` — a transient "this leg
/// did not answer this time" that has no business outliving the page — and
/// `unaskedReason`, which is nil for anything worth writing (`write` skips
/// empty answers). What is kept is exactly what the shelf drew: the shelves
/// and the credits owed for them. `EditionShelf` is not itself `Codable`
/// (`EditionShelf.swift` is another lane's file), so its four fields are
/// spelled out here; `VolumeEdition`, `VolumeFormat` and `EditionVolume`
/// already are.
struct StoredEditionAnswer: Codable, Sendable, Equatable {
    struct Shelf: Codable, Sendable, Equatable {
        let edition: VolumeEdition
        let format: VolumeFormat
        let volumes: [EditionVolume]
        let isPartial: Bool
    }

    let shelves: [Shelf]
    let credits: [VolumeCatalogue]

    init(_ answer: VolumeEditionAnswer) {
        shelves = answer.shelves.map {
            Shelf(edition: $0.edition, format: $0.format, volumes: $0.volumes, isPartial: $0.isPartial)
        }
        credits = answer.credits
    }

    /// Back to the type the shelf view reads. `failures` is empty by
    /// construction; `unaskedReason` is nil when there is a shelf and
    /// `.noneListed` when there is not, which is the only honest reading of a
    /// stored answer with no rows.
    var answer: VolumeEditionAnswer {
        VolumeEditionAnswer(
            shelves: shelves.map {
                EditionShelf(
                    edition: $0.edition, format: $0.format, volumes: $0.volumes, isPartial: $0.isPartial
                )
            },
            credits: credits,
            failures: [:],
            unaskedReason: shelves.isEmpty ? .noneListed : nil
        )
    }
}
