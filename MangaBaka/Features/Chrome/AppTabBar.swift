import SwiftUI

/// The floating tab capsule and the search button beside it.
///
/// The mockup replaces the system tab bar with a capsule of four tabs plus a
/// separate circular search button. The app still runs a real `TabView`
/// underneath with its bar hidden: that keeps per-tab navigation stacks, lazy
/// loading and state restoration, and this draws over the top. Rebuilding tab
/// switching by hand would have thrown all of that away for a visual change.
struct AppTabBar: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    @Binding var selection: RootView.AppTab
    /// Search is not in the capsule; it is the button beside it.
    let isSearching: Bool
    let onSearch: () -> Void
    /// Tapping the tab you are already on returns to its root, which is what
    /// every iOS tab bar does and what the system one did before this replaced
    /// it. Without it a pushed detail screen could only be left by swiping.
    let onReselect: (RootView.AppTab) -> Void

    /// The four in the capsule, in the mockup's order.
    private static let tabs: [RootView.AppTab] = [.discover, .stack, .mix, .library]

    var body: some View {
        HStack(spacing: Metrics.tabCapsuleGap) {
            capsule
            searchButton
        }
        .padding(.bottom, Metrics.tabBarBottomInset)
    }

    private var capsule: some View {
        HStack(spacing: 2) {
            ForEach(Self.tabs, id: \.self) { tab in
                Button {
                    if selection == tab && !isSearching {
                        onReselect(tab)
                    } else {
                        selection = tab
                    }
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tab.symbol)
                            .font(.system(size: 17, weight: .medium))
                            .frame(height: Metrics.tabIcon)
                        // Labels are dropped at accessibility sizes rather than
                        // scaled. Scaled, they wrapped to three lines each
                        // ("Dis/cov/er"), the capsule ballooned into the middle
                        // of the screen, and it covered content on every screen
                        // — including its own tap targets, which moved 80pt
                        // from where they are drawn. The system tab bar does
                        // the same thing for the same reason; every tab keeps
                        // its accessibilityLabel, so nothing is lost to
                        // VoiceOver.
                        if !typeSize.isAccessibilitySize {
                            Text(tab.title)
                                .typeTabLabel()
                                .lineLimit(1)
                        }
                    }
                    .frame(width: Metrics.tabWidth)
                    .padding(.top, 7)
                    .padding(.bottom, typeSize.isAccessibilitySize ? 7 : 6)
                    .foregroundStyle(isSelected(tab) ? Palette.textEmphasis : Palette.textMuted)
                    .background {
                        if isSelected(tab) {
                            Capsule().fill(Palette.surfaceActive)
                        }
                    }
                    // Explicit, because the label's own background is a glass
                    // layer built on Color.clear and does not take hits.
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(isSelected(tab) ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(Metrics.tabCapsulePadding)
        .background { Glass.floating(Capsule()) }
    }

    /// Library stays lit while Dropped is open, since Dropped is reached from
    /// inside it rather than being a tab of its own.
    private func isSelected(_ tab: RootView.AppTab) -> Bool {
        !isSearching && selection == tab
    }

    private var searchButton: some View {
        Button(action: onSearch) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(isSearching ? Palette.onAccent : Palette.textSecondary)
                .frame(width: Metrics.searchButton, height: Metrics.searchButton)
                .background {
                    if isSearching {
                        Circle().fill(Palette.accent)
                    } else {
                        Glass.floating(Circle())
                    }
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Search")
        .accessibilityAddTraits(isSearching ? [.isButton, .isSelected] : .isButton)
    }
}

/// The top bar: wordmark, cache freshness, and an overflow control.
///
/// Thinner glass than the tab capsule so content reads through it, which is
/// what the mockup's lower alpha encodes.
struct AppTopBar: View {
    /// How old the freshest cached feed is, or nil when nothing is cached yet.
    let cacheAge: TimeInterval?

    var body: some View {
        HStack(spacing: 10) {
            Text("BAKAMANGA")
                .typeWordmark()
                .foregroundStyle(Palette.textPrimary.opacity(0.55))

            Spacer(minLength: 0)

            if let label = cacheLabel {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Palette.positive)
                        .frame(width: 6, height: 6)
                    Text(label)
                        .typeFootnote()
                        .foregroundStyle(Palette.textSecondary)
                }
                .padding(.horizontal, 11)
                .frame(height: Metrics.headerPill)
                .background(Palette.surfacePill, in: Capsule())
                .overlay(Capsule().strokeBorder(Palette.borderPill, lineWidth: 0.5))
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Content cached \(label)")
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .background {
            Glass.topBar(Rectangle())
                .overlay(alignment: .bottom) {
                    Rectangle().fill(Palette.hairline).frame(height: 0.5)
                }
                .ignoresSafeArea(edges: .top)
        }
    }

    private var cacheLabel: String? { Self.cacheLabel(for: cacheAge) }

    /// "Cached 2m". Built from a real timestamp, so it is absent rather than
    /// invented when nothing has been cached yet.
    static func cacheLabel(for age: TimeInterval?) -> String? {
        guard let age, age >= 0 else { return nil }
        let minutes = Int(age / 60)
        if minutes < 1 { return "Cached now" }
        if minutes < 60 { return "Cached \(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "Cached \(hours)h" }
        return "Cached \(hours / 24)d"
    }
}
