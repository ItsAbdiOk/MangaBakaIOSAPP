import Foundation
import Testing
@testable import MangaBaka

/// "More of what you finished": candidate selection, filtering, and the
/// model's request budget.
@Suite("Continuations")
struct ContinuationsTests {
    private func entry(
        _ id: Int,
        state: LibraryEntry.State = .completed,
        finishDate: Date? = nil,
        series: Series? = nil
    ) -> LibraryEntry {
        LibraryEntry(
            id: id, seriesId: series?.id ?? id, state: state, progressChapter: nil,
            progressVolume: nil, rating: nil, note: nil, startDate: nil,
            finishDate: finishDate, numberOfRereads: nil, priority: nil,
            isPrivate: nil, readLink: nil, series: series ?? SeriesFactory.make(id: id)
        )
    }

    /// A library entry whose series never loaded. `entry(series: nil)` cannot
    /// express this — its `??` fabricates one — so a test that passed
    /// `series: nil` was silently testing an entry that had a series.
    private func entryWithoutSeries(_ id: Int, state: LibraryEntry.State = .completed) -> LibraryEntry {
        LibraryEntry(
            id: id, seriesId: id, state: state, progressChapter: nil,
            progressVolume: nil, rating: nil, note: nil, startDate: nil,
            finishDate: Date(), numberOfRereads: nil, priority: nil,
            isPrivate: nil, readLink: nil, series: nil
        )
    }

    private func relation(
        id: String = UUID().uuidString,
        type: String?,
        seriesID: Int
    ) -> SeriesRelationship {
        SeriesRelationship(
            id: id, relationType: type, note: nil, series: SeriesFactory.make(id: seriesID)
        )
    }

    // MARK: - candidates

    @Test("Only completed entries with a series are candidates")
    func candidatesFiltersState() {
        let day = Date()
        let candidates = Continuations.candidates(
            finished: [
                entry(1, state: .completed, finishDate: day),
                entry(2, state: .reading, finishDate: day),
                entryWithoutSeries(3)
            ],
            libraryIDs: []
        )
        #expect(candidates.map(\.id) == [1])
    }

    @Test("Most recently finished first, nil finish dates last")
    func candidatesOrdering() {
        let now = Date()
        let earlier = now.addingTimeInterval(-86400)
        let candidates = Continuations.candidates(
            finished: [
                entry(1, finishDate: earlier),
                entry(2, finishDate: nil),
                entry(3, finishDate: now)
            ],
            libraryIDs: []
        )
        #expect(candidates.map(\.id) == [3, 1, 2])
    }

    @Test("Capped at the limit")
    func candidatesLimit() {
        let entries = (1...10).map { entry($0, finishDate: Date()) }
        let candidates = Continuations.candidates(finished: entries, libraryIDs: [], limit: 8)
        #expect(candidates.count == 8)
    }

    // MARK: - pick

    @Test("Keeps only continuation types, dropping prequels and sources")
    func pickDropsNonContinuationTypes() {
        let base = entry(1)
        let relations = [
            Continuations.RelationSource(from: base, relation: relation(type: "sequel", seriesID: 2)),
            Continuations.RelationSource(from: base, relation: relation(type: "prequel", seriesID: 3)),
            Continuations.RelationSource(from: base, relation: relation(type: "source", seriesID: 4))
        ]
        let picked = Continuations.pick(relations, libraryIDs: [])
        #expect(picked.map(\.series.id) == [2])
    }

    @Test("Drops continuations already in the library")
    func pickDropsInLibrary() {
        let base = entry(1)
        let relations = [
            Continuations.RelationSource(from: base, relation: relation(type: "sequel", seriesID: 2))
        ]
        let picked = Continuations.pick(relations, libraryIDs: [2])
        #expect(picked.isEmpty)
    }

    @Test("Dedupes by series id, keeping the first and the order")
    func pickDedupesKeepsOrder() {
        let base = entry(1)
        let relations = [
            Continuations.RelationSource(from: base, relation: relation(type: "sequel", seriesID: 3)),
            Continuations.RelationSource(from: base, relation: relation(type: "sequel", seriesID: 2)),
            Continuations.RelationSource(
                from: base, relation: relation(id: "dup", type: "spin_off", seriesID: 3)
            )
        ]
        let picked = Continuations.pick(relations, libraryIDs: [])
        #expect(picked.map(\.series.id) == [3, 2])
    }

    @Test("because and label carry through from the source relation")
    func pickCarriesBecauseAndLabel() {
        let base = entry(1, series: SeriesFactory.make(id: 1, title: "Berserk"))
        let relations = [
            Continuations.RelationSource(from: base, relation: relation(type: "spin_off", seriesID: 9))
        ]
        let picked = Continuations.pick(relations, libraryIDs: [])
        #expect(picked.first?.because == "Berserk")
        #expect(picked.first?.label == "Spin Off")
    }

    // MARK: - ContinuationsModel

    /// Counts `relationships(for:)` calls, so tests can assert the request
    /// budget without inspecting network traffic.
    private final class CountingRepository: StubRepositoryBase, @unchecked Sendable {
        private(set) var calls: [Int] = []
        var relationsBySeries: [Int: [SeriesRelationship]] = [:]

        override func relationships(for seriesId: Int) async -> [SeriesRelationship]? {
            calls.append(seriesId)
            return relationsBySeries[seriesId] ?? []
        }
    }

    @Test("Stops fetching once 12 continuations are found")
    @MainActor
    func modelStopsEarly() async {
        let repository = CountingRepository()
        // Series 1 alone answers with 12 continuations across two relations —
        // enough to satisfy the row without touching series 2.
        repository.relationsBySeries[1] = (1...12).map {
            relation(type: "sequel", seriesID: 100 + $0)
        }
        repository.relationsBySeries[2] = [relation(type: "sequel", seriesID: 999)]

        let entries = [
            entry(1, finishDate: Date(), series: SeriesFactory.make(id: 1)),
            entry(2, finishDate: Date().addingTimeInterval(-1), series: SeriesFactory.make(id: 2))
        ]

        let model = ContinuationsModel(repository: repository)
        await model.load(entries: entries)

        #expect(model.items.count == 12)
        #expect(repository.calls == [1])
    }

    @Test("A second load with the same finished ids does nothing")
    @MainActor
    func modelIsIdempotent() async {
        let repository = CountingRepository()
        repository.relationsBySeries[1] = [relation(type: "sequel", seriesID: 2)]
        let entries = [entry(1, finishDate: Date(), series: SeriesFactory.make(id: 1))]

        let model = ContinuationsModel(repository: repository)
        await model.load(entries: entries)
        #expect(repository.calls == [1])

        await model.load(entries: entries)
        #expect(repository.calls == [1])
    }
}
