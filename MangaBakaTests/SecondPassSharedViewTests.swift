import Foundation
import Testing
@testable import MangaBaka

/// Two view-only fixes from the second-pass review (2026-09-14) that no unit
/// test can drive: this project has no ViewInspector, so a `Countdown`
/// cannot be mounted and a `CoverImage`'s `.task` cannot be cancelled from
/// here. What *can* be held is the mechanism each fix depends on, pinned to
/// the source so a refactor that drops it fails loudly rather than
/// silently. These are pins, not behaviour tests, and say so.
@Suite("Shared view mechanisms, second pass", .enabled(if: SourceTree.isAvailable))
struct SecondPassSharedViewTests {
    /// Item 18. `onChange` does not fire for a view's initial value, so a
    /// countdown mounted after its deadline — a 429 whose window lapsed
    /// while the app was backgrounded — read "Retrying now…" forever and
    /// never called `onReachZero`. `initial: true` is the whole fix.
    ///
    /// Expected to fail before the fix with: `initial: true` absent.
    @Test("A countdown mounted past its deadline observes that on mount")
    func countdownObservesInitialValue() throws {
        let source = try SourceTree.read("MangaBaka/Features/Shared/Countdown.swift")
        #expect(SourceTree.containsRun(source, ".onChange(of: hasReached(remaining), initial: true)"))
        // And still exactly once: the guard that stops a second fire on the
        // next tick is unchanged.
        #expect(SourceTree.containsRun(source, "guard reached, !hasFired else { return }"))
    }

    /// Item 47. `CoverStore.image(for:)` is deliberately uncancellable, so
    /// it answers normally after the row's `.task` was cancelled by
    /// `onDisappear` — and the assignment after the await handed the
    /// released bitmap straight back. Both writes after the await now check
    /// the task first; the deferred `isReady` write is a `yield` inside the
    /// same task rather than a detached one that could not see the flag.
    ///
    /// Expected to fail before the fix with: no `Task.isCancelled` check
    /// between the `await CoverStore.shared.image(for: url)` and
    /// `loaded = image`.
    @Test("A cover that arrives after its row left is not held by the row")
    func releasedRowDoesNotReholdTheBitmap() throws {
        let source = try SourceTree.read("MangaBaka/Features/Shared/CoverImage.swift")
        let fetch = "guard let image = await CoverStore.shared.image(for: url) else { return }"
        let fetchRange = try #require(source.range(of: fetch))
        let assignRange = try #require(source.range(of: "loaded = image"))
        let between = source[fetchRange.upperBound..<assignRange.lowerBound]
        #expect(between.contains("guard !Task.isCancelled else { return }"))
        let deferred = "await Task.yield() guard !Task.isCancelled else { return } isReady = true"
        #expect(SourceTree.containsRun(source, deferred))
        #expect(!source.contains("Task { @MainActor in\n            isReady = true"),
                "the detached write could never see the cancellation it needed to honour")
    }
}
