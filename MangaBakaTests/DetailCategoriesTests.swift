import Testing
@testable import MangaBaka

/// `DetailCategories`' pure helpers — the branch a given (categories,
/// isLoading, failure) triple renders as, and the chip text — exercised
/// without building the view. See `DetailCategories.state` and its `Category`
/// label helpers.
@Suite("Detail categories section")
struct DetailCategoriesTests {
    private func category(_ name: String = "Betrayal", _ score: Int = 32) -> MangaUpdatesCategories.Category {
        MangaUpdatesCategories.Category(name: name, score: score)
    }

    // MARK: - State selection

    @Test("Loading with nothing yet and no failure shows the skeleton")
    func loadingShowsSkeleton() {
        let state = DetailCategories.state(categories: [], isLoading: true, failure: nil)
        #expect(state == .skeleton)
    }

    @Test("A failure with nothing to show shows the failure line")
    func failureWithNothingCachedShowsFailed() {
        let state = DetailCategories.state(
            categories: [], isLoading: false, failure: .transport(underlying: "x", party: .mangaUpdates)
        )
        #expect(state == .failed)
    }

    @Test("Categories present renders the chips, even mid-retry")
    func categoriesPresentShowsChips() {
        // isLoading true (a retry in flight) must not hide already-loaded
        // chips — the same "don't blank a screen that has content" rule
        // `Fetched<T>` draws everywhere else.
        let state = DetailCategories.state(categories: [category()], isLoading: true, failure: nil)
        #expect(state == .chips)
    }

    @Test("Nothing loading, nothing failed, nothing returned is absent — not a failure state")
    func answeredEmptyIsAbsent() {
        let state = DetailCategories.state(categories: [], isLoading: false, failure: nil)
        #expect(state == .absent)
    }

    // MARK: - Chip text

    @Test("A chip reads as \"name · score\"")
    func chipLabelFormat() {
        #expect(DetailCategories.chipLabel(category("Abuse of Power", 32)) == "Abuse of Power · 32")
    }

    @Test("A chip's spoken label says \"votes\" instead of reading the separator")
    func chipAccessibilityLabelFormat() {
        let label = DetailCategories.chipAccessibilityLabel(category("Abuse of Power", 33))
        #expect(label == "Abuse of Power, 33 votes")
    }

    // MARK: - Expand toggle

    @Test("12 categories or fewer show no expand toggle")
    func noToggleAtOrBelowCollapsedCount() {
        #expect(!DetailCategories.showsExpandToggle(count: DetailCategories.collapsedCount))
    }

    @Test("More than 12 categories show the expand toggle")
    func togglesAboveCollapsedCount() {
        #expect(DetailCategories.showsExpandToggle(count: DetailCategories.collapsedCount + 1))
    }
}
