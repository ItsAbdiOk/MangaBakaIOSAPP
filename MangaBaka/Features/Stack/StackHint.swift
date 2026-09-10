import Foundation

/// Whether the stack still needs to explain itself.
///
/// "Drag the cover aside · tap it to open" is a tutorial, and a tutorial that
/// never leaves is an accusation. Abdi asked for it to go once the reader has
/// done it: instructions earn their space exactly once.
///
/// **Keyed on the drag, not the tap.** Tapping a cover to open it is what every
/// cover in the app does; the drag is the half nobody would guess. A reader who
/// only ever taps has not learned the gesture and still needs telling.
///
/// **Remembered rather than derived.** The obvious source — "has this reader
/// saved or skipped anything?" — is the shelf, and resetting the stack empties
/// it. Someone who has used the app for a month and then reset it would be
/// taught the gesture again.
@MainActor
@Observable
final class StackHint {
    private static let key = "stack.hasDraggedACard"

    private(set) var hasDragged: Bool
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hasDragged = defaults.bool(forKey: Self.key)
    }

    /// Called when a drag is committed, not when one begins: a drag that snaps
    /// back is a reader who has not done it yet.
    func markDragged() {
        guard !hasDragged else { return }
        hasDragged = true
        defaults.set(true, forKey: Self.key)
    }
}
