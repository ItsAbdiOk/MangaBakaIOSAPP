import SwiftUI

/// The shapes the wrapped screen is built from.
///
/// Its own file because `WrappedView` hit the lint's 250-line body ceiling,
/// and because these are the parts with no opinion in them: a card, a big
/// number, a sentence under it, and a smaller sentence admitting to something.
extension WrappedView {
    // MARK: - Shapes

    func card<Content: View>(
        _ eyebrow: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Eyebrow(text: eyebrow)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .hairlineBorder(Palette.border, radius: 20)
    }

    func headline(_ value: String, _ unit: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text(value)
                .typeScreenTitle()
                .foregroundStyle(Palette.textPrimary)
                .countsNotCuts()
                .lineLimit(2)
                .minimumScaleFactor(0.5)
                .fixedSize(horizontal: false, vertical: true)
            if !unit.isEmpty {
                Text(unit)
                    .typeSubtitle()
                    .foregroundStyle(Palette.textMuted)
            }
        }
    }

    /// `headline`, but the number counts up from 0 to `target` as the card
    /// arrives rather than appearing whole — the motion brief's "that
    /// dopamine hit" for the one screen in this app whose entire point is a
    /// handful of big numbers. `index` matches the card's own `.arrives(index:)`
    /// so the count starts exactly when the card has finished rising in,
    /// not before it is legible. Under Reduce Motion `CountUpNumber` shows
    /// `target` immediately — no count, per the brief's rule 9.
    func headlineCounting(_ target: Int, _ unit: String, index: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            CountUpNumber(target: target, index: index)
                .typeScreenTitle()
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(2)
                .minimumScaleFactor(0.5)
                .fixedSize(horizontal: false, vertical: true)
            if !unit.isEmpty {
                Text(unit)
                    .typeSubtitle()
                    .foregroundStyle(Palette.textMuted)
            }
        }
    }

    func detail(_ text: String) -> some View {
        Text(text)
            .typeBody()
            .foregroundStyle(Palette.textBody)
            .fixedSize(horizontal: false, vertical: true)
    }

    func caveat(_ text: String) -> some View {
        Text(text)
            .typeFootnote()
            .foregroundStyle(Palette.textMuted)
            .fixedSize(horizontal: false, vertical: true)
    }

    func monthName(_ month: Int) -> String {
        DateFormatter().monthSymbols?[max(0, min(11, month - 1))] ?? "\(month)"
    }
}

/// Whether an arrival should still fire its one-time haptic — the pure,
/// testable half of `.arrivalHaptic(index:)`. A `struct` rather than a bare
/// `Bool` so the "already fired" rule has one name and one call site instead
/// of being re-derived at each of them.
struct ArrivalHapticLatch: Equatable {
    private var hasFired = false

    /// Returns `true` (and latches) the first time this is called; `false`
    /// every time after. Mutating rather than returning a new value, so a
    /// `@State` holder can call it in place the way `SettingsView`'s own
    /// `@State` mutations already read.
    mutating func fireOnce() -> Bool {
        guard !hasFired else { return false }
        hasFired = true
        return true
    }
}

/// One `Haptics.tick` as a card lands — see the motion brief's Wrapped rule.
/// Timed off the same `Motion.stagger(index)` delay `.arrives(index:)` uses,
/// so the tick and the rise finish together rather than the tick either
/// pre-empting a card that has not visibly arrived yet or trailing one that
/// already has. Latched through `ArrivalHapticLatch` so a body re-evaluation
/// (a sibling card's state changing, a rotation) cannot fire it twice.
private struct ArrivalHapticModifier: ViewModifier {
    let index: Int
    @State private var latch = ArrivalHapticLatch()
    @State private var tickCount = 0

    func body(content: Content) -> some View {
        content
            .haptic(Haptics.tick, onEach: tickCount)
            .onAppear {
                guard !Motion.isReduced else { return }
                // `@MainActor in`, matching `CelebratesModifier`'s own
                // pattern in `MotionModifiers.swift`: both `latch` and
                // `tickCount` are `@State`, mutable only on the main actor.
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(Motion.stagger(index)))
                    guard latch.fireOnce() else { return }
                    tickCount += 1
                }
            }
    }
}

extension View {
    /// See `ArrivalHapticModifier`.
    func arrivalHaptic(index: Int) -> some View {
        modifier(ArrivalHapticModifier(index: index))
    }
}

/// The digit that counts up rather than cutting in, for `headlineCounting`.
///
/// Driven by a `TimelineView(.animation)` reading wall-clock time rather than
/// an `@State` mutated by `withAnimation` — `WrappedView.countUp` needs an
/// intermediate value to show on every frame, and SwiftUI only interpolates
/// values it knows how to animate (numeric `Double`/`CGFloat` properties on
/// shapes and the like), not an arbitrary `Int` fed through a pure function.
/// A `TimelineView` sidesteps that: it redraws on every frame regardless, and
/// `countUp` turns "how much time has passed" into "what to show" itself.
private struct CountUpNumber: View {
    let target: Int
    let index: Int
    /// How long the count-up takes, once it starts. Matches `Motion.settle`'s
    /// own response (0.45s, itself a guess — see `Motion.swift`) rather than
    /// inventing a second number for the same "content arriving" motion.
    private static let duration: TimeInterval = 0.45

    @State private var start: Date?

    var body: some View {
        if Motion.isReduced {
            // Rule 9: Reduce Motion shows the final number at once, not a
            // faster count — a count is itself the movement being asked for
            // less of, not just its duration.
            Text("\(target)")
        } else {
            TimelineView(.animation) { timeline in
                let began = start ?? timeline.date
                let elapsed = timeline.date.timeIntervalSince(began) - Motion.stagger(index)
                let progress = elapsed / Self.duration
                Text("\(WrappedView.countUp(progress: progress, target: target))")
                    .countsNotCuts()
                    .onAppear { if start == nil { start = timeline.date } }
            }
        }
    }
}
