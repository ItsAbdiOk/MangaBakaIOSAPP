import SwiftUI

/// A brief, non-blocking confirmation, floating above the tab bar.
///
/// One of the six surfaces the design spec allows glass on, and the last of
/// them the app had not built. It exists because several actions currently
/// succeed in silence — a stack save, a library write, a reset — and an action
/// that gives no sign it worked is indistinguishable from one that missed.
///
/// Deliberately not an alert: none of these need acknowledging, and a dialog
/// for a save would be worse than saying nothing at all.
@MainActor
@Observable
final class ToastCentre {
    private(set) var message: String?
    private var dismissal: Task<Void, Never>?

    /// Shows a message, replacing whatever was there.
    ///
    /// Replacing rather than queueing: three quick saves should leave one
    /// message, not three shown in turn while the reader waits for the last.
    func show(_ message: String, for duration: Duration = .seconds(2)) {
        dismissal?.cancel()
        self.message = message
        dismissal = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.message = nil
        }
    }
}

private struct ToastOverlay: ViewModifier {
    let centre: ToastCentre

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let message = centre.message {
                Text(message)
                    .typeSmallMeta()
                    .foregroundStyle(Palette.textPrimary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 11)
                    .frame(maxWidth: 300)
                    .background { Glass.floating(Capsule()) }
                    .clipShape(Capsule())
                    // Above the tab bar, not behind it. The mockup puts it at
                    // 104px from the bottom, which is the bar plus its inset.
                    .padding(.bottom, Metrics.scrollBottomInset)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    // Never intercepts a tap: it is a statement, not a control,
                    // and a reader reaching for the tab bar while one is up
                    // must not hit it instead.
                    .allowsHitTesting(false)
                    .accessibilityAddTraits(.isStaticText)
            }
        }
        .animation(Motion.reduced(.snappy(duration: 0.28)), value: centre.message)
        // A toast is the confirmation that an action worked. It appears near
        // the bottom of a screen the reader may not be looking at, so the tap
        // gets an answer even when the text does not.
        .sensoryFeedback(.success, trigger: centre.message) { _, new in new != nil }
    }
}

extension View {
    /// Puts the app's toasts over this view. Applied once, at the root.
    func toasts(_ centre: ToastCentre) -> some View {
        modifier(ToastOverlay(centre: centre))
    }
}
