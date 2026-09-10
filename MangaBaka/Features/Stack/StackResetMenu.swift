import SwiftUI

/// A way back out of a run of swipes.
///
/// The stack blends what comes next from what has been saved, so a handful of
/// swipes in a direction the reader did not mean sends every card after them
/// the same way — and there is no unswipe. This is the way back.
///
/// Behind a confirmation because it throws away every save and skip on the
/// device, and the confirmation says exactly what it does and does not touch:
/// a save also wrote `plan_to_read` to the reader's MangaBaka library, and
/// deleting rows from someone's real account to undo a swipe is a much larger
/// action than the one being asked for.
struct StackResetMenu: View {
    let onReset: () async -> Void

    @State private var isConfirming = false

    var body: some View {
        Menu {
            Button("Start the stack over", systemImage: "arrow.counterclockwise", role: .destructive) {
                isConfirming = true
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Palette.textSecondary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Stack options")
        .confirmationDialog(
            "Start the stack over?",
            isPresented: $isConfirming,
            titleVisibility: .visible
        ) {
            Button("Start over", role: .destructive) {
                Task { await onReset() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("""
            Forgets every save and skip on this device, and deals a fresh stack. \
            Anything already added to your MangaBaka library stays there.
            """)
        }
    }
}
