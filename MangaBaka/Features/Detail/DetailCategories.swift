import SwiftUI

/// "What it's actually like" — MangaUpdates' vote-weighted categories for a
/// series, shown as a row of chips.
///
/// Same loading/loaded/empty/failed shape as `ContinuationsRow`: a section
/// that asked and got nothing back (no MangaUpdates id, or MangaUpdates
/// answered with zero categories) simply isn't shown, but a section that
/// asked and failed owes the reader a line saying so.
struct DetailCategories: View {
    var categories: [MangaUpdatesCategories.Category]
    var isLoading: Bool
    var failure: APIError?
    var onRetry: (() async -> Void)?

    @State private var showingAll = false

    init(
        categories: [MangaUpdatesCategories.Category],
        isLoading: Bool,
        failure: APIError?,
        onRetry: (() async -> Void)? = nil
    ) {
        self.categories = categories
        self.isLoading = isLoading
        self.failure = failure
        self.onRetry = onRetry
    }

    /// GUESS: enough to fill a couple of `FlowLayout` rows at the default
    /// text size before asking the reader to expand.
    nonisolated static let collapsedCount = 12

    /// The chip's visible text. `nonisolated static` so `DetailCategoriesTests`
    /// can pin the exact string without building the view.
    nonisolated static func chipLabel(_ category: MangaUpdatesCategories.Category) -> String {
        "\(category.name) · \(category.score)"
    }

    /// The chip's spoken label — the name and vote count as a sentence,
    /// rather than the visual "·" separator VoiceOver would otherwise read
    /// as a raw character.
    nonisolated static func chipAccessibilityLabel(_ category: MangaUpdatesCategories.Category) -> String {
        "\(category.name), \(category.score) votes"
    }

    /// Whether "Show all N" appears at all — only once there is a second row
    /// worth hiding.
    nonisolated static func showsExpandToggle(count: Int) -> Bool {
        count > collapsedCount
    }

    var body: some View {
        let state = Self.state(categories: categories, isLoading: isLoading, failure: failure)
        Group {
            switch state {
            case .skeleton:
                VStack(alignment: .leading, spacing: 11) {
                    header
                    skeleton
                }
                .padding(.top, Metrics.sectionGap)
                .transition(.blurReplace)
            case .failed:
                VStack(alignment: .leading, spacing: 11) {
                    header
                    // `.failed` here is defined as "categories.isEmpty, failure
                    // != nil" — `failure` is force-unwrapped-free by construction,
                    // but spelled with `if let` rather than `!` regardless.
                    if let failure {
                        InlineFailure(error: failure, retry: onRetry)
                    }
                }
                .padding(.top, Metrics.sectionGap)
                .transition(.blurReplace)
            case .chips:
                VStack(alignment: .leading, spacing: 11) {
                    header
                    FlowLayout {
                        ForEach(Array(shown.enumerated()), id: \.element.name) { index, category in
                            chip(category)
                                .arrives(index: index)
                        }
                    }
                    .padding(.horizontal, Metrics.gutter)

                    if Self.showsExpandToggle(count: categories.count) {
                        StateAction(
                            title: showingAll ? "Show less" : "Show all \(categories.count)",
                            weight: .aside
                        ) {
                            Motion.run(.settle) { showingAll.toggle() }
                        }
                        .padding(.horizontal, Metrics.gutter)
                    }
                }
                .padding(.top, Metrics.sectionGap)
                .transition(.blurReplace)
            case .absent:
                // Nothing asked yet, or asked and MangaUpdates answered with zero
                // categories: not a failure, so no row at all.
                EmptyView()
            }
        }
        .animation(Motion.reduced(Motion.settle), value: state)
    }

    private var shown: [MangaUpdatesCategories.Category] {
        showingAll ? categories : Array(categories.prefix(Self.collapsedCount))
    }

    /// Which of the four sections a given state renders as — factored out
    /// so `DetailCategoriesTests` can assert the branch without building the
    /// view.
    enum SectionState: Equatable {
        case skeleton
        case failed
        case chips
        case absent
    }

    nonisolated static func state(
        categories: [MangaUpdatesCategories.Category], isLoading: Bool, failure: APIError?
    ) -> SectionState {
        if isLoading, categories.isEmpty, failure == nil { return .skeleton }
        if categories.isEmpty, failure != nil { return .failed }
        if !categories.isEmpty { return .chips }
        return .absent
    }

    private var header: some View {
        Text("What it's like · MangaUpdates")
            .typeDetailSectionHeader()
            .foregroundStyle(Palette.textPrimary)
            .padding(.horizontal, Metrics.gutter)
    }

    private func chip(_ category: MangaUpdatesCategories.Category) -> some View {
        Text(Self.chipLabel(category))
            .typeGridMeta()
            .foregroundStyle(Palette.textPrimary)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Palette.surface, in: Capsule())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Self.chipAccessibilityLabel(category))
    }

    /// Chip-shaped placeholders, in `FlowLayout`'s own layout, so nothing
    /// jumps when the real chips land — same reasoning as `CoverSkeletonRow`.
    private var skeleton: some View {
        FlowLayout {
            ForEach(0..<8, id: \.self) { index in
                Capsule()
                    .fill(Palette.surface)
                    // Varied widths so the row reads as chips of text about
                    // to arrive rather than a repeating rendering artefact.
                    .frame(width: 56 + CGFloat(index % 3) * 22, height: 28)
            }
        }
        .padding(.horizontal, Metrics.gutter)
        .shimmering()
        .accessibilityHidden(true)
    }
}
