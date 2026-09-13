import SwiftUI

/// The stack's title, its saved counter, and the way to start over.
///
/// Title and counter sit side by side until the text is large enough that they
/// squeeze each other — at which point the title truncated to "The sta…" and
/// the counter broke into "4" over "saved".
struct StackHeader: View {
    let savedCount: Int
    /// Where the cards came from, said under the title.
    let provenance: String
    /// False once the reader has dragged a card. See `StackHint`.
    let showsInstruction: Bool
    /// `StackModel.todayProgress`, for the streak ring next to the counter.
    let todayAnswered: Int
    let todayDealt: Int
    /// Where a saved card should land, for the counter's own half of the
    /// save-flight `matchedGeometryEffect` — see `StackView`.
    let saveFlightNamespace: Namespace.ID
    let onReset: () async -> Void

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 12) {
                title
                count
            }
            .padding(.horizontal, Metrics.gutterStack)
            .padding(.bottom, 14)
            .overlay(alignment: .topTrailing) { StackResetMenu(onReset: onReset) }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                title
                Spacer(minLength: 0)
                StackStreakRing(answered: todayAnswered, dealt: todayDealt)
                count
                StackResetMenu(onReset: onReset)
            }
            .padding(.horizontal, Metrics.gutterStack)
            .padding(.bottom, 14)
        }
    }

    private var title: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("The stack")
                .typeStackTitle()
                .foregroundStyle(Palette.textEmphasis)
                .fixedSize(horizontal: false, vertical: true)
            // The provenance line ("Picked from your MangaBaka library")
            // used to sit here. Abdi, 2026-09-13: dead space — the reason
            // under each card already says where it came from, and the
            // header's job is the count and the ring.
            if showsInstruction {
                Text("Drag the cover aside · tap it to open")
                    .typeInstruction()
                    .foregroundStyle(Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var count: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text("\(savedCount)")
                .countsNotCuts()
                .animation(Motion.reduced(.snappy(duration: 0.25)), value: savedCount)
                .typeStatNumber()
                .foregroundStyle(Palette.accent)
            Text("saved")
                .typeGridMeta()
                .foregroundStyle(Palette.textMuted)
        }
        .fixedSize()
        // The save-flight ghost card lands here: a near-invisible anchor
        // sharing the flight's id so `matchedGeometryEffect` has somewhere
        // in the header to resolve to. `isSource` keeps this anchor's own
        // natural (tiny) frame fixed as the destination, rather than letting
        // the much larger card impose its size back onto the counter.
        .background {
            Color.clear
                .frame(width: 1, height: 1)
                .matchedGeometryEffect(id: StackView.saveFlightID, in: saveFlightNamespace, isSource: true)
        }
        // Rewards the reader for saving, not for the counter simply having a
        // value: fires once the flight lands, alongside `Haptics.success`.
        .celebrates(on: savedCount)
        .haptic(Haptics.success, onEach: savedCount)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(savedCount) saved")
    }
}

/// How far through today's stack the reader has gotten — answered ÷ dealt,
/// from `StackModel.todayProgress`. Purely a mood ring: `dealt` is a guess
/// at a day's worth of cards (`StackModel.dailyGoal`), not a real quota, so
/// this never blocks or scolds, it just fills.
private struct StackStreakRing: View {
    let answered: Int
    let dealt: Int

    private var fraction: Double {
        guard dealt > 0 else { return 0 }
        return min(1, Double(answered) / Double(dealt))
    }

    private var isComplete: Bool { fraction >= 1 }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Palette.hairline, lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(Palette.accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(Motion.reduced(Motion.settle), value: fraction)
        }
        .frame(width: 20, height: 20)
        .celebrates(on: isComplete)
        .haptic(Haptics.success, on: isComplete)
        // The number itself is read out by the saved counter next to it;
        // this ring repeats the same fact visually and would only be noise
        // to VoiceOver.
        .accessibilityHidden(true)
    }
}
