import Testing
@testable import MangaBaka

/// Which of the series page's six `extras` legs may wait for a slot.
///
/// Counted 2026-09-14 (`docs/reviews/detail-page-budget.md`): a cold open is
/// nine MangaBaka requests, and with every one `.userInitiated` the
/// guaranteed floor under Discover prefetch was 60 / 9 ≈ 6.6 opens a minute
/// before the throttle card. The three below-the-fold legs now go
/// `.background`, which waits instead of throwing. Read from the source
/// because the priority never leaves `APIClient` — nothing a stub can see —
/// and the way this regresses is someone tidying the argument away.
///
/// Fails before the change with `news`, `relationships` and `collections`
/// each missing `priority: .background`.
@Suite("The series page's request priorities", .enabled(if: SourceTree.isAvailable))
struct DetailPagePriorityTests {
    /// The legs moved to `SeriesRepository+Extras.swift` on 2026-09-15 when
    /// `extras` split into a foreground hero phase and a background tail.
    private static let file = "MangaBaka/Core/Persistence/SeriesRepository+Extras.swift"

    private static func call(for endpoint: String, in source: String) -> String? {
        // Only the tail phase of `fetchExtras`: `refetchMissingLegs` lower in
        // the file asks for the same endpoints again.
        guard let start = source.range(of: "await hero(extras)"),
              let stop = source.range(of: "let tail = TailResults(")
        else { return nil }
        let source = String(source[start.lowerBound..<stop.lowerBound])
        guard let range = source.range(of: "/v1/series/\\(seriesId)/\(endpoint)\"") else { return nil }
        // Up to the end of the `attempt { ... }` closure the call sits in —
        // the `news` call spans lines and has a `)` of its own inside.
        let after = source[range.upperBound...]
        guard let end = after.range(of: "\n        }") else { return nil }
        return String(after[..<end.lowerBound])
    }

    @Test("news, relationships and collections wait for a slot rather than being refused")
    func belowTheFoldLegsAreBackground() throws {
        let source = try SourceTree.read(Self.file)
        for endpoint in ["news", "relationships", "collections"] {
            let call = try #require(Self.call(for: endpoint, in: source), Comment(rawValue: endpoint))
            #expect(call.contains("priority: .background"), Comment(rawValue: "\(endpoint): \(call)"))
        }
    }

    /// The legs the reader is looking at keep the foreground window: the
    /// series itself and the volumes shelf a short series shows above the
    /// fold. Links used to be a third; since 2026-09-15 they ride inside the
    /// series record (`Series.linksV2`, `LinksInlineTests`).
    ///
    /// The works leg lives in `SeriesRepository+Works.swift` since it became
    /// two requests (2026-09-15): the first page is what the shelf draws and
    /// stays foreground; the last page — where a long series' forthcoming
    /// volume sits — waits at the gate like the below-the-fold legs.
    @Test("the works shelf's first page stays foreground; its last page waits")
    func visibleLegsStayUserInitiated() throws {
        let source = try SourceTree.read("MangaBaka/Core/Persistence/SeriesRepository+Works.swift")
        let first = "query: Self.worksQuery(page: 1)\n"
        #expect(source.contains(first), "the first-page call, with no priority argument")
        #expect(!source.contains("Self.worksQuery(page: 1), priority: .background"))
        let last = "Self.worksQuery(page: page), priority: .background"
        #expect(source.contains(last))
    }
}
