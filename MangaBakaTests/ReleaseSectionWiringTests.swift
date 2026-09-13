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

/// Gap 19/20: a series whose publisher was matched and then failed used to
/// have no release section at all — identical to a series no provider
/// carries — and a matched series popped the section in after the page had
/// already settled, with no loading state in between.
@Suite("The release section tells a failure apart from silence")
struct ReleaseSectionStateTests {
    private func report(failedSources: [ReleaseSource]) -> ReleaseReport {
        let failures = failedSources.map {
            ReleaseFailure(source: $0, error: .server(status: 500, message: "", party: .webtoons))
        }
        return ReleaseReport(summary: .none, source: nil, sourceName: nil, gap: .none, failures: failures)
    }

    @Test("A provider that was carrying this series and failed is shown")
    func failedProviderShown() {
        let state = ReleaseSection.sectionState(report: report(failedSources: [.webtoons]), isLoading: false)
        guard case .failed = state else {
            Issue.record("expected .failed, got \(state)")
            return
        }
    }

    @Test("Nothing carried and nothing failed stays hidden")
    func nothingCarriedIsHidden() {
        #expect(ReleaseSection.sectionState(report: report(failedSources: []), isLoading: false) == .hidden)
    }

    @Test("Loading wins while the providers are still being asked")
    func loadingWins() {
        #expect(ReleaseSection.sectionState(report: report(failedSources: []), isLoading: true) == .loading)
    }

    @Test("The loading skeleton is gated on a matched provider link")
    func skeletonOnlyWhenMatched() {
        let webtoons = SeriesLink(
            id: "1", url: URL(string: "https://www.webtoons.com/en/x/y/list?title_no=1"),
            name: "webtoons.com", nameDisplay: nil, type: "webplatform", language: "en"
        )
        let unrelated = SeriesLink(
            id: "2", url: URL(string: "https://example.com"), name: "example.com",
            nameDisplay: nil, type: "webplatform", language: "en"
        )
        #expect(ReleaseSection.isMatched(links: [webtoons]))
        #expect(!ReleaseSection.isMatched(links: [unrelated]))
        #expect(!ReleaseSection.isMatched(links: []))
    }
}
