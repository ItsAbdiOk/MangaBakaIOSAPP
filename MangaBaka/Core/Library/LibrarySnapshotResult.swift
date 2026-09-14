import Foundation

/// The two answers a library read can give, kept apart at the type level.
///
/// **Why this file exists.** `LibrarySnapshot.Result` has carried `failure`
/// since 2026-09-13, and it was still true that nine of twelve callers went
/// through `all()`/`seriesIDs()`, which returned `[]` for "the reader has no
/// series" and `[]` for "the walk failed" alike. Two of those nine wrote data
/// off the confusion: `TasteLedger.absorb([])` retracted all 945 sources on one
/// offline series-page open, and an import run after a failed walk re-`add`ed
/// every row because its "never downgrade progress" guard was comparing against
/// an empty library.
///
/// Fixing nine call sites one at a time leaves the tenth. So the discard is
/// made visible instead: a caller that is about to *act* on the library — write
/// to the account, retract what is missing, conclude a series is not there —
/// asks for `wholeLibrary`, which is `nil` rather than empty when the walk did
/// not deliver. A caller that only draws what arrived reads `entries` and the
/// name says it is doing that.
extension LibrarySnapshot.Result {
    /// Whether these entries are the reader's whole library.
    ///
    /// False for a failed walk *and* for one that stopped at the thirty-page
    /// cap: both mean "there is more than this", which is the only thing a
    /// caller deciding something is absent needs to know. `failure == nil` is
    /// not sufficient on its own — `walk` sets `isComplete = false` without a
    /// failure when it runs out of pages.
    var isWholeLibrary: Bool { failure == nil && isComplete }

    /// The reader's whole library, or `nil` when this walk did not deliver it.
    ///
    /// `nil` and `[]` are different answers and the optional is the point:
    /// `[]` means the reader has no series, `nil` means the app does not know
    /// what the reader has. Use this anywhere the *absence* of a series is
    /// about to cause a write, a retraction or a refusal.
    var wholeLibrary: [LibraryEntry]? { isWholeLibrary ? entries : nil }

    /// The ids of everything this walk returned, however far it got.
    ///
    /// The display counterpart of `wholeLibrarySeriesIDs`: fine for dimming
    /// rows that are already in the library, wrong for deciding one is not.
    var seriesIDs: Set<Int> { Set(entries.map(\.seriesId)) }

    /// The ids of the reader's whole library, or `nil` when this walk did not
    /// deliver it. See `wholeLibrary`.
    var wholeLibrarySeriesIDs: Set<Int>? { isWholeLibrary ? seriesIDs : nil }
}
