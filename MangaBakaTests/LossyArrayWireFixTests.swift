import Testing
import Foundation
@testable import MangaBaka

/// `LossyArray` counted what it dropped but discarded the `DecodingError`
/// that explained it, so a shape change reached Abdi as "3 rows dropped"
/// with no key name to grep for — wire review W10/P10, 2026-09-15.
@Suite("LossyArray and NetworkLedger after W10")
struct LossyArrayWireFixTests {
    /// Fails on the pre-fix code with "value of type 'LossyArray<Int>' has
    /// no member 'firstDropReason'" — the field did not exist.
    @Test("A dropped element's DecodingError description survives on the box")
    func firstDropReasonIsKept() throws {
        let json = Data("[1, \"not a number\", 3]".utf8)
        let box = try JSONDecoder().decode(LossyArray<Int>.self, from: json)
        #expect(box.elements == [1, 3])
        #expect(box.dropped == 1)
        let reason = try #require(box.firstDropReason)
        // Not asserting the exact `DecodingError` wording (Foundation's is
        // not a stable contract) — only that a real description made it
        // through rather than being discarded, and that a caller could grep
        // it for something.
        #expect(!reason.isEmpty)
    }

    /// Only the *first* reason is kept — a page of many bad rows from the
    /// same shape change would otherwise write near-identical strings.
    @Test("Only the first drop's reason is kept, not every one")
    func onlyFirstReasonIsKept() throws {
        let json = Data("[\"bad one\", \"bad two\", 3]".utf8)
        let box = try JSONDecoder().decode(LossyArray<Int>.self, from: json)
        #expect(box.dropped == 2)
        #expect(box.firstDropReason != nil)
    }

    /// Nothing dropped, nothing to explain.
    @Test("A clean array carries no drop reason")
    func cleanArrayHasNoReason() throws {
        let json = Data("[1, 2, 3]".utf8)
        let box = try JSONDecoder().decode(LossyArray<Int>.self, from: json)
        #expect(box.dropped == 0)
        #expect(box.firstDropReason == nil)
    }

    /// Fails on the pre-fix code with "extra argument 'reason' in call" —
    /// `NetworkLedger.recordDropped` took no reason.
    @Test("NetworkLedger keeps the most recent drop reason per path")
    func networkLedgerKeepsDropReason() async {
        let ledger = NetworkLedger()
        await ledger.recordDropped(path: "/v1/series/3397/works", count: 2, reason: "keyNotFound(works)")
        let entry = await ledger.byPath["/v1/series/{id}/works"]
        #expect(entry?.droppedRows == 2)
        #expect(entry?.lastDropReason == "keyNotFound(works)")
    }

    /// A later drop on the same path updates the reason rather than losing
    /// it — "most recent shape change" per the field's own doc comment.
    @Test("A later drop on the same path replaces the stored reason")
    func laterDropReplacesReason() async {
        let ledger = NetworkLedger()
        await ledger.recordDropped(path: "/v1/tags", count: 1, reason: "first shape change")
        await ledger.recordDropped(path: "/v1/tags", count: 1, reason: "second shape change")
        let entry = await ledger.byPath["/v1/tags"]
        #expect(entry?.droppedRows == 2)
        #expect(entry?.lastDropReason == "second shape change")
    }

    /// A caller with no reason (nothing to report, or the old call shape)
    /// still records the count without erasing any reason already stored —
    /// the default parameter keeps every pre-existing call site compiling.
    @Test("Recording a drop with no reason keeps the count and any prior reason")
    func noReasonKeepsPriorReason() async {
        let ledger = NetworkLedger()
        await ledger.recordDropped(path: "/v1/tags", count: 1, reason: "a real reason")
        await ledger.recordDropped(path: "/v1/tags", count: 1)
        let entry = await ledger.byPath["/v1/tags"]
        #expect(entry?.droppedRows == 2)
        #expect(entry?.lastDropReason == "a real reason")
    }
}
