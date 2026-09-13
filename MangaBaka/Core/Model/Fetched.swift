import Foundation

/// What a read produced, and whether it can be trusted as the whole answer.
///
/// The largest single family in the failure review (systemic cause (a)):
/// `SeriesRepository.mix`, `.images`, five of six `extras` legs,
/// `CharacterService`, `ReleaseSchedule.cadence`, three feed clients and more
/// all collapse "asked and got nothing" and "asked and failed" into the same
/// `[]` / `nil` / `.empty`, so the caller — and then the screen — cannot tell
/// a quiet section from a broken one. `FeedResult` (`SeriesRepository.swift`)
/// and `AppleBooksClient`'s nil-vs-`[]` already draw this line correctly by
/// hand, in two different shapes; this is that distinction, generalised, so
/// the next caller does not reinvent it a third way.
enum Fetched<T: Sendable>: Sendable {
    /// Nothing has been asked for yet.
    case idle
    /// A request is in flight. Carries no stale value on purpose — a caller
    /// that wants to keep showing old content *while* loading fresh content
    /// should stay on `.loaded(_, isPartial: true, …)` rather than routing
    /// through `.loading`; this case is for "nothing to show yet".
    case loading
    /// A successful read.
    /// - Parameters:
    ///   - fetchedAt: when this value was obtained, so a screen can say how
    ///     old it is.
    ///   - isPartial: true when only some of what was asked for came back —
    ///     five of six `extras` legs, a library walk that stopped partway.
    ///     The cache layer must refuse to persist a value with this set,
    ///     since writing a partial result to a 6-hour cache is how gap 9
    ///     (`extras` cached incomplete) happened.
    case loaded(T, fetchedAt: Date, isPartial: Bool)
    /// The read failed. `stale` is the last good value, when one exists, so
    /// the screen can show it under a `StaleBar` rather than an empty state.
    case failed(APIError, stale: T?)

    /// The value to show, whether fresh or stale. Nil only for `.idle`,
    /// `.loading`, or a `.failed` with nothing cached.
    var value: T? {
        switch self {
        case .idle, .loading: nil
        case let .loaded(value, _, _): value
        case let .failed(_, stale): stale
        }
    }

    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }

    /// The failure, when the most recent attempt failed — regardless of
    /// whether stale content is still being shown alongside it.
    var error: APIError? {
        if case let .failed(error, _) = self { return error }
        return nil
    }

    /// True when there is something to render: a loaded value, or a failure
    /// that still has a stale value to fall back on. False for `.idle`,
    /// `.loading`, and a `.failed` with nothing cached — the three states a
    /// screen has nothing to draw for yet.
    var isUsable: Bool {
        switch self {
        case .idle, .loading: false
        case .loaded: true
        case let .failed(_, stale): stale != nil
        }
    }

    /// The error to show as a full failure screen — a `.failed` with no
    /// stale value to fall back on. Mirrors `FeedResult.blockingError`: a
    /// failure that still has content to show is not blocking, it's a
    /// `StaleBar`.
    var blockingError: APIError? {
        guard case let .failed(error, stale) = self, stale == nil else { return nil }
        return error
    }
}

extension Fetched: Equatable where T: Equatable {}
