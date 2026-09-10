import Foundation
import Testing
@testable import MangaBaka

/// Finding one tag among 7,127.
///
/// The pickers filtered the 500 tags they had loaded, so typing "romance" —
/// which is a tag on thousands of series — emptied the screen with no
/// explanation. Measured against the live API on 2026-09-10:
/// `/v1/tags?limit=500` does not contain Romance; `?q=romance` returns 35 tags
/// including it.
@Suite("Tag search")
struct TagSearchTests {
    private static func tag(_ id: Int, _ name: String, count: Int = 0) -> MangaBaka.Tag {
        MangaBaka.Tag(
            id: id, name: name, namePath: name, parentId: nil, level: nil,
            description: nil, seriesCount: count, isGenre: nil, isSpoiler: nil,
            mergedWith: nil, contentRating: nil
        )
    }

    @Test("Local hits lead, and the API's answer fills in behind them")
    func mergeKeepsBoth() {
        let local = [Self.tag(1, "Workplace Romance", count: 900)]
        let remote = [
            Self.tag(1, "Workplace Romance", count: 900),
            Self.tag(2, "Romance", count: 90_000)
        ]
        let merged = TagSearch.merge(local: local, remote: remote)

        #expect(merged.map(\.id) == [1, 2], "no duplicate, and the local hit stays first")
    }

    @Test("An empty local list still gets everything the API found")
    func remoteAlone() {
        let merged = TagSearch.merge(local: [], remote: [Self.tag(2, "Romance")])
        #expect(merged.map(\.name) == ["Romance"])
    }
}
