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
@MainActor
enum Motion {
    static var isReduced: Bool { UIAccessibility.isReduceMotionEnabled }

    /// The animation, or none at all when the reader has asked for less.
    ///
    /// Returning nil rather than a shorter duration is deliberate: Reduce
    /// Motion asks for no movement, not for quick movement. The state change
    /// still happens — it simply happens at once.
    /// - Parameter isReduced: defaulted to the system setting, and injectable
    ///   so the decision can be tested without a device whose accessibility
    ///   settings have been changed underneath it.
    static func reduced(_ animation: Animation?, isReduced: Bool = Motion.isReduced) -> Animation? {
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
