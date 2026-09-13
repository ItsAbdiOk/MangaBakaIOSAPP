import Foundation
import Testing
@testable import MangaBaka

@Suite("A page keeps the rows it can read")
struct LossyArrayTests {
    private struct Row: Decodable, Equatable, Sendable {
        let id: Int
    }

    /// Fails before `LossyArray` existed: `[Row]` throws on the second
    /// element and the whole page is lost.
    @Test("One bad row costs one row, not the page")
    func oneBadRow() throws {
        let data = Data(#"[{"id":1},{"id":"two"},{"id":3}]"#.utf8)
        let page = try JSONDecoder().decode(LossyArray<Row>.self, from: data)
        #expect(page.elements == [Row(id: 1), Row(id: 3)])
        #expect(page.dropped == 1)
    }

    /// Control: a clean page decodes exactly as `[Row]` would.
    @Test("A clean page loses nothing")
    func cleanPage() throws {
        let data = Data(#"[{"id":1},{"id":2}]"#.utf8)
        let page = try JSONDecoder().decode(LossyArray<Row>.self, from: data)
        #expect(page.elements == [Row(id: 1), Row(id: 2)])
        #expect(page.dropped == 0)
    }
}
