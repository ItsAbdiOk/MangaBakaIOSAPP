import Foundation
import Testing
@testable import MangaBaka

/// The small controls that make a screen usable, and that nothing else notices
/// when they disappear.
///
/// Every one of these was reported by Abdi as missing on 2026-09-10, having
/// been absent since the screen was built: there is no test that fails when a
/// field cannot be cleared, so these are the tests.
@Suite("Flow affordances", .enabled(if: SourceTree.isAvailable))
struct FlowAffordanceTests {
    @Test("Every search field can be cleared", arguments: [
        "MangaBaka/Features/Search/SearchView.swift",
        "MangaBaka/Features/Search/TagPickerSheet.swift",
        "MangaBaka/Features/Shared/InlineSearchField.swift",
        "MangaBaka/Features/Mix/SeedPickerSheet.swift"
    ])
    func fieldsClear(path: String) throws {
        let source = try SourceTree.read(path)
        #expect(source.contains("SearchClearButton"), "\(path) has a field with no way out")
    }

    /// The "+" opened the Search TAB, which keeps its query, its results and
    /// its pushed series page. Adding a second seed therefore landed you back
    /// on the first seed's page.
    @Test("Adding a seed does not hand the reader back their last search")
    func seedPickerIsItsOwnSearch() throws {
        let mix = try SourceTree.read("MangaBaka/Features/Mix/MixView.swift")
        #expect(mix.contains("SeedPickerSheet"))
        #expect(!mix.contains("onPickSeed"), "the tab-switching route is gone, not merely unused")

        let sheet = try SourceTree.read("MangaBaka/Features/Mix/SeedPickerSheet.swift")
        #expect(
            sheet.contains("SearchModel(repository: repository)"),
            "a search of its own, made fresh with the sheet"
        )
    }

    /// Artwork is copyable where it is something to look at, and deliberately
    /// not on the swipe stack's cards, where a context menu competes with the
    /// drag for the same press.
    @Test("Artwork can be copied from the places you look at it")
    func artworkIsCopyable() throws {
        let gallery = try SourceTree.read("MangaBaka/Features/Detail/CoverGallery.swift")
        #expect(gallery.contains("copyableArtwork"))
        let characters = try SourceTree.read("MangaBaka/Features/Detail/CharacterRow.swift")
        #expect(characters.contains("copyableArtwork"))
        let stack = try SourceTree.read("MangaBaka/Features/Stack/StackView.swift")
        #expect(!stack.contains("copyableArtwork"), "a menu here would fight the swipe")
    }

    /// A page must not be poorer for the door you came in by — see
    /// `SeriesMergeTests`.
    @Test("The series page shows the merged series, not the copy it arrived with")
    func detailUsesTheFullSeries() throws {
        let detail = try SourceTree.read("MangaBaka/Features/Detail/SeriesDetailView.swift")
        #expect(detail.contains("filling(gapsFrom:"))
        for reader in ["DetailHero(\n                    series: shown", "DetailStatsStrip(series: shown"] {
            #expect(detail.contains(reader))
        }
        #expect(
            detail.contains("if let description = shown.description"),
            "the synopsis is the field that was missing from the stack"
        )
    }
}
