import SwiftUI

/// Loading "What it's actually like" — MangaUpdates' vote-weighted category
/// tags for the series.
///
/// Its own file for the same reason `SeriesDetailView+Releases.swift` and
/// `SeriesDetailView+Store.swift` are: `SeriesDetailView` is at the lint's
/// body-length ceiling.
extension SeriesDetailView {
    /// Asked once, after the page is readable, alongside cast/cadence/taste/
    /// store/releases in `loadOnward()`. Silent (no skeleton, no failure) for
    /// a series with no MangaUpdates id — nothing is asked, so there is
    /// nothing to report a failure about, same reasoning as `loadCadence()`.
    func loadCategories() async {
        guard let mangaUpdatesCategories,
              let rawID = shown.mangaUpdatesID,
              let number = MangaUpdatesID.number(from: rawID)
        else { return }
        isCategoriesLoading = true
        defer { isCategoriesLoading = false }
        do {
            let series = try await mangaUpdatesCategories.series(number: number)
            categories = MangaUpdatesCategories.ranked(series)
            categoriesFailure = nil
        } catch {
            categoriesFailure = error
        }
    }
}
