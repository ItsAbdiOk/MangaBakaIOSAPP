import SwiftUI
import UIKit

/// Animation that respects "Reduce Motion".
///
/// Fifteen surfaces in the app animated and exactly one of them — the swipe
/// stack's card throw — asked whether the reader wanted motion. The rest
/// glided, expanded, slid and bounced regardless: the cover gallery, the tag
/// groups, the toast, the library's shape bar, the settings disclosures.
///
/// For a reader who turns Reduce Motion on, that setting is usually not a
/// preference about taste. It is vestibular: motion on a screen can cause
/// genuine nausea and dizziness. An app that honours it in one place out of
/// fifteen has not honoured it.
///
/// Reads `UIAccessibility` rather than the SwiftUI environment on purpose.
/// The environment value is only reachable inside a `View`, and half these
/// call sites are in models and closures; threading it through them all would
/// mean fifteen chances to forget. This is the same flag the environment
/// value is derived from.
///
/// Four modifiers — `NumericTransition` and `ArrivalTransition` below,
/// `AppearsSoftlyModifier` and the `SettingsRow` toggle — do read
/// `@Environment(\.accessibilityReduceMotion)` instead, because inside a
/// `ViewModifier` the environment is free and updates the view when the
/// setting changes mid-session, which this static does not. That is two
/// mechanisms for one value and the 2026-09-14 review was right to call it
/// out; consolidating on the environment means finding a home for the ~10
/// non-`View` call sites first, so it is recorded here rather than done.
@MainActor
enum Motion {
    /// `nonisolated` so the pure helpers below (`reduced`, `arrival`) and
    /// `DetailBackdrop.parallaxOffset` can default to it without themselves
    /// becoming `@MainActor` — a default-argument expression has to match its
    /// function's isolation, so marking this `@MainActor` would cascade
    /// through all of them and through `MotionModifiers`'
    /// `glideTransitionConfig`. It is still only ever read on the main actor;
    /// see below.
    nonisolated static var isReduced: Bool {
        // The compiler marks the UIKit flag main-actor (`NS_SWIFT_UI_ACTOR`
        // on `UIAccessibilityIsReduceMotionEnabled`, checked against the
        // iOS 26.5 SDK header on 2026-09-14), so reading it needs the hop
        // even though UIKit documents the value itself as thread-safe.
        //
        // There used to be a `DispatchQueue.main.sync` fallback here for the
        // off-main case, justified by "a Swift Testing test evaluating a
        // default argument". That path is dead, checked both ways on
        // 2026-09-14: every production read is from a view body, a
        // `ViewModifier`, a `@State` initialiser or a `scrollTransition`
        // closure, all of which SwiftUI runs on the main actor; and the only
        // test that reaches the default rather than passing `isReduced:`
        // explicitly is `MotionTests.swift`'s `MotionSystemFlagTests`, whose
        // suite is `@MainActor`. A blocking hop from a cooperative-pool
        // thread is worth losing on its own account — it is the classic way
        // to deadlock the thread pool — and keeping it meant this value had
        // two behaviours, one of which nothing exercised.
        //
        // `assumeIsolated` traps rather than deadlocks if a future caller
        // does read this off the main actor, which is the failure mode you
        // want: loud, at the call site, in the first run.
        MainActor.assumeIsolated { UIAccessibility.isReduceMotionEnabled }
    }

    /// The four springs everything in this app animates with. Response and
    /// damping are guesses tuned by feel, not measurement — see each preset.
    ///
    /// Taps and toggles: quick, slightly underdamped so it reads as answering
    /// a finger rather than settling into place. A guess.
    nonisolated static let snappy: Animation = .spring(response: 0.28, dampingFraction: 0.86)
    /// Content arriving, sheets presenting: a touch slower and better damped
    /// than `snappy` so a whole surface doesn't feel jumpy. A guess.
    nonisolated static let settle: Animation = .spring(response: 0.45, dampingFraction: 0.82)
    /// One-off rewards only — save, complete — never a loop and never a
    /// second bounce. Underdamped on purpose so it reads as a reward, not a
    /// UI transition. A guess.
    nonisolated static let celebrate: Animation = .spring(response: 0.55, dampingFraction: 0.6)
    /// Scroll-linked motion: fully damped so nothing overshoots while the
    /// reader's finger is still moving the content. A guess.
    nonisolated static let glide: Animation = .spring(response: 0.7, dampingFraction: 1.0)

    /// How long into a list's arrival the item at `index` should wait before
    /// animating in, so a list assembles rather than queues. Capped at
    /// `cap` steps so a long list doesn't make its last rows wait seconds —
    /// `cap` and `step` are both guesses. Negative indices (should not occur,
    /// but nothing here should force-unwrap or crash on bad input) wait 0.
    nonisolated static func stagger(_ index: Int, step: TimeInterval = 0.045, cap: Int = 6) -> TimeInterval {
        TimeInterval(min(max(index, 0), cap)) * step
    }

    /// `settle`, delayed by this item's place in the stagger — or nil under
    /// Reduce Motion, where nothing should wait to appear either.
    nonisolated static func arrival(index: Int, isReduced: Bool = Motion.isReduced) -> Animation? {
        guard !isReduced else { return nil }
        return settle.delay(stagger(index))
    }

    /// The animation, or none at all when the reader has asked for less.
    ///
    /// Returning nil rather than a shorter duration is deliberate: Reduce
    /// Motion asks for no movement, not for quick movement. The state change
    /// still happens — it simply happens at once.
    /// - Parameter isReduced: defaulted to the system setting, and injectable
    ///   so the decision can be tested without a device whose accessibility
    ///   settings have been changed underneath it.
    nonisolated static func reduced(
        _ animation: Animation?, isReduced: Bool = Motion.isReduced
    ) -> Animation? {
        isReduced ? nil : animation
    }

    /// `withAnimation`, honouring the setting.
    @discardableResult
    static func run<Result>(
        _ animation: Animation?,
        _ body: () throws -> Result
    ) rethrows -> Result {
        try withAnimation(reduced(animation), body)
    }
}

extension View {
    /// A figure that changes morphs digit by digit rather than cutting.
    ///
    /// A number that morphs reads as *the same number changing*; one that
    /// cuts reads as *a different screen*. Applied to every figure that can
    /// change while it is on screen: counts on chips, "N shown", the pulse,
    /// the stack's saved counter. Under Reduce Motion the digits cut, which
    /// is the setting's own request.
    func countsNotCuts() -> some View {
        modifier(NumericTransition())
    }
}

private struct NumericTransition: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if reduceMotion {
            content
        } else {
            content.contentTransition(.numericText())
        }
    }
}

extension View {
    /// A card in a horizontal row arrives rather than appears: entering from
    /// the edge it comes up from a little smaller and a little faded, and
    /// leaves the same way. The gallery already did this; the cover rows on
    /// Discover, the library and the series page did not, and the difference
    /// is most of what makes a shelf feel like the App Store's rather than a
    /// list. Identity under Reduce Motion.
    func arrives() -> some View {
        modifier(ArrivalTransition())
    }
}

private struct ArrivalTransition: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.scrollTransition(.interactive, axis: .horizontal) { [reduceMotion] view, phase in
            let distance = reduceMotion ? 0 : abs(phase.value)
            return view
                .scaleEffect(1 - distance * 0.06)
                .opacity(1 - distance * 0.4)
        }
    }
}
