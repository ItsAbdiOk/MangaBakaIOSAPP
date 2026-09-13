import Foundation

/// Whether a request is something the reader is looking at right now, or work
/// this app decided to do on its own.
///
/// Threaded through `APIClient` into `RateLimitGate` so background work — a
/// lens count, a publisher-follow check, a catalogue deal for the swipe
/// stack, a Discover prefetch — cannot spend the same 30-a-minute search
/// window the reader's own search needs. 2026-09-13: the series page showed
/// "Too many requests, briefly" while nothing the reader had asked for was
/// even loading, because a background walk had already used most of the
/// window. See `RateLimitGate`'s doc comment for the budget rule this drives.
enum RequestPriority: Sendable, Equatable {
    /// The reader asked for this, directly (typed a search) or by being on
    /// the screen it belongs to (a series page's own legs, a visible feed).
    /// Gets the whole search window — never queued behind background work.
    case userInitiated
    /// Work the app started on its own: a lens count, a follow check, a
    /// catalogue deal dealt while the reader isn't looking at the stack, a
    /// prefetch for a row scrolled past. Capped below the full window and
    /// will wait for room rather than compete with `userInitiated` for it.
    case background
}
