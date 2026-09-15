import Testing
@testable import MangaBaka

/// `BlendDNA.moves` used to build its lookup with
/// `Dictionary(uniqueKeysWithValues:)`, which traps the instant two strands
/// share a `tag_id` — wire review W8/P8, 2026-09-15. Not observed on the one
/// live capture (`mix.json`, 09-09, 10 unique ids), so this cannot be
/// reproduced by decoding a real payload; it is exercised directly against
/// `BlendDNA.Strand` values instead.
@Suite("BlendDNA.moves after W8")
struct BlendDNAWireFixTests {
    /// Fails on the pre-fix code by crashing the whole test process with
    /// "Fatal error: Dictionary literal contains duplicate keys" — not a
    /// catchable `Issue.record`, since `uniqueKeysWithValues:` traps rather
    /// than throws. Verified by reading `Dictionary(uniqueKeysWithValues:)`'s
    /// own documentation, which states it as a precondition failure; not
    /// re-run against the old code here, since doing so would end the test
    /// run rather than fail one test.
    @Test("Two strands sharing a tag_id do not crash — the first one wins")
    func duplicateTagIDDoesNotTrap() {
        let before = BlendDNA(
            strands: [
                BlendDNA.Strand(tagId: 7, name: "Isekai", weight: 0.20),
                BlendDNA.Strand(tagId: 7, name: "Isekai (dup)", weight: 0.05)
            ],
            seedCount: 2
        )
        let after = BlendDNA(
            strands: [BlendDNA.Strand(tagId: 7, name: "Isekai", weight: 0.30)],
            seedCount: 2
        )
        let moves = BlendDNA.moves(from: before, to: after)
        #expect(moves.count == 1)
        // The first strand for tag 7 (weight 0.20) is what `previous` keeps,
        // so the move is measured against it, not the duplicate's 0.05.
        #expect(moves.first?.from == 0.20)
        #expect(moves.first?.to == 0.30)
    }

    /// The ordinary case, unaffected by the dictionary construction change.
    @Test("Distinct tag ids still report their moves correctly")
    func distinctTagIDsStillWork() {
        let before = BlendDNA(
            strands: [
                BlendDNA.Strand(tagId: 1, name: "Action", weight: 0.10),
                BlendDNA.Strand(tagId: 2, name: "Romance", weight: 0.15)
            ],
            seedCount: 2
        )
        let after = BlendDNA(
            strands: [
                BlendDNA.Strand(tagId: 1, name: "Action", weight: 0.30),
                BlendDNA.Strand(tagId: 2, name: "Romance", weight: 0.15)
            ],
            seedCount: 2
        )
        let moves = BlendDNA.moves(from: before, to: after)
        #expect(moves.count == 1)
        #expect(moves.first?.tagId == 1)
    }
}
