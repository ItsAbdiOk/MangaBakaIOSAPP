import Foundation
import Testing
@testable import MangaBaka

/// Second-pass review (2026-09-14), the series page: items 30, 32 and 63.
@Suite("Series page, second pass")
struct SeriesPageSecondPassTests {
    /// Item 30. `CharacterService` reports a cancelled `URLSession` as a
    /// failure like any other, and `firstCastFailure` handed it to the row
    /// as "Cancelled" with a Retry — on a page the reader had left and, once
    /// item 32 stops the page reloading on return, one they were looking at.
    ///
    /// Expected to fail before the fix with: `firstCastFailure(...) ==
    /// .cancelled` where nil was expected.
    @Test("A cast fetch every source cancelled is not a failure to show")
    func cancelledCastIsNotShown() {
        let cancelled = CharacterService.CharacterCast(
            characters: [], aniList: .failed(.cancelled), shikimori: .failed(.cancelled)
        )
        #expect(cancelled.failed, "control: the service still calls it a failure")
        #expect(SeriesDetailView.firstCastFailure(cancelled) == nil)

        // A real failure beside a cancellation still shows the real one.
        let mixed = CharacterService.CharacterCast(
            characters: [], aniList: .failed(.cancelled), shikimori: .failed(.offline)
        )
        #expect(SeriesDetailView.firstCastFailure(mixed) == .offline)
        // And the rule the other two sections share.
        #expect(SeriesDetailView.presentableFailure(.cancelled) == nil)
        #expect(SeriesDetailView.presentableFailure(.offline) == .offline)
    }

    /// Item 30, the categories and Apple legs, and item 32, the reload —
    /// both live in `@State` on a view, so they are pinned to the source.
    @Test("The page loads once per series, and the other two legs drop a cancellation",
          .enabled(if: SourceTree.isAvailable))
    func loadIsIdempotentAndLegsDropCancellation() throws {
        let page = try SourceTree.read("MangaBaka/Features/Detail/SeriesDetailView.swift")
        // Item 32: `.task(id: series.id)` stays (it is what reloads under the
        // pager); `load()` refuses to repeat itself for a series already in.
        #expect(page.contains(".task(id: series.id) { await load() }"))
        #expect(SourceTree.containsRun(page, "if coreLoadedID != series.id {"))
        let coreGate = "guard extras.failure == nil, !Task.isCancelled else { return }"
            + " coreLoadedID = series.id"
        #expect(SourceTree.containsRun(page, coreGate))
        #expect(SourceTree.containsRun(page, "if onwardLoadedID != series.id {"))
        // The stale bar's retry still bypasses the guard and asks the core again.
        #expect(page.contains("retry: { await loadCore() }"))

        let categories = try SourceTree.read("MangaBaka/Features/Detail/SeriesDetailView+Categories.swift")
        let categoriesGate = "guard let failure = Self.presentableFailure(error) else { return }"
        #expect(SourceTree.containsRun(categories, categoriesGate + " categoriesFailure = failure"))
        #expect(!categories.contains("categoriesFailure = error"))

        let store = try SourceTree.read("MangaBaka/Features/Detail/SeriesDetailView+Store.swift")
        // The comment between the case and its body is the point of the
        // branch, so the run is not contiguous; assert the two statements
        // that matter and that they sit inside the cancelled case.
        #expect(store.contains("case .failure(.cancelled):"))
        #expect(SourceTree.containsRun(store, "isLoadingVolumes = false return"))
    }

    /// Item 63. `CharacterProfileView` built its own `AniListClient()` and
    /// `ShikimoriClient()` per open — each with its own request spacing and
    /// backoff, blind to the 429 the cast fetch had just taken. The row now
    /// threads the service's clients through, and the sheet has no defaults
    /// to fall back to by omission.
    ///
    /// Expected to fail before the fix with: `var aniList: AniListClient =
    /// AniListClient()` present, and the row constructing the sheet with
    /// `character:` alone.
    @Test("The profile sheet is built with the service's own clients", .enabled(if: SourceTree.isAvailable))
    func profileSheetSharesClients() throws {
        let sheet = try SourceTree.read("MangaBaka/Features/Detail/CharacterProfileView.swift")
        #expect(!sheet.contains("var aniList: AniListClient = AniListClient()"))
        #expect(!sheet.contains("var shikimori: ShikimoriClient = ShikimoriClient()"))
        let sheetInit = "init(character: SeriesCharacter, aniList: AniListClient?,"
            + " shikimori: ShikimoriClient?)"
        #expect(sheet.contains(sheetInit))

        let row = try SourceTree.read("MangaBaka/Features/Detail/CharacterRow.swift")
        let sheetCall = "CharacterProfileView(character: character, aniList: aniList, shikimori: shikimori)"
        #expect(row.contains(sheetCall))

        let page = try SourceTree.read("MangaBaka/Features/Detail/SeriesDetailView.swift")
        #expect(page.contains("aniList: characters?.aniList, shikimori: characters?.shikimori"))
        // The other half lives in Core/Characters (lane C): the service has
        // to let its clients out. Until it does, this line fails and so does
        // the build — deliberately, rather than a defaulted client coming
        // back by omission.
        let service = try SourceTree.read("MangaBaka/Core/Characters/CharacterService.swift")
        #expect(!service.contains("private let aniList: AniListClient"), "aniList must be readable")
        #expect(!service.contains("private let shikimori: ShikimoriClient"), "and its shikimori")
    }
}
