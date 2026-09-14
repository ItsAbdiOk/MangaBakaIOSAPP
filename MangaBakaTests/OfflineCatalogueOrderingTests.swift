import Foundation
import Testing
@testable import MangaBaka

/// Tests for the review's F15 fix (persistence review, 2026-09-14):
/// `filteredAndSorted` used to filter the whole 19,300-row index and then
/// sort the survivors on every call — an O(n log n) sort over ~15,000 rows
/// per page turn and per filter-panel keystroke. The fix sorts once at load
/// (`OfflineCatalogue.LoadState.entries`/`byScore`) and has `filteredAndSorted`
/// choose which pre-sorted array to filter from, relying on `Array.filter`
/// preserving the order of its input. This file's job is the control the
/// review specifically asked for: prove the *ordering* produced today is
/// identical to what a fresh, independent filter-then-sort produces — a
/// speed win that silently reordered results would not be worth taking.
///
/// Kept separate from `OfflineCatalogueTests` (this lane owns
/// `OfflineCatalogue.swift` but not the existing test file) rather than
/// folding these in, and duplicates the raw-decode control rather than
/// reaching into `OfflineCatalogueTests.rawEntries` (`fileprivate` there, and
/// sharing it would also mean sharing decode code with the thing being
/// checked — the same reason that file gives for decoding independently).
@Suite("Offline catalogue: pre-sorted ordering (F15)")
struct OfflineCatalogueOrderingTests {
    private struct RawWire: Decodable {
        let version: Int
        let built: String
        let series: [OfflineIndexEntry]
    }

    private final class BundleMarker {}

    private static let rawEntries: [OfflineIndexEntry] = {
        let inTestBundle = Bundle(for: BundleMarker.self)
            .url(forResource: "OfflineIndex", withExtension: "json.gz")
        guard
            let url = inTestBundle ?? Bundle.main.url(forResource: "OfflineIndex", withExtension: "json.gz"),
            let gzipped = try? Data(contentsOf: url),
            let raw = try? Gunzip.decompress(gzipped),
            let wire = try? JSONDecoder().decode(RawWire.self, from: raw)
        else { return [] }
        return wire.series
    }()

    private func query(tags: [String] = [], sort: String? = nil) -> SearchQuery {
        var result = SearchQuery()
        result.tags = tags
        result.sort = sort
        return result
    }

    /// Independent control matching the *old* `OfflineCatalogue` algorithm
    /// exactly (filter, then sort the survivors) — this is the "today" this
    /// suite proves the new load-time-sorted path still agrees with.
    private func naiveFilterThenSort(tag tagID: Int, sort: String?) -> [Int] {
        let filtered = Self.rawEntries.filter { $0.tagIDs.contains(tagID) }
        let sorted: [OfflineIndexEntry]
        switch sort {
        case "score_desc":
            sorted = filtered.sorted { ($0.rating ?? -1) > ($1.rating ?? -1) }
        default:
            sorted = filtered.sorted { ($0.popularity ?? .max) < ($1.popularity ?? .max) }
        }
        return sorted.map(\.id)
    }

    /// Tag 36 is "Fantasy" — the same tag `OfflineCatalogueTests` uses for
    /// its subset test, chosen again here so this suite exercises a real,
    /// large subset rather than an edge case of one or two rows.
    @Test("Default (popularity) order matches a fresh filter-then-sort of the raw export")
    func defaultOrderMatchesNaiveControl() async {
        let expectedOrder = naiveFilterThenSort(tag: 36, sort: nil)
        #expect(!expectedOrder.isEmpty, "Sanity: the fixture must carry this tag somewhere")

        let catalogue = OfflineCatalogue()
        let hits = await catalogue.matches(
            query(tags: ["Fantasy"]), allowedRatings: [], allowedTypes: [], blockedTags: [],
            limit: Self.rawEntries.count, offset: 0
        )
        #expect(hits.map(\.id) == expectedOrder)
    }

    @Test("score_desc order matches a fresh filter-then-sort of the raw export")
    func scoreDescOrderMatchesNaiveControl() async {
        let expectedOrder = naiveFilterThenSort(tag: 36, sort: "score_desc")
        #expect(!expectedOrder.isEmpty, "Sanity: the fixture must carry this tag somewhere")

        let catalogue = OfflineCatalogue()
        let hits = await catalogue.matches(
            query(tags: ["Fantasy"], sort: "score_desc"), allowedRatings: [], allowedTypes: [],
            blockedTags: [], limit: Self.rawEntries.count, offset: 0
        )
        #expect(hits.map(\.id) == expectedOrder)
    }

    /// Sanity that the two orderings actually differ for this tag — if they
    /// didn't, the two tests above could both pass by coincidence (e.g. if
    /// `sort` were ignored entirely).
    @Test("Popularity order and score_desc order are not the same sequence")
    func theTwoOrdersDiffer() {
        let byPopularity = naiveFilterThenSort(tag: 36, sort: nil)
        let byScore = naiveFilterThenSort(tag: 36, sort: "score_desc")
        #expect(byPopularity != byScore)
    }
}
