import Foundation
import Testing
@testable import MangaBaka

/// The release section actually being on the detail page, not just built and
/// tested. See docs/release-sources-2026-09-12.md and the schedule types in
/// MangaBaka/Core/Schedule — none of them were reachable from any screen
/// before this.
@Suite("Release section is wired into the detail page", .enabled(if: SourceTree.isAvailable))
struct ReleaseSectionWiringTests {
    @Test("ReleaseSection is placed before the volumes shelf")
    func placedBeforeVolumesShelf() throws {
        let source = try SourceTree.read("MangaBaka/Features/Detail/SeriesDetailView.swift")
        let releaseRange = try #require(source.range(of: "ReleaseSection("))
        let volumesRange = try #require(source.range(of: "volumesShelf"))
        #expect(releaseRange.lowerBound < volumesRange.lowerBound)
    }

    @Test("Releases are loaded alongside the rest of loadOnward")
    func loadedInLoadOnward() throws {
        let source = try SourceTree.read("MangaBaka/Features/Detail/SeriesDetailView.swift")
        #expect(source.contains("loadReleases()"))
    }
}
