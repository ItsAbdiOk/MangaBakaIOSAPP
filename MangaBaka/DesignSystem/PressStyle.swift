import SwiftUI

/// A button that answers the finger.
///
/// `.plain` — which every button in this app used — draws nothing on press,
/// so a card, a chip or a row felt dead under a thumb: nothing moved until
/// the screen changed. This is `.plain` plus a small scale while pressed,
/// on the project's one spring, and back on release. 0.97 is enough to be
/// felt and not enough to be noticed as an effect. A guess, as such numbers
/// are; anything larger read as a toy on the first try.
///
/// Under Reduce Motion the scale goes and a dip in opacity stands in for it:
/// still an answer, not a movement.
struct PressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(reduceMotion ? 1 : (configuration.isPressed ? 0.97 : 1))
            .opacity(reduceMotion && configuration.isPressed ? 0.8 : 1)
            .animation(
                Motion.reduced(.spring(response: 0.36, dampingFraction: 0.78)),
                value: configuration.isPressed
            )
    }
}

extension ButtonStyle where Self == PressStyle {
    /// The app's default for anything the reader taps: cards, chips, rows.
    static var press: PressStyle { PressStyle() }
}
