import Testing
import Foundation
@testable import MangaBaka

/// Pins the `by_tags()` port: score = sum(profile[tag] * seriesWeight(tag)) /
/// count(tags)^0.7, min 3 tags, ported from a sibling project.
@Suite("Taste ranker")
struct TasteRankerTests {
    private func tag(_ id: Int, _ name: String, weight: String = "unweighted") -> SeriesTag {
        SeriesTag(
            id: id, name: name, namePath: nil, isGenre: false, isSpoiler: false,
            isExplicit: false, impliedByTagIds: nil, contentRating: nil,
            weight: weight, seriesCount: nil
        )
    }

    private func affinity(_ id: Int, _ name: String, _ score: Double) -> TagAffinity {
        TagAffinity(tagId: id, name: name, score: score, seriesCount: 5)
    }

    @Test("An empty profile scores everything 0 and rank() keeps input order")
    func emptyProfileScoresZero() {
        let ranker = TasteRanker(affinities: [])
        #expect(ranker.isEmpty)

        let series = [
            SeriesFactory.make(id: 1, tagsV2: [tag(1, "A"), tag(2, "B"), tag(3, "C")]),
            SeriesFactory.make(id: 2, tagsV2: [tag(1, "A"), tag(2, "B"), tag(3, "C")])
        ]
        #expect(series.allSatisfy { ranker.score($0) == 0 })

        let ranked = ranker.rank(series) { $0 }
        #expect(ranked.map(\.id) == [1, 2])
    }

    @Test("Fewer than the minimum tags scores 0, even with a loved tag")
    func tooFewTagsScoresZero() {
        let ranker = TasteRanker(affinities: [affinity(1, "Regression", 10)])
        let series = SeriesFactory.make(id: 1, tagsV2: [
            tag(1, "Regression", weight: "core"), tag(2, "Cooking")
        ])
        #expect(series.richTags.count < TasteRanker.minimumTags)
        #expect(ranker.score(series) == 0)
    }

    @Test("Sharing two loved tags outranks sharing one")
    func moreSharedTagsRanksHigher() {
        let ranker = TasteRanker(affinities: [
            affinity(1, "Regression", 10),
            affinity(2, "Tower Climbing", 8)
        ])
        let twoShared = SeriesFactory.make(id: 1, tagsV2: [
            tag(1, "Regression", weight: "core"),
            tag(2, "Tower Climbing", weight: "core"),
            tag(3, "Cooking")
        ])
        let oneShared = SeriesFactory.make(id: 2, tagsV2: [
            tag(1, "Regression", weight: "core"),
            tag(4, "Slice of Life"),
            tag(5, "Cooking")
        ])
        #expect(ranker.score(twoShared) > ranker.score(oneShared))

        let ranked = ranker.rank([oneShared, twoShared]) { $0 }
        #expect(ranked.map(\.id) == [1, 2])
    }

    @Test("The count^0.7 denominator lets a tight 3-tag match beat a sprawling 30-tag one")
    func lengthPenaltyFavorsTightTagging() {
        let ranker = TasteRanker(affinities: [affinity(1, "Regression", 10)])

        let tight = SeriesFactory.make(id: 1, tagsV2: [
            tag(1, "Regression", weight: "core"), tag(2, "A"), tag(3, "B")
        ])
        var sprawlTags = [tag(1, "Regression", weight: "core")]
        sprawlTags.append(contentsOf: (2...30).map { tag($0, "Filler\($0)") })
        let sprawl = SeriesFactory.make(id: 2, tagsV2: sprawlTags)

        #expect(sprawl.richTags.count == 30)
        #expect(ranker.score(tight) > ranker.score(sprawl))
    }

    @Test("reasons() lists matched tag names strongest first, capped at limit")
    func reasonsListsStrongestFirst() {
        let ranker = TasteRanker(affinities: [
            affinity(1, "Regression", 5),
            affinity(2, "Tower Climbing", 20),
            affinity(3, "Cooking", 10)
        ])
        let series = SeriesFactory.make(id: 1, tagsV2: [
            tag(1, "Regression"), tag(2, "Tower Climbing"),
            tag(3, "Cooking"), tag(4, "Unmatched")
        ])

        #expect(ranker.reasons(for: series) == ["Tower Climbing", "Cooking", "Regression"])
        #expect(ranker.reasons(for: series, limit: 2) == ["Tower Climbing", "Cooking"])
    }

    @Test("rank() is stable: equal scores keep their original relative order")
    func rankIsStableForTies() {
        let ranker = TasteRanker(affinities: [affinity(1, "Regression", 10)])
        // Neither series clears the minimum tag count, so both score 0 and
        // must come back in the order they went in.
        let series = [
            SeriesFactory.make(id: 1, tagsV2: [tag(1, "Regression")]),
            SeriesFactory.make(id: 2, tagsV2: [tag(1, "Regression")]),
            SeriesFactory.make(id: 3, tagsV2: [tag(1, "Regression")])
        ]
        let ranked = ranker.rank(series) { $0 }
        #expect(ranked.map(\.id) == [1, 2, 3])
    }
}

/// The ranker is applied where it adds something: a blend or a random draw
/// joining the stack, not the profile recommender's own ordering.
@Suite("The stack is ordered by the reader's tags", .enabled(if: SourceTree.isAvailable))
struct StackRankingWiringTests {
    @Test("Fresh batches are ranked, except the profile recommender's")
    func wiring() throws {
        let stack = try SourceTree.read("MangaBaka/Features/Stack/StackModel.swift")
        #expect(stack.contains("if let ranker, !ranker.isEmpty, source != .yourProfile {"))
        #expect(stack.contains("fresh = ranker.rank(fresh) { $0 }"))
        let root = try SourceTree.read("MangaBaka/App/RootView.swift")
        #expect(root.contains("stackModel?.ranker = await taste.ranker()"))
    }
}
