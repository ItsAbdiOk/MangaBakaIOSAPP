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
    // `private(set)`, not `private`: the overlay reads this to choose between
    // `Haptics.success` and `Haptics.warning` — a plain `.success` unconditionally
    // for both kinds is how a failed write buzzed the same as one that landed.
    private(set) var kind: Kind = .success
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

    /// The reader swiping a toast away early. Distinct from the timeout
    /// above only in that it is deliberate, so it clears the same way a
    /// `.failure`'s protection included — a swipe is at least as clear a
    /// signal as time running out.
    func dismiss() {
        dismissal?.cancel()
        message = nil
        protectedUntil = nil
    }
}

/// Internal rather than private so `ToastTests` can reach the hit-testing
/// rule below; nothing outside this file constructs it.
struct ToastOverlay: ViewModifier {
    let centre: ToastCentre
    /// A swipe-down far enough to count as "dismiss this" rather than a
    /// stray drag. 40pt is a guess, generous enough that a reader aiming
    /// roughly downward at the capsule does not have to be precise.
    private static let dismissThreshold: CGFloat = 40
    @State private var dragOffset: CGFloat = 0

    /// The only region of the screen a toast takes taps from: the capsule
    /// itself. Seen on the simulator 2026-09-13: with a toast up, a reader
    /// who had just saved one series could not tap the next until it faded.
    /// The swipe gesture used to be attached *after* the 104pt bottom
    /// padding and the 300pt max-width frame, so its hit region was whatever
    /// SwiftUI decided that padded, framed subtree covered — over the tab bar
    /// — rather than the card. Now the shape is stated, attached before the
    /// padding, and this rule is what the test checks.
    nonisolated static var interactionShape: Capsule { Capsule() }

    /// Whether a tap at `point` lands on the card whose frame is `card`.
    /// Everything outside — the padding under the capsule, the rest of the
    /// overlay — passes through to the content beneath.
    nonisolated static func capturesTap(at point: CGPoint, card: CGRect) -> Bool {
        interactionShape.path(in: card).contains(point)
    }

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
                    // The swipe-down needs hit testing on (the old
                    // `.allowsHitTesting(false)` went with it), so the hit
                    // region is pinned to the capsule here — before the
                    // bottom padding below, which would otherwise be part of
                    // the gestured subtree and sit exactly over the tab bar.
                    // See `interactionShape`.
                    .contentShape(Self.interactionShape)
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                guard value.translation.height > 0 else { return }
                                dragOffset = value.translation.height
                            }
                            .onEnded { value in
                                if value.translation.height > Self.dismissThreshold {
                                    centre.dismiss()
                                }
                                withAnimation(Motion.reduced(Motion.snappy)) { dragOffset = 0 }
                            }
                    )
                    // Above the tab bar, not behind it. The mockup puts it at
                    // 104px from the bottom, which is the bar plus its inset.
                    .padding(.bottom, Metrics.scrollBottomInset)
                    .offset(y: max(0, dragOffset))
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .accessibilityAddTraits(.isStaticText)
            }
        }
        // Settles in — content arriving — and leaves with the quicker,
        // answering-a-gesture spring: a toast that lingered on the way out
        // as long as it did on the way in read as reluctant to go.
        .animation(centre.message != nil ? Motion.reduced(Motion.settle) : Motion.reduced(Motion.snappy),
                   value: centre.message)
        // A toast is the confirmation that an action worked, or the warning
        // that it didn't — it appears near the bottom of a screen the reader
        // may not be looking at, so the tap gets an answer even when the
        // text does not. The two kinds do not share one feel.
        .sensoryFeedback(Haptics.success, trigger: centre.message) { _, new in
            new != nil && centre.kind == .success
        }
        .sensoryFeedback(Haptics.warning, trigger: centre.message) { _, new in
            new != nil && centre.kind == .failure
        }
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
