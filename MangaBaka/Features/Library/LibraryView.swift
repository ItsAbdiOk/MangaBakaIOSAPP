import SwiftUI

/// The reader's own library: shelves, what is in progress, and a way into the
/// release schedule.
struct LibraryView: View {
    @Bindable private var model: LibraryModel
    @Binding private var path: [Series]
    private let scheduleSummary: String?
    private let onOpenSchedule: () -> Void
    private let onOpenTaste: () -> Void
    private let onOpenShelf: (LibraryEntry.State) -> Void
    private let onOpenSettings: () -> Void

    init(
        model: LibraryModel,
        path: Binding<[Series]>,
        scheduleSummary: String?,
        onOpenSchedule: @escaping () -> Void,
        onOpenTaste: @escaping () -> Void,
        onOpenShelf: @escaping (LibraryEntry.State) -> Void,
        onOpenSettings: @escaping () -> Void
    ) {
        self.model = model
        _path = path
        self.scheduleSummary = scheduleSummary
        self.onOpenSchedule = onOpenSchedule
        self.onOpenTaste = onOpenTaste
        self.onOpenShelf = onOpenShelf
        self.onOpenSettings = onOpenSettings
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                if !model.entries.isEmpty { searchField }
                if model.isLoading && model.entries.isEmpty {
                    loading
                } else if !model.hasAccount {
                    noAccount
                } else {
                    if model.isSearching {
                        searchResults
                    } else {
                        scheduleCard
                        tasteCard
                        PickBackUp(entries: model.inProgress, path: $path)
                        shelfCards
                    }
                    if let shape = model.shapeLine {
                        Text(shape)
                            .typeFootnote()
                            .foregroundStyle(Palette.textQuaternary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 20)
                            .padding(.top, 20)
                    }
                }
            }
            .padding(.top, Metrics.scrollTopInset)
            .padding(.bottom, Metrics.scrollBottomInset)
        }
        .scrollIndicators(.hidden)
        .background(Palette.ground)
        .task { await model.load() }
    }

    /// Settings sits here rather than in a navigation bar. The bar is empty on
    /// this screen — no title, no back button — so iOS collapses it to nothing
    /// and the gear went with it, which is how Settings became unreachable.
    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Library")
                    .typeScreenTitle()
                    .foregroundStyle(Palette.textEmphasis)
                Text(model.subtitle)
                    .typeSubtitle()
                    .foregroundStyle(Palette.textMuted)
            }
            Spacer(minLength: 0)
            Button(action: onOpenSettings) {
                Image(systemName: "gearshape")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Palette.textSecondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Settings")
        }
        .padding(.horizontal, Metrics.gutter)
    }

    /// Searching your own library, which at 937 entries is the difference
    /// between a list and an archive.
    private var searchField: some View {
        InlineSearchField(
            prompt: "Search \(model.total.formatted()) series",
            text: $model.searchText
        )
        .padding(.horizontal, Metrics.gutter)
        .padding(.top, 16)
    }

    /// Matching entries, still grouped by shelf so a result keeps its context.
    private var searchResults: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(model.matchCount == 0
                 ? "Nothing in your library matches"
                 : "\(model.matchCount) in your library")
                .typeSubsectionHeader()
                .foregroundStyle(Palette.textPrimary)
                .padding(.horizontal, Metrics.gutter)
                .padding(.bottom, 12)

            ForEach(model.visibleShelves) { shelf in
                Button { onOpenShelf(shelf.state) } label: {
                    ShelfCard(shelf: shelf)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, Metrics.gutter)
                .padding(.bottom, Metrics.gapCovers)
            }
        }
        .padding(.top, Metrics.sectionGap)
    }

    private var loading: some View {
        HStack {
            Spacer()
            ProgressView().tint(Palette.textTertiary)
            Spacer()
        }
        .padding(.top, 80)
    }

    private var noAccount: some View {
        EmptyState(
            title: "No library yet",
            message: """
            Add a MangaBaka token in Settings and everything you track there \
            appears here.
            """
        )
    }

    /// The way into the schedule, carrying its own summary so the card says
    /// something rather than just pointing.
    private var scheduleCard: some View {
        Button(action: onOpenSchedule) {
            HStack(spacing: 12) {
                Image(systemName: "calendar")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Palette.textPrimary)
                    .frame(width: 34, height: 34)
                    .background(Palette.surfacePill, in: RoundedRectangle(
                        cornerRadius: 11, style: .continuous
                    ))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Next chapters")
                        .typeRowTitle()
                        .foregroundStyle(Palette.textPrimary)
                    Text(scheduleSummary ?? "Estimate when each one is due")
                        .typeSmallMeta()
                        .foregroundStyle(Palette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.textQuaternary)
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 13)
            .background(Palette.surface, in: RoundedRectangle(
                cornerRadius: Metrics.radiusCard, style: .continuous
            ))
            .hairlineBorder(Palette.border, radius: Metrics.radiusCard)
            .contentShape(RoundedRectangle(cornerRadius: Metrics.radiusCard, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, Metrics.gutter)
        .padding(.top, 22)
    }

    private var tasteCard: some View {
        Button(action: onOpenTaste) {
            HStack(spacing: 12) {
                Image(systemName: "chart.bar.xaxis")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Palette.textPrimary)
                    .frame(width: 34, height: 34)
                    .background(Palette.surfacePill, in: RoundedRectangle(
                        cornerRadius: 11, style: .continuous
                    ))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Your taste")
                        .typeRowTitle()
                        .foregroundStyle(Palette.textPrimary)
                    Text("Counted from your own library")
                        .typeSmallMeta()
                        .foregroundStyle(Palette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.textQuaternary)
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 13)
            .background(Palette.surface, in: RoundedRectangle(
                cornerRadius: Metrics.radiusCard, style: .continuous
            ))
            .hairlineBorder(Palette.border, radius: Metrics.radiusCard)
            .contentShape(RoundedRectangle(cornerRadius: Metrics.radiusCard, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, Metrics.gutter)
        .padding(.top, Metrics.gapCovers)
    }

    private var shelfCards: some View {
        VStack(spacing: Metrics.gapCovers) {
            ForEach(model.shelves) { shelf in
                Button { onOpenShelf(shelf.state) } label: {
                    ShelfCard(shelf: shelf)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, Metrics.gutter)
        .padding(.top, Metrics.sectionGap)
    }
}
