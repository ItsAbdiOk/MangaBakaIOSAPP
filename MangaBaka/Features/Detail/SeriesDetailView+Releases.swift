import SwiftUI

/// Loading everything `loadOnward` fans out to besides the volumes shelf and
/// the taste ledger: the release section, the cast, and the cadence.
///
/// Its own file for the same reason `SeriesDetailView+Store.swift` exists:
/// `SeriesDetailView` is at the lint's body-length ceiling. Grouped with
/// releases rather than split further, since all three are "the rest of the
/// page, once it's readable" and none is large enough alone to earn its own
/// file.
extension SeriesDetailView {
    /// One request per provider, after the page is readable and after
    /// `extras` has loaded — `extras.links` is what tells the providers which
    /// publisher, if any, actually carries this series.
    func loadReleases() async {
        guard let releaseFeeds else { return }
        isReleasesLoading = true
        defer { isReleasesLoading = false }
        releases = await releaseFeeds.report(for: shown, links: extras.links)
    }

    /// Re-runs just the Similar feed — the retry `DetailOnwardRows` offers
    /// when that row alone failed. Doing it alone rather than through the
    /// whole page's `load()` keeps a retry from a section slot from paying
    /// for `extras`, the cast and the release feeds all over again.
    func loadSimilar() async {
        let result = await repository.feed(.similar(seriesId: series.id), forceRefresh: true)
        similar = result.series
        similarNotes = result.notes
        similarOrigin = result.origin
        similarFailure = result.blockingError
    }

    func loadAlsoLike() async {
        let result = await repository.feed(.readersAlsoLike(seriesId: series.id), forceRefresh: true)
        alsoLike = result.series
        alsoLikeNotes = result.notes
        alsoOrigin = result.origin
        alsoLikeFailure = result.blockingError
    }

    /// Both tracker ids come from MangaBaka's own `source` block, so no lookup
    /// is needed to find them. A series carrying neither has no cast to show,
    /// and in that case nothing is asked and no row appears.
    func loadCast() async {
        guard let characters,
              shown.aniListID != nil || shown.shikimoriID != nil
        else { return }
        isCastLoading = true
        defer { isCastLoading = false }
        let result = await characters.characters(
            aniListID: shown.aniListID,
            shikimoriID: shown.shikimoriID
        )
        // `.failed` is true only when every source asked came back with a
        // real error — "asked and found nobody" (both sources answering
        // empty) stays silent, same as before (gap 17).
        let failure = result.failed ? Self.firstCastFailure(result) : nil
        // Every source asked was cancelled: the reader left mid-fetch, or
        // the pager replaced the series. Nothing is written — not the empty
        // cast either, which would wipe a row that had already answered
        // (item 30; `presentableFailure` says why `.cancelled` never shows).
        if result.failed, failure == nil { return }
        cast = result.characters
        castFailure = failure
    }

    /// Which of the two sources' own `APIError` to show, when both were
    /// asked and both failed. Arbitrary when both did — no caller
    /// distinguishes between them today, same reasoning as
    /// `SeriesRepository.combinedFailure`. A `.cancelled` outcome is skipped
    /// over (`presentableFailure`): `CharacterService` reports a cancelled
    /// `URLSession` as a failure like any other, and it used to reach the
    /// row as "Cancelled" with a Retry (item 30). Nil when every failure
    /// was a cancellation.
    nonisolated static func firstCastFailure(_ cast: CharacterService.CharacterCast) -> APIError? {
        for outcome in [cast.aniList, cast.shikimori] {
            if case let .failed(error) = outcome, let shown = presentableFailure(error) { return shown }
        }
        return nil
    }

    /// Asked separately from everything else, and after it.
    ///
    /// MangaUpdates spaces requests at one every three seconds, so this can
    /// take noticeably longer than the rest of the page. Awaiting it alongside
    /// the others would hold the whole screen on the slowest thing on it; the
    /// hero shows a spinner in its place instead.
    func loadCadence() async {
        // Nothing is asked, and no spinner shown, for a series that has
        // finished or stopped — see `canPredict`.
        guard let schedule,
              shown.mangaUpdatesID != nil,
              ReleaseScheduleService.canPredict(status: shown.status)
        else { return }
        isCadenceLoading = true
        defer { isCadenceLoading = false }
        switch await schedule.cadence(for: shown) {
        case let .measured(estimate):
            cadence = estimate
            cadenceFailure = nil
        case .failed(.cancelled):
            // The reader left, or the page was replaced under the pager.
            // `ReleaseScheduleService.cadence(for:)` returns this rather than
            // swallowing it, deliberately, so the one caller that can tell a
            // live page from a dead one makes the call — and a live page has
            // nothing to say about a request nobody is waiting for.
            // `APIError.cancelled`'s own doc comment: never on screen
            // (item 40).
            cadenceFailure = nil
        case let .failed(error):
            // Distinct from `.none` (measured, too little history) and
            // `.unavailable` (no MangaUpdates id) — both of those stay
            // silent, same as before. Only a real failed ask gets a line
            // (gap 18).
            cadenceFailure = error
        case .none, .unavailable:
            cadenceFailure = nil
        }
    }
}
