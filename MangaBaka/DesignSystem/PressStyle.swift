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
    /// Bumped on every press-down (not release) so `.haptic(_:onEach:)` — an
    /// increase-only trigger — fires exactly once per press rather than once
    /// per press *and* release.
    @State private var pressTicks = 0
    /// `Haptics.selection` on press-down, when set. Left nil for most
    /// buttons — a tap is its own feedback, per `Haptics.swift` — this is
    /// for the few whose press itself is the meaningful choice (a segmented
    /// pick), not a step toward one a later `.success`/`.committed` will mark.
    var haptic: SensoryFeedback?
    /// A disabled control is a different control, not a faded live one — the
    /// same rule `StateAction` already follows (see its doc comment: an
    /// `.opacity` fade dims foreground and background together and can leave
    /// text under Apple's contrast minimum). `PressStyle` used to have no
    /// disabled look at all: a disabled button under it rendered identically
    /// to a live one and pressed with the same spring, so a spine with no
    /// link (`AppleVolumesRow.swift:63`) or a row with no series
    /// (`LibraryList.swift:68`) looked exactly as tappable as one that
    /// worked (gaps 52, 65).
    @Environment(\.isEnabled) private var isEnabled

    init(haptic: SensoryFeedback? = nil) {
        self.haptic = haptic
    }

    @ViewBuilder
    func makeBody(configuration: Configuration) -> some View {
        let isPressed = configuration.isPressed
        let label = configuration.label
            .foregroundStyle(Self.foregroundColor(isEnabled: isEnabled))
            .scaleEffect(Self.scale(isEnabled: isEnabled, isPressed: isPressed, reduceMotion: reduceMotion))
            .opacity(Self.opacity(isEnabled: isEnabled, isPressed: isPressed, reduceMotion: reduceMotion))
            .animation(Motion.reduced(Motion.snappy), value: isPressed)
            .onChange(of: isPressed) { _, pressed in
                if pressed, isEnabled { pressTicks += 1 }
            }
        if let haptic {
            label.haptic(haptic, onEach: pressTicks)
        } else {
            label
        }
    }

    /// A disabled control is a different control, not a faded live one — see
    /// the type's doc comment. `nonisolated static` and returning a concrete
    /// `Color` (rather than `.foreground`/`AnyShapeStyle`) so `StateFamilyTests`
    /// can assert the disabled look with `==`: `ButtonStyleConfiguration` has
    /// no public initialiser, so a test cannot drive `makeBody` itself and
    /// needs a pure, comparable function to call instead. `.primary` for the
    /// enabled case is overridden by whatever explicit colour the label
    /// already sets further in (every call site in this app that cares about
    /// its own colour, e.g. `StateAction`, sets it on the label directly), so
    /// this only ever changes anything for a label that had no opinion.
    nonisolated static func foregroundColor(isEnabled: Bool) -> Color {
        isEnabled ? .primary : Palette.textMuted
    }

    /// No press scale while disabled: the finger's answer is for a control
    /// that is about to do something, and a disabled one isn't.
    nonisolated static func scale(isEnabled: Bool, isPressed: Bool, reduceMotion: Bool) -> CGFloat {
        guard isEnabled, !reduceMotion else { return 1 }
        return isPressed ? 0.97 : 1
    }

    /// Under Reduce Motion a disabled control does not get the pressed dip
    /// either — the dip stands in for the scale as this control's *only*
    /// answer to a press, and a disabled control has no answer to give.
    nonisolated static func opacity(isEnabled: Bool, isPressed: Bool, reduceMotion: Bool) -> Double {
        reduceMotion && isPressed && isEnabled ? 0.8 : 1
    }
}

extension ButtonStyle where Self == PressStyle {
    /// The app's default for anything the reader taps: cards, chips, rows.
    static var press: PressStyle { PressStyle() }

    /// `.press`, plus `Haptics.selection` on press-down — for a control
    /// whose press is itself the choice (a segmented pick), not a step
    /// toward one a later write's own haptic will mark.
    static func press(haptic: SensoryFeedback) -> PressStyle { PressStyle(haptic: haptic) }
}
