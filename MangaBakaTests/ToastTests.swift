import Foundation
import Testing
@testable import MangaBaka

/// A toast confirms a save; it must not stop the next one. Seen on the
/// simulator 2026-09-13: with a toast up, taps around it were swallowed
/// until it faded. The rule for what the overlay captures now lives in one
/// static function, and this suite pins it. What it cannot check — that
/// SwiftUI actually applies that shape to the gestured subtree and not to the
/// padded one — is the part the simulator has to answer.
@Suite("Toast hit testing")
struct ToastTests {
    /// The capsule the overlay draws, in the coordinate space of the overlay.
    /// 300 × 40 is the card's max width by a one-line height; the numbers are
    /// only a stand-in for a layout the test does not run.
    private let card = CGRect(x: 46, y: 700, width: 300, height: 40)

    /// Expected to fail before the fix with: no such symbol —
    /// `ToastOverlay` was private and had no hit-testing rule, so the rule
    /// was whatever the modifier order produced, and the modifier order put
    /// the gesture after a 104pt bottom padding.
    @Test("A tap on the card is the toast's")
    func tapOnCardIsCaptured() {
        #expect(ToastOverlay.capturesTap(at: CGPoint(x: 196, y: 720), card: card))
    }

    /// The 104pt under the capsule — where the tab bar is — is the region the
    /// old modifier order put inside the gestured subtree.
    @Test("A tap in the padding under the card passes through")
    func tapUnderCardPassesThrough() {
        #expect(!ToastOverlay.capturesTap(at: CGPoint(x: 196, y: 780), card: card))
    }

    @Test("A tap beside the card passes through")
    func tapBesideCardPassesThrough() {
        #expect(!ToastOverlay.capturesTap(at: CGPoint(x: 20, y: 720), card: card))
        #expect(!ToastOverlay.capturesTap(at: CGPoint(x: 196, y: 300), card: card))
    }

    /// A capsule, not the rect: the corner of the card's bounding box is
    /// outside the rounded end, and a tap there belongs to whatever is under
    /// it.
    @Test("The card's hit region is the capsule, not its bounding rectangle")
    func cornerOfBoundingBoxPassesThrough() {
        #expect(!ToastOverlay.capturesTap(at: CGPoint(x: 47, y: 701), card: card))
    }
}
