import SwiftUI

/// First run.
///
/// **Deliberately not a gate.** Every discovery endpoint answers without a
/// token — rising, search, series detail, blends, tags, genres, all verified —
/// so a new reader gets a fully working app with no account. Nothing here
/// stands between opening the app and seeing covers.
///
/// Three screens, from the design board of 2026-09-10, and three is the number
/// on purpose: search, the library and the schedule are all lists a reader
/// recognises on sight, so a screen explaining them would be teaching what is
/// already obvious. The stack is the one thing in the app nobody can guess from
/// looking, and it gets the middle screen to itself.
///
/// Skip is on every screen including the first. If it genuinely is not a gate,
/// the exit should not be something you discover on screen three.
struct OnboardingView: View {
    let covers: [Series]
    let onFinish: () -> Void
    let onConnectAccount: () -> Void

    @State private var page = 0

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $page) {
                CoversFirstPage(covers: covers).tag(0)
                StackMechanicPage(cover: covers.first).tag(1)
                AccountPage(onConnect: onConnectAccount, onDecline: onFinish).tag(2)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            controls
        }
        .background(Palette.ground.ignoresSafeArea())
        .preferredColorScheme(.dark)
    }

    /// The dots, Skip, and Next — one row, so Skip never competes with the
    /// primary button for the same corner.
    ///
    /// The last screen has its own two buttons and needs neither, so this row
    /// stands down rather than stacking a third and fourth control under them.
    @ViewBuilder
    private var controls: some View {
        if page < 2 {
            HStack {
                Button("Skip", action: onFinish)
                    .typeRowTitle()
                    .foregroundStyle(Palette.textTertiary)

                Spacer(minLength: 12)

                PageDots(count: 3, current: page)

                Spacer(minLength: 12)

                Button("Next") {
                    withAnimation(.snappy(duration: 0.25)) { page += 1 }
                }
                .typeRowTitle()
                .foregroundStyle(Palette.accent)
            }
            .padding(.horizontal, Metrics.gutter)
            .padding(.bottom, 20)
            .padding(.top, 8)
        }
    }
}

/// The dots, drawn rather than taken from `TabView`.
///
/// `TabView`'s own indicator cannot sit in a row beside two buttons, and it
/// puts itself where the board puts Skip.
private struct PageDots: View {
    let count: Int
    let current: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { index in
                Circle()
                    .fill(index == current ? Palette.accent : Palette.textQuaternary)
                    .frame(width: 6, height: 6)
            }
        }
        .accessibilityHidden(true)
    }
}

/// Screen one: the app already working, before anything is explained.
///
/// Real covers from the live rising feed, behind the copy. Nothing is promised
/// that is not on screen.
///
/// **What happens with no network.** The board suggested shipping a set of
/// covers to fall back on, and Abdi agreed — but bundling real cover art in the
/// binary is redistributing publisher artwork, and MangaBaka's own licence is
/// explicit that third-party data carries no redistribution rights it can grant.
/// Loading art from the CDN at runtime is a different thing from shipping it.
/// So the fallback is a wash of the app's own colours in the same grid: the
/// screen still reads as covers arriving rather than as a broken page, and
/// nothing is redistributed. Flagged to Abdi 2026-09-10.
private struct CoversFirstPage: View {
    let covers: [Series]

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)
    }

    var body: some View {
        VStack(spacing: 0) {
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(0..<6, id: \.self) { index in
                    if let series = covers[safe: index] {
                        CoverImage(
                            cover: series.cover,
                            width: 104,
                            accessibilityText: series.displayTitle ?? "Cover art"
                        )
                    } else {
                        RoundedRectangle(
                            cornerRadius: Metrics.radiusCoverRow, style: .continuous
                        )
                        .fill(Palette.surface)
                        .aspectRatio(Metrics.coverAspect, contentMode: .fit)
                        .accessibilityHidden(true)
                    }
                }
            }
            .padding(.horizontal, 28)
            // The grid is the argument, so it leads and the copy follows.
            .mask(
                LinearGradient(
                    colors: [.black, .black, .black.opacity(0.15)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )

            Spacer(minLength: 16)

            Text("Everything is already here")
                .typeScreenTitle()
                .foregroundStyle(Palette.textEmphasis)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Text("""
            Search, the daily stack and the blend work with no account and no \
            sign-up. You can close this and start reading.
            """)
            .typeBody()
            .foregroundStyle(Palette.textMuted)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 12)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 28)
        .padding(.top, 40)
    }
}

/// Screen two: the one mechanic worth teaching.
private struct StackMechanicPage: View {
    /// A real cover, when one has loaded. Teaching the gesture on an empty grey
    /// rectangle asks a reader to imagine the thing the screen exists to show
    /// them — and the whole argument of screen one is that the covers are the
    /// point.
    let cover: Series?

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            HStack(spacing: 14) {
                direction(symbol: "arrow.left", label: "Left to pass", tint: Palette.textTertiary)
                card
                direction(symbol: "arrow.right", label: "Right to keep", tint: Palette.accent)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Drag a cover left to pass, right to keep")

            Text("A stack a day")
                .typeScreenTitle()
                .foregroundStyle(Palette.textEmphasis)
                .multilineTextAlignment(.center)
                .padding(.top, 34)

            Text("""
            Series drawn from what is rising. Pass or keep, tap for the full \
            page. It refills tomorrow, so there is nothing to catch up on.
            """)
            .typeBody()
            .foregroundStyle(Palette.textMuted)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 12)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 28)
    }

    /// The card, tilted a little the way a card being pushed aside is.
    ///
    /// Static rather than animated: the arrows already say which way, and a
    /// looping animation on a screen someone reads once is a distraction from
    /// the sentence underneath it.
    @ViewBuilder
    private var card: some View {
        ZStack(alignment: .topLeading) {
            if let cover {
                CoverImage(
                    cover: cover.cover,
                    width: 128,
                    radius: Metrics.radiusStackCard,
                    accessibilityText: "A series in the stack"
                )
            } else {
                RoundedRectangle(cornerRadius: Metrics.radiusStackCard, style: .continuous)
                    .fill(Palette.surface)
                    .frame(width: 128, height: 128 / Metrics.coverAspect)
                    .overlay(
                        RoundedRectangle(
                            cornerRadius: Metrics.radiusStackCard, style: .continuous
                        )
                        .strokeBorder(Palette.border, lineWidth: 0.5)
                    )
            }

            // The badge the real card shows while a drag is in progress, held
            // still. It is what the gesture looks like mid-way, which is the
            // part a screenshot of the finished state cannot teach.
            Text("SKIP")
                .typeChip()
                .foregroundStyle(Palette.textPrimary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Palette.borderPill, lineWidth: 0.5))
                .padding(10)
                .accessibilityHidden(true)
        }
        .rotationEffect(.degrees(-4))
    }

    private func direction(symbol: String, label: String, tint: Color) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(tint)
            Text(label)
                .typeSmallMeta()
                .foregroundStyle(Palette.textTertiary)
                .multilineTextAlignment(.center)
        }
        .frame(width: 66)
    }
}

/// Screen three: the only ask, and it is refusable in one tap.
private struct AccountPage: View {
    let onConnect: () -> Void
    let onDecline: () -> Void

    private struct Benefit: Identifiable {
        let id: Int
        let symbol: String
        let title: String
        let body: String
    }

    /// Three, and each one is a thing the app genuinely cannot do without a
    /// token. Nothing aspirational.
    private static let benefits: [Benefit] = [
        Benefit(
            id: 0,
            symbol: "books.vertical",
            title: "A library that follows you",
            body: "Reading states, ratings and progress, synced across devices."
        ),
        Benefit(
            id: 1,
            symbol: "wand.and.sparkles",
            title: "Recommendations from your taste",
            body: "The stack and the blend weight toward what you have rated."
        ),
        Benefit(
            id: 2,
            symbol: "calendar",
            title: "A schedule for what you read",
            body: "Predicted releases for series you are reading or have paused."
        )
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 0)

            Text("An account adds your own data")
                .typeScreenTitle()
                .foregroundStyle(Palette.textEmphasis)
                .fixedSize(horizontal: false, vertical: true)

            Text("Nothing you have seen so far needs one. These three do.")
                .typeBody()
                .foregroundStyle(Palette.textMuted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)

            VStack(alignment: .leading, spacing: 18) {
                ForEach(Self.benefits) { benefit in
                    row(benefit)
                }
            }
            .padding(.top, 28)

            Spacer(minLength: 0)

            Button(action: onConnect) {
                Text("Connect an account")
                    .typeCTA()
                    .foregroundStyle(Palette.onAccent)
                    .frame(maxWidth: .infinity)
                    .frame(height: Metrics.ctaPrimary)
                    .background(Palette.accent, in: RoundedRectangle(
                        cornerRadius: Metrics.radiusCard, style: .continuous
                    ))
            }
            .buttonStyle(.plain)

            // A full-width button, not grey text. Refusing is a real choice
            // here, and a choice styled as an afterthought reads as one the app
            // would rather you did not make.
            Button(action: onDecline) {
                Text("Not now")
                    .typeCTA()
                    .foregroundStyle(Palette.textSecondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: Metrics.ctaSecondary)
                    .overlay(
                        RoundedRectangle(cornerRadius: Metrics.radiusCard, style: .continuous)
                            .strokeBorder(Palette.borderPill, lineWidth: 0.5)
                    )
            }
            .buttonStyle(.plain)
            .padding(.top, 10)
        }
        .padding(.horizontal, 28)
        .padding(.top, 40)
        .padding(.bottom, 12)
    }

    private func row(_ benefit: Benefit) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: benefit.symbol)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Palette.accent)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(benefit.title)
                    .typeRowTitle()
                    .foregroundStyle(Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(benefit.body)
                    .typeSmallMeta()
                    .foregroundStyle(Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Whether onboarding has been seen.
@MainActor
@Observable
final class OnboardingState {
    private static let key = "onboarding.completed"

    private(set) var hasCompleted: Bool
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hasCompleted = defaults.bool(forKey: Self.key)
    }

    func complete() {
        hasCompleted = true
        defaults.set(true, forKey: Self.key)
    }
}
