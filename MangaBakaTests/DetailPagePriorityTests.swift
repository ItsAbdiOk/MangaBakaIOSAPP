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
    private static let file = "MangaBaka/Core/Persistence/SeriesRepository.swift"

    private static func call(for endpoint: String, in source: String) -> String? {
        // Only the five-way `extras` fetch: `relationships` is also fetched on
        // its own elsewhere in the file, for a different screen.
        guard let start = source.range(of: "// Concurrent rather than sequential: five independent reads"),
              let stop = source.range(of: "let results = await (news, related, full, editions, works)")
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
    @Test("the series and its works stay foreground")
    func visibleLegsStayUserInitiated() throws {
        let source = try SourceTree.read(Self.file)
        for endpoint in ["works"] {
            let call = try #require(Self.call(for: endpoint, in: source), Comment(rawValue: endpoint))
            #expect(!call.contains(".background"), Comment(rawValue: "\(endpoint): \(call)"))
        }
    }
}
