import SwiftUI

/// Loading "What it's actually like" — MangaUpdates' vote-weighted category
/// tags for the series.
///
/// Its own file for the same reason `SeriesDetailView+Releases.swift` and
/// `SeriesDetailView+Store.swift` are: `SeriesDetailView` is at the lint's
/// body-length ceiling.
///
/// **Not wired into `SeriesDetailView` by this file** — `SeriesDetailView.swift`
/// itself is owned elsewhere this round. It needs:
/// - a property, alongside `releaseFeeds`: `var mangaUpdatesCategories:
///   MangaUpdatesClient? = MangaUpdatesClient()` (a sensible live default, so
///   no caller needs to change to get the section — it can be swapped for
///   `nil` anywhere a series page should not carry the section).
/// - three `@State` vars, alongside `releases`/`isReleasesLoading`:
///   `@State var categories: [MangaUpdatesCategories.Category] = []`,
///   `@State var isCategoriesLoading = false`,
///   `@State var categoriesFailure: APIError?`.
/// - `async let categories: Void = loadCategories()` added to `loadOnward()`'s
///   list (and to the final `await (...)` tuple) — it depends on nothing
///   `loadOnward()`'s other legs produce, so it can sit anywhere in the list.
/// - `DetailCategories(categories: categories, isLoading: isCategoriesLoading,
///   failure: categoriesFailure, onRetry: loadCategories)` placed one line
///   after wherever `TrackerScores(series: shown)` (or equivalent) sits in the
///   body.
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
