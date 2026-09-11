import Testing
import Foundation
@testable import MangaBaka

/// Links, grouped by what each one is for.
///
/// The API returns four kinds and the app showed six links of any kind under
/// one heading. On series 3397, verified live on 2026-09-11, that is six of
/// twenty-one — 13 webplatform, 4 publisher, 3 info, 1 social — with a
/// publisher's page and an official store listing mixed in among the reading
/// platforms and nothing saying which was which.
@Suite("Link grouping")
struct LinkGroupingTests {
    private func link(
        _ id: String,
        type: String?,
        url: String = "https://example.com"
    ) -> SeriesLink {
        SeriesLink(
            id: id, url: URL(string: url), name: id, nameDisplay: id,
            type: type, language: "en"
        )
    }

    @Test("Every link with a usable URL is kept, whatever its kind")
    func nothingIsDropped() {
        // The old section took the first six of everything. A series with
        // thirteen reading platforms lost its publisher and its official page
        // purely to ordering.
        let links = (1...13).map { link("w\($0)", type: "webplatform") }
            + [link("p1", type: "publisher"), link("i1", type: "info"), link("s1", type: "social")]
        let grouped = SeriesLink.grouped(links)

        #expect(grouped.map(\.count).reduce(0, +) == 16)
        #expect(grouped.map(\.heading) == ["Read it", "Publishers", "More about it", "Social"])
    }

    @Test("Reading platforms lead")
    func readingComesFirst() {
        // Someone on a series page is usually after somewhere to read it.
        let grouped = SeriesLink.grouped([
            link("s1", type: "social"),
            link("w1", type: "webplatform")
        ])
        #expect(grouped.first?.heading == "Read it")
    }

    @Test("An empty kind gets no heading")
    func emptyGroupsAreAbsent() {
        let grouped = SeriesLink.grouped([link("w1", type: "webplatform")])
        #expect(grouped.map(\.heading) == ["Read it"])
    }

    @Test("An unrecognised kind is shown rather than lost")
    func unknownTypesSurvive() {
        // MangaBaka's data is community-maintained and its vocabulary can
        // grow. A new kind appearing should not make a link disappear.
        let grouped = SeriesLink.grouped([
            link("w1", type: "webplatform"),
            link("x1", type: "aggregator"),
            link("x2", type: nil)
        ])
        #expect(grouped.map(\.heading) == ["Read it", "Elsewhere"])
        #expect(grouped.last?.count == 2)
    }

    @Test("A link with an unsafe URL is excluded everywhere")
    func unsafeLinksAreExcluded() {
        // Community-supplied URLs: an arbitrary scheme can trigger another
        // installed app. `safeURL` is what guards that, and grouping must not
        // route around it.
        let grouped = SeriesLink.grouped([
            link("bad", type: "webplatform", url: "javascript:alert(1)"),
            link("good", type: "webplatform")
        ])
        #expect(grouped.first?.count == 1)
    }
}
