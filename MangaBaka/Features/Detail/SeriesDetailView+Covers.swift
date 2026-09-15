import SwiftUI

/// The covers behind the front one, for the fan and the gallery. Its own
/// file for the lint's ceiling on `SeriesDetailView`.
extension SeriesDetailView {
    /// Everything behind the front cover, in the order Abdi asked for
    /// (2026-09-12): the cover on the page, then every volume Apple Books
    /// sells, then the rest of MangaBaka's collection.
    ///
    /// Apple leads because it is the fuller source — MangaBaka's `/images` has
    /// 4 English covers for ONE PIECE, of 115 volumes — so a reader swiping
    /// right off the front cover gets the official run of the book rather than
    /// whichever four alternates happened to be uploaded.
    ///
    /// **That count was page one of an unfiltered request.** Re-measured
    /// 2026-09-15: ONE PIECE (377) holds 931 covers, 465 of them English or
    /// Japanese, and the request now asks for 50 of those at a time
    /// (`SeriesRepository.imagesQuery`). Apple still leads — 50 in upload
    /// order is not volumes 1–50 — but the "four alternates" reading of
    /// MangaBaka's collection was the page size, not the collection.
    ///
    /// Deliberately not deduplicated against MangaBaka's covers. The two
    /// sources are different scans of different editions at different sizes,
    /// with no shared id and no reliable way to tell a true duplicate from the
    /// English and Japanese printings of the same volume; dropping a cover
    /// because it looked like another one is the worse failure here.
    /// The MangaBaka covers leg, on its own so it can be asked again.
    ///
    /// `loadCore` used to await `images(for:)` inline and that was the only
    /// ask the page ever made: a throttled first answer left the fan at one
    /// cover for the rest of the visit, with the `StaleBar`'s Retry — which
    /// re-runs every core leg — the only way back. Now a throttle schedules
    /// one re-ask for when the server said to come back (`coversRetry`), and
    /// a tap on the lone cover re-asks by hand (`openCovers`). The re-ask is
    /// cancelled with the page, like every other leg.
    ///
    /// `.cancelled` writes nothing (item 30: the reader left, or the pager
    /// replaced the series; a live page has nothing to say about it).
    func loadCovers() async {
        isCoversLoading = true
        defer { isCoversLoading = false }
        switch await repository.imagesResult(for: series.id, languages: shown.coverLanguages) {
        case let .success(images):
            covers = images
            coversFailure = nil
        case .failure(.cancelled):
            break
        case let .failure(error):
            coversFailure = error
            scheduleCoversRetry(after: error)
        }
    }

    /// One automatic re-ask, only for a throttle, only once per failure —
    /// and only within `coversRetryCeiling`, past which the reader is more
    /// likely to have left than to still be waiting on a fan.
    private func scheduleCoversRetry(after error: APIError) {
        guard let wait = error.retryAfter, wait <= Self.coversRetryCeiling else { return }
        coversRetry?.cancel()
        coversRetry = Task {
            // A hair past the stated window, so the re-ask is not the first
            // request the gate sees while it still reads as closed.
            try? await Task.sleep(for: .seconds(wait + 0.5))
            guard !Task.isCancelled else { return }
            await loadCovers()
        }
    }

    /// **A guess.** MangaBaka's `Retry-After` on the search gate is 60 s
    /// (`RateLimitGate`); two minutes covers that and the general gate's
    /// window without holding a task open for a reader who has moved on.
    static let coversRetryCeiling: TimeInterval = 120

    var otherCovers: [SeriesImage] {
        Self.gallery(
            mangaBaka: covers,
            apple: appleVolumes,
            google: googleVolumes,
            front: preferred,
            languages: shown.coverLanguages
        )
    }

    /// `front` is the cover already shown on the page, dropped so the fan never
    /// repeats it. Apple's volumes come in store order and are sorted by number
    /// here, because the search API ranks by relevance, not by volume.
    ///
    /// `languages` narrows MangaBaka's collection to English and the series'
    /// own — see `Series.coverLanguages`. Nil means no narrowing, which is how
    /// a novel and an untypeable series both arrive here.
    nonisolated static func gallery(
        mangaBaka: [SeriesImage],
        apple: [AppleBooksVolume],
        google: [GoogleBooksVolume],
        front: SeriesImage?,
        languages: Set<String>?
    ) -> [SeriesImage] {
        var rest = mangaBaka.filter { speaks($0.language, in: languages) }
        if let front { rest.removeAll { $0.id == front.id } }
        // Apple's own covers are exempt. They are the editions the reader can
        // actually buy in their own store, which is the reason they were put
        // at the front of this list in the first place, and the store sends no
        // language field to filter them by.
        // Apple's run, then any volume number only Google has, then the rest.
        // Same rule as the shelf below the fold (`VolumeShelf.merge`): Apple
        // wins every number they share, so the 800px store art is never
        // replaced by Google's upscaled thumbnail.
        let appleNumbers = Set(apple.map(\.number))
        let store = apple.sorted { $0.number < $1.number }.compactMap(\.galleryImage)
        let filled = google
            .filter { !appleNumbers.contains($0.number) }
            .sorted { $0.number < $1.number }
            .compactMap(\.galleryImage)
        return store + filled + rest
    }

    /// Prefix-matched, because the wire carries regional tags — "pt-br" is
    /// Portuguese and "zh-hans" is Chinese, and an exact match would keep
    /// neither. A cover whose language the API did not send is kept: an
    /// unlabelled cover is far more likely to be a missing field than a
    /// Spanish edition, and hiding real artwork over a null is the worse
    /// mistake.
    nonisolated private static func speaks(_ language: String?, in allowed: Set<String>?) -> Bool {
        guard let allowed else { return true }
        guard let language = language?.lowercased(), !language.isEmpty else { return true }
        return allowed.contains { language.hasPrefix($0) }
    }

    /// True while any request this page made is still out.
    var isAnyLegLoading: Bool {
        isLoading || isCoversLoading || isLoadingVolumes || isLoadingEditions
            || isCastLoading || isCadenceLoading || isCategoriesLoading || isReleasesLoading
    }

    /// Snapshots the gallery's images at the moment of the tap — see
    /// `openCoversImages` — and refuses to open on a series with nothing to
    /// show, where a full-screen cover over an empty pager was a dead end
    /// with a close button and nothing else.
    func openCovers(startingAt index: Int) {
        let images = otherCovers
        // A fan of one over a failed ask: the tap is the retry. The reader
        // pressed the cover wanting more of them, and re-asking here is what
        // "load in when I press it" means once the first ask was throttled.
        if images.isEmpty, coversFailure != nil, !isCoversLoading {
            Task { await loadCovers() }
            return
        }
        guard !images.isEmpty else { return }
        openCoversImages = images
        openCoversAt = GalleryStart(value: index)
    }

    /// Covers that landed after the gallery opened join it at the end —
    /// never in the middle, so the page under a thumb keeps its number (gap
    /// 67's rule, kept). Apple's and Google's volumes arrive on their own
    /// legs and MangaBaka's after a throttle wait, so this is common.
    func appendLateCovers(_ current: [SeriesImage]) {
        guard openCoversAt != nil else { return }
        let seen = Set(openCoversImages.map(\.id))
        let late = current.filter { !seen.contains($0.id) }
        guard !late.isEmpty else { return }
        openCoversImages += late
    }
}
