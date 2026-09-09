import SwiftUI

/// Cover-forward triage. Drag right to save, left to skip, tap for detail.
///
/// Physics come from the design spec: 0.012° of rotation per point of drag, a
/// 92pt commit threshold, and badge opacity tied to |dx| / 80 so the decision
/// is legible before you let go.
struct StackView: View {
    @State private var model: StackModel
    @Binding private var path: [Series]

    @State private var drag: CGSize = .zero
    @State private var isDragging = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let commitThreshold: CGFloat = 92
    private let rotationPerPoint: Double = 0.012
    private let badgeDivisor: CGFloat = 80

    init(model: StackModel, path: Binding<[Series]>) {
        _model = State(initialValue: model)
        _path = path
    }

    var body: some View {
        ZStack {
            Palette.ground.ignoresSafeArea()

            if let current = model.current {
                // The next card, peeking behind, so the stack reads as a stack.
                if let next = model.next {
                    card(next, showsText: false)
                        .scaleEffect(0.94)
                        .offset(y: 14)
                        .opacity(0.5)
                        .blur(radius: 1)
                        .allowsHitTesting(false)
                }

                card(current)
                    .offset(drag)
                    .rotationEffect(.degrees(drag.width * rotationPerPoint))
                    .overlay(alignment: .top) { decisionBadges }
                    .gesture(dragGesture)
                    .onTapGesture { path.append(current) }
                    // VoiceOver cannot perform a drag, so saving and skipping
                    // are exposed as actions. Without these the entire screen
                    // is unusable with the screen reader on.
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(current.displayTitle ?? "Untitled series")
                    .accessibilityHint("Double tap for details")
                    .accessibilityAction(named: "Save") {
                        Task { await model.react(.saved) }
                    }
                    .accessibilityAction(named: "Skip") {
                        Task { await model.react(.skipped) }
                    }
            } else if model.isLoading {
                ProgressView().tint(Palette.textTertiary)
            } else {
                emptyState
            }
        }
        // Says what the queue is built from, because "are these actually based
        // on my taste?" is otherwise unanswerable from the screen. A random
        // queue says so rather than passing itself off as personalised.
        .overlay(alignment: .bottom) {
            if model.current != nil {
                Text(model.source.caption)
                    .typeSmallMeta()
                    .foregroundStyle(Palette.textTertiary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Metrics.gutter)
                    .padding(.bottom, Metrics.tabBarClearance)
            }
        }
        .task { await model.loadIfNeeded() }
    }

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                isDragging = true
                drag = value.translation
            }
            .onEnded { value in
                let dx = value.translation.width
                if abs(dx) > commitThreshold {
                    let kind: ShelfEntry.Kind = dx > 0 ? .saved : .skipped
                    // Throw the card off-screen in the direction of travel.
                    // A card thrown the width of the screen is a lot of motion.
                    // With Reduce Motion on, it simply goes.
                    if reduceMotion {
                        drag = .zero
                    } else {
                        withAnimation(.easeOut(duration: 0.22)) {
                            drag.width = dx > 0 ? 700 : -700
                        }
                    }
                    Task {
                        await model.react(kind)
                        drag = .zero
                        isDragging = false
                    }
                } else {
                    // The spec's return spring.
                    withAnimation(.spring(response: 0.36, dampingFraction: 0.78)) {
                        drag = .zero
                    }
                    isDragging = false
                }
            }
    }

    /// - Parameter showsText: false for the card peeking behind. Its title used
    ///   to render at half opacity directly under the front card's title, which
    ///   read as a ghosted duplicate of the wrong series rather than as depth.
    ///   Only the cover should peek.
    private func card(_ series: Series, showsText: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            CoverImage(cover: series.cover, width: 268, radius: Metrics.radiusStackCard)
                .shadow(color: .black.opacity(0.65), radius: 30, y: 24)

            VStack(alignment: .leading, spacing: 6) {
                Text(series.displayTitle ?? "Untitled series")
                    .typeStackTitle()
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                if let authors = series.authors, !authors.isEmpty {
                    Text(authors.joined(separator: ", "))
                        .typeSubtitle()
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(1)
                }
            }
            .frame(width: 268, alignment: .leading)
            // Hidden rather than removed, so both cards keep the same height
            // and the one behind stays exactly the intended amount lower.
            .opacity(showsText ? 1 : 0)
        }
        .padding(.horizontal, Metrics.gutterStack)
    }

    /// SAVE and SKIP fade in with the drag, so the outcome is readable before
    /// the reader commits to it.
    private var decisionBadges: some View {
        let strength = min(abs(drag.width) / badgeDivisor, 1)
        return HStack {
            badge("SKIP", Palette.textPrimary)
                .opacity(drag.width < 0 ? strength : 0)
            Spacer()
            badge("SAVE", Palette.accent)
                .opacity(drag.width > 0 ? strength : 0)
        }
        .padding(.horizontal, 34)
        .padding(.top, 26)
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text)
            .typeEyebrow()
            .foregroundStyle(color)
            .padding(.horizontal, 13)
            .frame(height: Metrics.headerPill)
            .overlay(Capsule().strokeBorder(color, lineWidth: 1.5))
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Text(model.message == nil ? "That's the stack for now" : "Can't load the stack")
                .typeSubsectionHeader()
                .foregroundStyle(Palette.textPrimary)
            Text(model.message ?? "Save a few and the next batch will lean towards them.")
                .typeSubtitle()
                .foregroundStyle(Palette.textSecondary)
                .multilineTextAlignment(.center)
            Button("Load more") { Task { await model.refill() } }
                .typeCTA()
                .foregroundStyle(Palette.onAccent)
                .padding(.horizontal, 18)
                .frame(height: Metrics.ctaSecondary)
                .background(Palette.accent, in: Capsule())
                .padding(.top, 6)
        }
        .padding(.horizontal, 44)
    }
}
