import Foundation

/// What a blend actually is: ten weighted tags the API derives from the seeds.
///
/// This is the field that turns the recommender from "trust me" into something
/// a reader can see and push around. It sat unused because `/v1/series/mix`
/// never successfully decoded until the cover-shape fix.
struct BlendDNA: Equatable, Sendable {
    struct Strand: Identifiable, Equatable, Sendable, Decodable {
        let tagId: Int
        let name: String
        /// Roughly 0-1, and the ten sum to about 1. The spread is shallow in
        /// practice — a real blend ran 0.161 down to 0.065 — so anything that
        /// relies on dramatic differences in magnitude will look flat.
        let weight: Double

        var id: Int { tagId }
    }

    let strands: [Strand]
    let seedCount: Int

    static let empty = BlendDNA(strands: [], seedCount: 0)
    var isEmpty: Bool { strands.isEmpty }

    /// The heaviest strand, used to scale the rest for display.
    var heaviestWeight: Double { strands.map(\.weight).max() ?? 1 }

    /// How a strand's weight moved between two blends, for the change summary.
    /// Only strands present in both, and only where the weight actually moved.
    static func moves(from before: BlendDNA, to after: BlendDNA) -> [Move] {
        let previous = Dictionary(uniqueKeysWithValues: before.strands.map { ($0.tagId, $0.weight) })
        return after.strands.compactMap { strand in
            guard let was = previous[strand.tagId],
                  abs(was - strand.weight) >= 0.005
            else { return nil }
            return Move(tagId: strand.tagId, name: strand.name, from: was, to: strand.weight)
        }
        // Biggest movers first: the point is what changed most.
        .sorted { abs($0.to - $0.from) > abs($1.to - $1.from) }
    }

    struct Move: Identifiable, Equatable, Sendable {
        let tagId: Int
        let name: String
        let from: Double
        let to: Double

        var id: Int { tagId }
        var rose: Bool { to > from }
    }
}

/// A blend: what came back, and what it was made of.
struct MixResult: Equatable, Sendable {
    var recommendations: [Recommendation] = []
    var dna: BlendDNA = .empty

    static let empty = MixResult()
}
