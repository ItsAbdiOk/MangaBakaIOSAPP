import SwiftUI

/// First run.
///
/// **Deliberately not a gate.** Every discovery endpoint answers without a
/// token — rising, search, series detail, blends, tags, genres, all verified —
/// so a new reader gets a fully working app with no account. Nothing here
/// stands between opening the app and seeing covers; it explains what an
/// account adds and then gets out of the way.
///
/// This is a first attempt, to be replaced by a design. It is built only from
/// things the app can actually do, so a redesign has real boundaries to work
/// within rather than inventing features that do not exist.
struct OnboardingView: View {
    let onFinish: () -> Void
    let onConnectAccount: () -> Void

    @State private var page = 0

    private struct Page: Identifiable {
        let id: Int
        let symbol: String
        let title: String
        let body: String
    }

    /// Three claims, each true of the shipped app.
    private static let pages: [Page] = [
        Page(
            id: 0,
            symbol: "square.grid.2x2",
            title: "Find something worth reading",
            body: """
            Browse what's rising, blend series you already like into new ones, \
            and swipe through covers to triage quickly. No account needed — all \
            of it works signed out.
            """
        ),
        Page(
            id: 1,
            symbol: "wand.and.sparkles",
            title: "See why, not just what",
            body: """
            A blend shows the ten tags it was built from, and you can switch \
            any of them off and watch the results re-derive. Recommendations \
            you can argue with rather than take on trust.
            """
        ),
        Page(
            id: 2,
            symbol: "books.vertical",
            title: "Bring your library",
            body: """
            Add a MangaBaka token and the app reads your shelves, estimates \
            when your next chapters are due, and makes the stack yours instead \
            of random. Optional, and it stays on this device.
            """
        )
    ]

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $page) {
                ForEach(Self.pages) { item in
                    pageView(item).tag(item.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))

            controls
        }
        .background(Palette.ground.ignoresSafeArea())
        .preferredColorScheme(.dark)
    }

    private func pageView(_ item: Page) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            Image(systemName: item.symbol)
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(Palette.accent)
                .padding(.bottom, 28)
            Text(item.title)
                .typeScreenTitle()
                .foregroundStyle(Palette.textEmphasis)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text(item.body)
                .typeBody()
                .foregroundStyle(Palette.textMuted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 14)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 32)
        .accessibilityElement(children: .combine)
    }

    private var controls: some View {
        VStack(spacing: 10) {
            Button(action: onFinish) {
                Text("Start browsing")
                    .typeCTA()
                    .foregroundStyle(Palette.onAccent)
                    .frame(maxWidth: .infinity)
                    .frame(height: Metrics.ctaPrimary)
                    .background(Palette.accent, in: RoundedRectangle(
                        cornerRadius: Metrics.radiusCard, style: .continuous
                    ))
            }
            .buttonStyle(.plain)

            // Second, not first: an account is an addition, not a requirement.
            Button(action: onConnectAccount) {
                Text("Connect an account")
                    .typeRowTitle()
                    .foregroundStyle(Palette.textPrimary)
                    .frame(maxWidth: .infinity)
                    .frame(height: Metrics.ctaSecondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Metrics.gutter)
        .padding(.bottom, 20)
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
