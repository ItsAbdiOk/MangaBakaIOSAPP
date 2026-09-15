import Foundation
import Testing
@testable import MangaBaka

/// The session shell's own wiring: `RootView+Session.swift`, `RootView.swift`
/// and `AppServices.swift`.
///
/// `RootView` is a SwiftUI view struct wired to eighteen collaborators and
/// several `@State` properties; constructing one in a test means building
/// the whole app graph for no benefit over reading the four lines that
/// matter, so these check the source directly — the same approach
/// `SpotlightWiringTests` already takes for the same file.
@Suite("Session wiring", .enabled(if: SourceTree.isAvailable))
struct SessionWiringTests {
    private func session() throws -> String {
        try SourceTree.read("MangaBaka/App/RootView+Session.swift")
    }

    /// Gap 88 / decision 5: a library write used to call `reload()`
    /// unconditionally — thirteen requests, 24.7 MB on a real account, to
    /// reflect one changed row. `apply(_:to:)` patches the entry that is
    /// already loaded for the cost of the write alone; `reload()` is now
    /// only the fallback for an entry that was not loaded to begin with.
    /// Expected to fail before the fix with: no `if wasLoaded` branch — the
    /// function called `await session.library.reload()` on every path.
    @Test("Saving a library change patches locally instead of always re-walking")
    func saveLibraryChangePatchesLocally() throws {
        let source = try session()
        let function = try #require(source.range(of: "func saveLibraryChange"))
        let body = String(source[function.lowerBound...])
        #expect(body.contains("await session.library.apply(change, to: seriesId)"))
        #expect(body.contains("if wasLoaded {"))
        #expect(body.contains("toasts.show(\"Saved\")"))
    }

    /// Gap 89: the previous account's shelves used to stay on screen — in
    /// `session.library.entries` — until relaunch, because nothing here told
    /// the Library tab's own model to drop them, and the taste ranker built
    /// from the old library kept weighting the stack.
    /// Expected to fail before the fix with: neither line present —
    /// `forgetPreviousAccount` cleared seven other stores and never touched
    /// `session.library` or `stackModel?.ranker`.
    @Test("Sign-out forgets the library and the taste ranker, not just the profile id")
    func forgetPreviousAccountForgetsLibrary() throws {
        let source = try session()
        #expect(source.contains("await session.library.forget()"))
        // Item 61: non-optional now, built in `RootView.init`.
        #expect(source.contains("stackModel.ranker = nil"))
    }

    /// Gap 3: told once, from the one place a launch actually runs its
    /// startup work.
    @Test("A database reset is announced from startSession")
    func databaseResetAnnounced() throws {
        let source = try session()
        let function = try #require(source.range(of: "func startSession"))
        let body = String(source[function.lowerBound...])
        #expect(body.contains("if databaseWasReset {"))
    }

    /// Gap 61/76: a series that cannot be opened used to fail in silence,
    /// and a cancelled intent task (a second "Open X" arriving before the
    /// first finished) kept running to completion and could still land its
    /// own navigation after a newer request had already set the right page.
    /// Expected to fail before the fix with: neither string present —
    /// `openSeries` and `openFromSpotlight` both ended their miss branch
    /// with a bare `return`.
    @Test("Opening a series that cannot be found toasts, and a cancelled open stops early")
    func openSeriesHandlesMisses() throws {
        let source = try session()
        let openSeries = try #require(source.range(of: "func openSeries"))
        let openFromSpotlight = try #require(source.range(of: "func openFromSpotlight"))
        let refreshReminders = try #require(source.range(of: "func refreshReminders"))
        let openSeriesBody = String(source[openSeries.lowerBound..<openFromSpotlight.lowerBound])
        let openFromSpotlightBody = String(source[openFromSpotlight.lowerBound..<refreshReminders.lowerBound])
        #expect(openSeriesBody.contains("toasts.show(\"That series isn't available right now\""))
        #expect(openSeriesBody.contains("guard !Task.isCancelled else { return }"))
        #expect(openFromSpotlightBody.contains("toasts.show(\"That series isn't available right now\""))
    }

    /// Gap 104: a failed walk must leave yesterday's index standing rather
    /// than wiping it and reindexing nothing.
    /// Expected to fail before the fix with: `await
    /// spotlight.reindex(await librarySnapshot.all())` unconditionally —
    /// `.all()` discards whether the walk that produced it failed.
    @Test("A failed library walk does not reindex Spotlight")
    func skipsReindexOnFailedWalk() throws {
        let source = try session()
        #expect(source.contains("let walk = await librarySnapshot.load()"))
        // Item 12 added a `needsAccount` branch inside the guard, so it is no
        // longer a one-liner; what matters is that the guard is still there.
        #expect(source.contains("guard walk.failure == nil else {"))
        #expect(source.contains("await spotlight.reindex(walk.entries)"))
    }
}

/// Gap 77: `RootView.swift`'s "Use as seed" toasted success when `mixModel`
/// was nil — built lazily in the tab's own `.task` and reachable before that
/// runs.
@Suite("Root view wiring", .enabled(if: SourceTree.isAvailable))
struct RootViewWiringTests {
    /// Expected to fail before the fix with: `mixModel?.addSeed(series)`
    /// followed unconditionally by `toasts.show("Added to the mix")`, with
    /// no branch for a nil model.
    @Test("Use as seed adds unconditionally: there is no nil mix model to guard")
    func useAsSeedGuardsNilModel() throws {
        let source = try SourceTree.read("MangaBaka/App/RootView+Failures.swift")
        let function = try #require(source.range(of: "func useAsSeedTapped"))
        let body = String(source[function.lowerBound...])
        // Item 61 closed the window this guard existed for: `mixModel` is
        // built in `RootView.init`, so there is no nil case to confirm
        // success over. The addition is unconditional because it now always
        // happens.
        #expect(body.contains("mixModel.addSeed(series)"))
        #expect(!body.contains("mixModel?.addSeed(series)"))
        let root = try SourceTree.read("MangaBaka/App/RootView+Session.swift")
        #expect(root.contains("onUseAsSeed: useAsSeedTapped,"))
    }

    /// Gap 64: the account-onboarding push used to run synchronously inside
    /// the same closure that also dismisses the cover. Deferred to an
    /// `onChange` on the value the cover is keyed from, so it only runs
    /// after SwiftUI has actually observed the cover's state change.
    @Test("The post-onboarding account push is deferred to onChange")
    func accountPushIsDeferred() throws {
        let source = try SourceTree.read("MangaBaka/App/RootView.swift")
        #expect(source.contains(".onChange(of: onboarding.hasCompleted) { _, completed in"))
        #expect(source.contains("wantsAccountAfterOnboarding = true"))
    }

    /// Item 106: nothing per-entry and nothing allocating belongs in a body
    /// pass that runs on every toast, tab selection and path change.
    ///
    /// Read off the source for the reason the suite's doc comment gives:
    /// mounting `RootView` means building the whole app graph, and there is
    /// no SwiftUI hook that reports "body ran and allocated two sets". The
    /// cost itself is unmeasured — no Instruments trace was taken, and the
    /// review filed it as microseconds — so this pins the shape rather than
    /// claiming a number.
    ///
    /// Expected to fail before the fix with two failures: `body` held
    /// `.environment(\.tagAudience, TagAudience(` — the inline construction,
    /// two `Set` allocations per pass — and carried neither `onChange`.
    @Test("The tag audience is held, not rebuilt on every body pass")
    func tagAudienceIsNotRebuiltInBody() throws {
        let source = try SourceTree.read("MangaBaka/App/RootView.swift")
        #expect(
            !source.contains(".environment(\\.tagAudience, TagAudience("),
            "body must read the held value, not construct a new one"
        )
        #expect(source.contains(".environment(\\.tagAudience, tagAudience)"))
        #expect(source.contains(".onChange(of: content.preferences)"))
        #expect(source.contains(".onChange(of: blockedTags.blocked)"))
    }

    /// The other half of item 106, landed by lanes C and G: the Discover tab
    /// reads a `chaptersRead` `LibraryModel` recomputes when `entries`
    /// changes, rather than reducing ~939 entries in the tab tree's body.
    ///
    /// Expected to fail before that fix with:
    /// `chaptersRead: ReadingInsights.chaptersRead(in: session.library.entries)`
    /// in `RootView+Tabs.swift`.
    @Test("Discover reads the cached chapter count rather than reducing the library")
    func discoverReadsCachedChapterCount() throws {
        let source = try SourceTree.read("MangaBaka/App/RootView+Tabs.swift")
        #expect(source.contains("chaptersRead: session.library.chaptersRead"))
        #expect(!source.contains("ReadingInsights.chaptersRead(in:"))
    }
}
