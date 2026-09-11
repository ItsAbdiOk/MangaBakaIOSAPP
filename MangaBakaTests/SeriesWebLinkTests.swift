import Foundation
import Testing
@testable import MangaBaka

/// The series' page on mangabaka.org, shared out and opened in.
@Suite("Series web links")
struct SeriesWebLinkTests {
    /// `/manhwa/3397` redirects to `/manhwa/3397/Solo-Leveling` with a 301,
    /// as does a bare `/3397`; measured 2026-09-11.
    @Test("The shared link is the typed page, or the bare id without a type")
    func sharedLink() {
        let typed = SeriesFactory.make(id: 3397, type: "Manhwa")
        #expect(SeriesWebLink.url(for: typed)?.absoluteString == "https://mangabaka.org/manhwa/3397")
        let untyped = SeriesFactory.make(id: 3397)
        #expect(SeriesWebLink.url(for: untyped)?.absoluteString == "https://mangabaka.org/3397")
    }

    @Test("A mangabaka.org series link names its series")
    func parsesSeriesLinks() throws {
        for path in ["/manhwa/3397/Solo-Leveling", "/manhwa/3397", "/3397", "/manga/3397/"] {
            let url = try #require(URL(string: "https://mangabaka.org\(path)"))
            #expect(SeriesWebLink.seriesID(from: url) == 3397, Comment(rawValue: path))
        }
        let www = try #require(URL(string: "https://www.mangabaka.org/manhwa/3397/x"))
        #expect(SeriesWebLink.seriesID(from: www) == 3397)
    }

    /// Other hosts and the site's other numbered pages are not series.
    @Test("Anything else is nil")
    func rejectsOthers() throws {
        for string in [
            "https://mangabaka.org/settings/api",
            "https://mangabaka.org/pages/24",
            "https://api.mangabaka.org/v1/series/3397",
            "https://example.com/manhwa/3397"
        ] {
            let url = try #require(URL(string: string))
            #expect(SeriesWebLink.seriesID(from: url) == nil, Comment(rawValue: string))
        }
    }
}

@Suite("Series links are wired", .enabled(if: SourceTree.isAvailable))
struct SeriesWebLinkWiringTests {
    @Test("The series page shares its link and the root opens one")
    func wiring() throws {
        let detail = try SourceTree.read("MangaBaka/Features/Detail/SeriesDetailView.swift")
        #expect(detail.contains("shareURL: SeriesWebLink.url(for: shown)"))
        let root = try SourceTree.read("MangaBaka/App/RootView.swift")
        let handler = ".onOpenURL { url in\n                guard let id = SeriesWebLink.seriesID(from: url)"
        #expect(root.contains(handler))
    }
}
