import SwiftUI
import Testing
import UIKit
@testable import MangaBaka

/// Regression tests for the `surface` slice's 2026-09-15 perf-review batch
/// (`docs/reviews/perf/surface.md`, `SUMMARY.md`). Each test documents what
/// failed before the fix in its own doc comment.
///
/// Several findings in the same batch are not covered here because they are
/// not testable by reading a pure function's return value — see the fix
/// report for the reasoning per finding (LoadingLine's `TimelineView` pause,
/// EdgeSwipeToDismiss's per-sample animation, and the widget's disk cache
/// all need a device or Instruments, not a unit test).
@Suite("Surface fix batch — 2026-09-15")
struct SurfaceFixTests {
    // MARK: S17 — NetworkLedger.Entry.failures shown

    /// Fails on the old code: `endpointCaption` had no `failures` parameter
    /// at all, so a refused endpoint read identically to a healthy one.
    @Test("A row with failures says so")
    func endpointCaptionShowsFailures() {
        let caption = DataUseSection.endpointCaption(calls: 12, bytes: "4 KB", droppedRows: 0, failures: 3)
        #expect(caption == "12 calls · 4 KB · 3 failed")
    }

    @Test("No failures, nothing extra said")
    func endpointCaptionOmitsZeroFailures() {
        let caption = DataUseSection.endpointCaption(calls: 12, bytes: "4 KB", droppedRows: 0)
        #expect(caption == "12 calls · 4 KB")
    }

    @Test("Dropped rows and failures both show, in order")
    func endpointCaptionShowsBoth() {
        let caption = DataUseSection.endpointCaption(calls: 12, bytes: "4 KB", droppedRows: 2, failures: 1)
        #expect(caption == "12 calls · 4 KB · 2 rows dropped · 1 failed")
    }

    // MARK: S18/W11 — gate counters, seamed so they light up when they exist

    /// Fails on the old code by not compiling at all: there was no
    /// `throttleCaption` and no row for it in `DataUseSection`. Nil today
    /// because `NetworkLedger` does not count these yet — see
    /// `GateDiagnosticsProviding`.
    @Test("Nothing counted, nothing shown")
    func throttleCaptionNilWhenNothingCounted() {
        let caption = DataUseSection.throttleCaption(
            localRefusals: nil, serverRateLimits: nil, backgroundWaitSeconds: nil
        )
        #expect(caption == nil)
    }

    @Test("Zero counts read the same as nothing counted")
    func throttleCaptionNilWhenAllZero() {
        let caption = DataUseSection.throttleCaption(
            localRefusals: 0, serverRateLimits: 0, backgroundWaitSeconds: 0
        )
        #expect(caption == nil)
    }

    @Test("A real count is shown, with the others omitted")
    func throttleCaptionShowsWhatHappened() {
        let caption = DataUseSection.throttleCaption(
            localRefusals: 2, serverRateLimits: nil, backgroundWaitSeconds: 12.4
        )
        #expect(caption == "2 refused locally · 12s waited in the background")
    }

    /// The seam: `NetworkLedger` conforms to `GateDiagnosticsProviding`. The
    /// counters landed in the same batch (wire W-fixes, 2026-09-15), so a
    /// fresh ledger reads zero on every field — never `nil`, which is what
    /// the caption reads as "not counted".
    @Test("A fresh NetworkLedger answers zero for every gate counter")
    func networkLedgerGateCountersStartAtZero() async {
        let ledger = NetworkLedger()
        let refusals = await ledger.localRefusals
        let serverLimits = await ledger.serverRateLimits
        let waitSeconds = await ledger.backgroundWaitSeconds
        #expect(refusals == 0)
        #expect(serverLimits == 0)
        #expect(waitSeconds == 0)
    }

    // MARK: S16 — textPrimary/textEmphasis are the semantic label colour

    /// Fails on the old code: `Palette.textPrimary` was `Color.white.opacity(0.96)`,
    /// which resolves to white at 96% alpha — not equal to `.label`'s dark
    /// resolution (white at 100%, opaque).
    @Test("textPrimary matches .label's dark resolution, not a near-white opacity")
    func textPrimaryIsSemanticLabel() {
        let dark = UITraitCollection(userInterfaceStyle: .dark)
        let primary = UIColor(Palette.textPrimary).resolvedColor(with: dark)
        let label = UIColor.label.resolvedColor(with: dark)
        #expect(primary == label)
    }

    /// Same defect, the hero-title token.
    @Test("textEmphasis matches .label's dark resolution, not a near-white opacity")
    func textEmphasisIsSemanticLabel() {
        let dark = UITraitCollection(userInterfaceStyle: .dark)
        let emphasis = UIColor(Palette.textEmphasis).resolvedColor(with: dark)
        let label = UIColor.label.resolvedColor(with: dark)
        #expect(emphasis == label)
    }

    // MARK: S5 — CoverImage.onLoaded, deleted rather than wired

    /// Not a behaviour test — there is no behaviour left to observe, which is
    /// the point. This documents the decision: `onLoaded` was declared,
    /// documented, and never passed at any of the app's call sites (whole-repo
    /// grep, tests included), so it was deleted rather than wired. Wiring it
    /// would mean changing `.arrives()` call sites in `DiscoverView`,
    /// `RecentlyViewedRow`, `MixView` and others — none of which are this
    /// agent's files — so deletion is what stays inside this batch's scope.
    /// `CoverImage`'s two existing fade tests (`CoverImageTests.swift`) still
    /// pass unchanged, which is the closest thing to a regression check here.
    @Test("CoverImage still compiles and fades correctly without onLoaded")
    func coverImageFadeDecisionUnaffectedByOnLoadedRemoval() {
        #expect(CoverImage.arrival(wasCached: true, loadDuration: 10) == .instant)
        #expect(CoverImage.arrival(wasCached: false, loadDuration: 10) == .fading)
    }

    // S15 (widget cover cache survives across extension launches) has no
    // test here: `CoverLoader` lives in the `MangaBakaWidgets` target, which
    // `MangaBakaTests` does not link (`project.yml` only pulls in
    // `WidgetSnapshotData.swift` from that folder), so its session
    // configuration is not reachable from this test target at all — untestable
    // by reading, not skipped for convenience. Verified by reading the source
    // instead: `MangaBakaWidgets/CoverLoader.swift`'s `session` now sets
    // `requestCachePolicy = .useProtocolCachePolicy` and a `URLCache` backed
    // by a directory under the App Group container, in place of `.ephemeral`'s
    // in-memory-only default, so the cache survives the extension process
    // dying between hourly reloads.
}
