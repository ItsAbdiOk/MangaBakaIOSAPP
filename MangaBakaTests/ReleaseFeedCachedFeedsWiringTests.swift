import Foundation
import Testing
@testable import MangaBaka

/// `refreshReminders` used to pass `feeds: [:]` to `ReleaseReminders.reschedule`
/// unconditionally — see the comment this batch removed — because nothing at
/// that call site had a cache of series -> `ReleaseFeed` to fill it with. The
/// confirmed-episode, season-ended and Naver-finished notification conditions
/// could never fire from this wiring as a result, only the announced-work and
/// library-status ones.
///
/// This reads source rather than running `RootView`, which needs a whole
/// app's worth of live dependencies to construct: the failure here is a
/// missing call, not a wrong value, and the per-client and
/// `ReleaseFeedServiceTests.cachedFeeds` suites already prove the read-only
/// half (`cachedFeed`/`cachedFeeds`) never makes a request.
@Suite("refreshReminders passes real feeds", .enabled(if: SourceTree.isAvailable))
struct ReleaseFeedCachedFeedsWiringTests {
    /// Expected failure before this fix: `refreshReminders` called
    /// `reminders.reschedule(announced:library:libraryFailure:)` with no
    /// `feeds:` argument at all (it defaults to `[:]`), so neither
    /// `"feeds:"` nor `"cachedFeeds("` appeared in the function body.
    @Test("refreshReminders builds feeds from cachedFeeds, not an empty dictionary")
    func refreshRemindersFillsFeeds() throws {
        let source = try SourceTree.read("MangaBaka/App/RootView+Session.swift")
        guard let range = source.range(of: "func refreshReminders() async {") else {
            Issue.record("refreshReminders not found")
            return
        }
        let body = source[range.lowerBound...]
        #expect(body.contains("cachedFeeds("))
        #expect(body.contains("feeds: feeds"))
        // The old "deliberately empty" comment explaining why feeds was [:]
        // must not still be sitting over a call that now fills it in.
        #expect(!body.contains("`feeds` is deliberately empty"))
    }

    /// The links a series' cached feeds are matched against must themselves
    /// come from the cache, never a fetch — `cachedExtras`, not `extras`.
    @Test("Links come from cachedExtras, never the six-leg extras(for:) fetch")
    func linksComeFromCachedExtras() throws {
        let source = try SourceTree.read("MangaBaka/App/RootView+Session.swift")
        guard let range = source.range(of: "func refreshReminders() async {") else {
            Issue.record("refreshReminders not found")
            return
        }
        let body = source[range.lowerBound...]
        #expect(body.contains("cachedExtras("))
        #expect(!body.contains(".extras(for:"))
    }
}
