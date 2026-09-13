import Foundation
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
    /// Which of two things a toast is confirming. Purely presentational today
    /// (both render as the same capsule) — the split exists because a
    /// `.failure` gets a longer window and cannot be pre-empted by a
    /// `.success` arriving inside it. A save that quietly failed and then
    /// looked, two seconds later, like every other successful save is exactly
    /// how "Saved here" after a throw (`StackModel.swift:267`) went
    /// unnoticed.
    enum Kind {
        case success
        case failure
    }

    private(set) var message: String?
    private var kind: Kind = .success
    private var dismissal: Task<Void, Never>?
    /// When the current toast should stop protecting itself from replacement.
    /// Only set for `.failure` — a `.success` toast has never needed this,
    /// because nothing before now ever asked to keep it up over an
    /// interruption.
    private var protectedUntil: Date?

    /// Shows a message, replacing whatever was there — with one exception: a
    /// `.failure` toast holds the screen for `failureDuration`, and a
    /// `.success` arriving inside that window does not clear it. A write that
    /// failed and then a moment later reported "Saved" (the reload that
    /// follows a failed write can still succeed) must not read as the write
    /// having worked.
    ///
    /// `failureDuration` is 4s: **a guess.** Long enough to read a full
    /// sentence rather than glimpse it (the existing 2s default suits a
    /// three-word confirmation, not a failure explaining itself), short
    /// enough that it does not become the next thing the reader has to wait
    /// out. No usability measurement backs the number; revisit if a real
    /// session recording says otherwise.
    static let failureDuration: Duration = .seconds(4)

    func show(_ message: String, kind: Kind = .success, for duration: Duration? = nil) {
        let now = Date()
        if let protectedUntil, now < protectedUntil, kind == .success {
            // A failure is still holding the floor; a success does not get to
            // clear it early. A second failure, or the reader triggering a
            // new one deliberately, still replaces it — only `.success` is
            // held back, because only a false "it worked" is actively
            // misleading.
            return
        }

        dismissal?.cancel()
        self.message = message
        self.kind = kind
        let resolvedDuration = duration ?? (kind == .failure ? Self.failureDuration : .seconds(2))
        protectedUntil = kind == .failure
            ? now.addingTimeInterval(resolvedDuration.timeInterval)
            : nil

        // The only confirmation the app gives for a write. The overlay does
        // not take focus, so without this a VoiceOver reader who saved a
        // series got a haptic and no words.
        AccessibilityNotification.Announcement(message).post()
        dismissal = Task { [weak self] in
            try? await Task.sleep(for: resolvedDuration)
            guard !Task.isCancelled else { return }
            self?.message = nil
            self?.protectedUntil = nil
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

private extension Duration {
    /// `Duration` has no direct `TimeInterval` accessor; `APIClient` computes
    /// this same conversion inline for `NetworkLedger`, and this is the
    /// second call site, so it earns a name here rather than a second copy of
    /// the arithmetic.
    var timeInterval: TimeInterval {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
