import SwiftUI

/// A confirmation dialog for an action that cannot be undone, extracted from
/// `StackResetMenu` — which built exactly this and nothing else, for exactly
/// one button.
///
/// Three more places do a destructive action with no confirmation at all
/// today (gap 12, 90; "Deal another now", "Remove token"), each one throwing
/// away something the reader cannot get back — every save on the device, or
/// every store tied to an account — with a single, undefended tap. This gives
/// each of them `StackResetMenu`'s dialog without re-deriving it.
struct ConfirmDestructive: ViewModifier {
    @Binding var isPresented: Bool
    /// The dialog's title, shown with `titleVisibility: .visible` — phrased
    /// as the question being asked, e.g. "Start the stack over?".
    let title: String
    /// What the action actually does and does not touch, in full sentences.
    /// `StackResetMenu`'s own message is the model: it names what is lost
    /// ("every save and skip on this device") and what survives ("Anything
    /// already added to your MangaBaka library stays there") — a reader
    /// deciding whether to confirm needs both halves, not just the warning.
    let consequence: String
    /// The destructive button's label. Nil derives it from `title` by
    /// dropping a trailing "?"; the stack passes "Start over" because that is
    /// the mockup's wording and it is shorter than the question.
    let label: String?
    let action: () async -> Void

    private var confirmLabel: String {
        label ?? (title.hasSuffix("?") ? String(title.dropLast()) : title)
    }

    func body(content: Content) -> some View {
        content.confirmationDialog(title, isPresented: $isPresented, titleVisibility: .visible) {
            Button(confirmLabel, role: .destructive) {
                Task { await action() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(consequence)
        }
    }
}

extension View {
    /// Behind a confirmation because the action it guards cannot be undone —
    /// see `ConfirmDestructive`'s doc comment for the three current call
    /// sites that skip this today.
    func confirmDestructive(
        isPresented: Binding<Bool>,
        title: String,
        consequence: String,
        label: String? = nil,
        action: @escaping () async -> Void
    ) -> some View {
        modifier(ConfirmDestructive(
            isPresented: isPresented,
            title: title,
            consequence: consequence,
            label: label,
            action: action
        ))
    }
}
