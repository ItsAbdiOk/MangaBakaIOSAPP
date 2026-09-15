import Foundation

// Split out of `VolumeEdition.swift` on 2026-09-15 when `EditionShelf` gained
// `format` and `isPartial` and the file crossed the 400-line ceiling. The
// vocabulary stays there; these two are the shapes the shelf view consumes.

/// One edition's spines of one format, ready for the shelf.
///
/// One format per shelf, not one shelf per edition: `VolumeFormat`'s own doc
/// comment says why — One Piece via ANN is `(GN n)` and `(eBook n)` for every
/// n, and one shelf holding both "reads as thirty volumes where there are
/// fifteen" (`docs/sources/publishers.md:157`). Delicious in Dungeon read
/// "You own 14 of 15" with the fifteenth being the box set. `VolumeEditions.
/// merge` groups on `(edition, format)`, so `volumes` all share `format`.
struct EditionShelf: Sendable, Equatable, Identifiable {
    let edition: VolumeEdition
    /// What every row on this shelf is. Print and digital are different books
    /// with different ISBNs; a box set is not a volume at all.
    let format: VolumeFormat
    /// Sorted by volume number, unnumbered releases last.
    let volumes: [EditionVolume]
    /// True when the catalogue holds more of this edition than the page it
    /// answered with — NDL's page is 50 of 84 for 薬屋のひとりごと (measured
    /// 2026-09-15) and volumes 2–9 are on the page nobody asked for. A view
    /// must not call a partial shelf complete: `OwnedSummary.line` drops
    /// "of M" and "missing" on one.
    let isPartial: Bool

    var id: String { "\(edition.id)-\(format.rawValue)" }

    /// `format` and `isPartial` default to the common case — a print shelf
    /// from a complete page — written out because a `let` with a default is
    /// left out of the synthesised memberwise init.
    init(
        edition: VolumeEdition, format: VolumeFormat = .print, volumes: [EditionVolume],
        isPartial: Bool = false
    ) {
        self.edition = edition
        self.format = format
        self.volumes = volumes
        self.isPartial = isPartial
    }

    /// The earliest volume in this edition dated after `now`, or why there
    /// isn't one. Never "nothing is coming" — see `ForthcomingVolume`.
    func forthcoming(asOf now: Date) -> ForthcomingVolume {
        let ahead = volumes
            .filter { $0.releaseDate?.isForthcoming(now: now) ?? false }
            .min { lhs, rhs in
                (lhs.releaseDate?.date ?? .distantFuture) < (rhs.releaseDate?.date ?? .distantFuture)
            }
        guard let ahead else { return .unknown(.noneListed) }
        return .announced(ahead)
    }
}

/// The whole answer the volumes shelf consumes.
///
/// **This is the API the detail lane wires to.** It is built by
/// `VolumeEditions.merge(ann:for:)` and nothing else; the client is never
/// called from a view.
struct VolumeEditionAnswer: Sendable, Equatable {
    /// Grouped by edition, fullest first, so the shelf's default tab is the
    /// one with the most spines on it.
    let shelves: [EditionShelf]
    /// The sources that actually put a row on screen, and therefore the ones
    /// owed a credit. Empty when `shelves` is empty — a credit for a source
    /// that contributed nothing is noise. Read
    /// `VolumeCatalogue.requiresPerEntryLink` for what each one obliges.
    let credits: [VolumeCatalogue]
    /// Why a leg is missing, when one is. Keyed by source so a section can
    /// show `InlineFailure` for the leg that failed while another renders.
    let failures: [VolumeCatalogue: APIError]
    /// Set when no shelf could be built at all, so `forthcoming(asOf:)` can
    /// say which kind of nothing this is. Nil once there is a shelf to read.
    let unaskedReason: ForthcomingVolume.UnknownReason?

    var isEmpty: Bool { shelves.isEmpty }

    /// Nothing asked yet. `unaskedReason: .notAsked` rather than nil, so a view
    /// holding this before its legs have run says "we haven't looked" and not
    /// the weaker "nobody listed one" — which is the distinction
    /// `ForthcomingVolume.UnknownReason` exists to keep.
    static let empty = VolumeEditionAnswer(
        shelves: [], credits: [], failures: [:], unaskedReason: .notAsked
    )

    /// The soonest announced volume across every shelf, or why there isn't
    /// one.
    ///
    /// **Never "nothing is coming."** Read `ForthcomingVolume` before writing
    /// any copy against this: `.unknown(.noneListed)` is the case a series
    /// that has genuinely ended and a series nobody has entered a date for
    /// both land in, and no source surveyed can tell those apart.
    func forthcoming(asOf now: Date) -> ForthcomingVolume {
        if let unaskedReason { return .unknown(unaskedReason) }
        let announced = shelves.compactMap { shelf -> EditionVolume? in
            guard case let .announced(volume) = shelf.forthcoming(asOf: now) else { return nil }
            return volume
        }
        guard let soonest = announced.min(by: { lhs, rhs in
            (lhs.releaseDate?.date ?? .distantFuture) < (rhs.releaseDate?.date ?? .distantFuture)
        }) else { return .unknown(.noneListed) }
        return .announced(soonest)
    }
}
