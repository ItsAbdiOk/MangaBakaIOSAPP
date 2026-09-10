import Foundation

/// The reader's whole library, fetched once and shared.
///
/// **This is the most expensive thing the app does, by an order of magnitude.**
/// Measured on a real account on 2026-09-10: 939 entries across 13 requests,
/// **24.7 MB** — because every entry embeds its whole series, tags and all.
/// Everything else the app fetched in that session came to under 1 MB
/// combined.
///
/// And it was being walked three times a launch: once by the Library screen,
/// once to build the taste ledger, once to work out which announced releases
/// are yours. Three walks is 74 MB of someone's data allowance to draw one
/// screen.
///
/// So: one walk per session, shared. Everyone who needs the library asks here
/// and waits on the same request rather than starting their own.
actor LibrarySnapshot {
    /// Pages of a hundred, up to thirty of them — far past any real library and
    /// still bounded. See `LibraryModel` for why the old ten-page cap was a bug.
    private static let pageSize = 100
    private static let pageCap = 30

    /// What one walk produced, including why it stopped.
    ///
    /// The failure is carried rather than swallowed: an empty list and a failed
    /// request are not the same thing, and treating them as one told a reader
    /// with 937 series that they had no account whenever they opened Library on
    /// a bad connection.
    struct Result: Sendable {
        var entries: [LibraryEntry] = []
        /// False when the walk stopped early — a failure, or the page cap.
        var isComplete = true
        var failure: APIError?
    }

    private let library: any LibraryProviding
    private var cached: Result?
    private var inFlight: Task<Result, Never>?

    init(library: any LibraryProviding) {
        self.library = library
    }

    /// Everything, fetched once.
    ///
    /// Concurrent callers share one request rather than starting several — on
    /// launch all three callers arrive at once, and without this they would
    /// each begin their own walk before any of them had finished.
    /// Called as each page lands, so a screen can draw what has arrived rather
    /// than waiting for all of it.
    ///
    /// **This is the difference between a screen that appears and a screen that
    /// takes three and a half seconds.** 939 entries is thirteen requests at
    /// roughly 270ms each; the first hundred arrive in one of those.
    private var onPage: (@Sendable ([LibraryEntry]) -> Void)?

    func observePages(_ handler: @escaping @Sendable ([LibraryEntry]) -> Void) {
        onPage = handler
    }

    func load() async -> Result {
        if let cached { return cached }
        if let inFlight { return await inFlight.value }

        let task = Task<Result, Never> { [library, onPage] in
            var result = Result()
            for page in 1...Self.pageCap {
                do throws(APIError) {
                    let batch = try await library.libraryPage(
                        page: page, limit: Self.pageSize
                    )
                    if batch.isEmpty { break }
                    result.entries.append(contentsOf: batch)
                    // The screen draws what has arrived rather than waiting
                    // for all thirteen pages.
                    onPage?(result.entries)
                    if batch.count < Self.pageSize { break }
                    // Ran out of pages before running out of library.
                    if page == Self.pageCap { result.isComplete = false }
                } catch {
                    result.failure = error
                    result.isComplete = false
                    break
                }
            }
            return result
        }
        inFlight = task
        let result = await task.value
        // A walk that failed is not cached: the next caller should try again
        // rather than inherit a bad connection for the rest of the session.
        if result.failure == nil { cached = result }
        inFlight = nil
        return result
    }

    /// Everything, for callers that do not care why it stopped.
    func all() async -> [LibraryEntry] { await load().entries }

    /// Just the ids, for callers that only need to know what is in there.
    func seriesIDs() async -> Set<Int> {
        Set(await all().map(\.seriesId))
    }

    /// Forgets it, so the next ask refetches.
    ///
    /// Called after a write: adding a series or changing its state makes the
    /// copy in memory wrong, and a stale library is how the app once offered
    /// "Add to library" for something already in it.
    func invalidate() {
        cached = nil
        inFlight?.cancel()
        inFlight = nil
    }
}
