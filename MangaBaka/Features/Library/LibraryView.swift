import SwiftUI

/// The reader's own library: shelves, what is in progress, and a way into the
/// release schedule.
struct LibraryView: View {
    @Bindable private var model: LibraryModel
    @Binding private var path: [Series]
    // Internal rather than private so the route cards can reach them. See
    // LibraryRouteCards.swift — the split is the lint's doing.
    let scheduleSummary: String?
    let onOpenSchedule: () -> Void
    let onOpenTaste: () -> Void
    private let onOpenShelf: (LibraryEntry.State) -> Void
    private let onOpenSettings: () -> Void
    private let onOpenStack: () -> Void

    init(
        model: LibraryModel,
        path: Binding<[Series]>,
        scheduleSummary: String?,
        onOpenSchedule: @escaping () -> Void,
        onOpenTaste: @escaping () -> Void,
        onOpenShelf: @escaping (LibraryEntry.State) -> Void,
        onOpenSettings: @escaping () -> Void,
        onOpenStack: @escaping () -> Void
    ) {
        self.model = model
        _path = path
        self.scheduleSummary = scheduleSummary
        self.onOpenSchedule = onOpenSchedule
        self.onOpenTaste = onOpenTaste
        self.onOpenShelf = onOpenShelf
        self.onOpenSettings = onOpenSettings
        self.onOpenStack = onOpenStack
    }

    var body: some View {
        ScrollViewReader { scroller in
            list
                .overlay(alignment: .trailing) {
                    if model.showsJumpIndex {
                        JumpIndex(targets: model.jumpTargets) { id in
                            Motion.run(.snappy(duration: 0.25)) {
                                scroller.scrollTo(id, anchor: .top)
                            }
                        }
                    }
                }
        }
    }

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                if !model.entries.isEmpty { searchField }
                if model.isLoading && model.entries.isEmpty {
                    loading
                } else if !model.hasAccount {
                    noAccount
                } else if model.entries.isEmpty {
                    emptyLibrary
                } else {
                    LibraryFilterRow(
                        shape: model.shape,
                        total: model.total,
                        selected: $model.filter
                    )
                    .padding(.top, 14)

                    LibraryShapeBar(counts: model.shape, selected: $model.filter)
                        .padding(.horizontal, Metrics.gutter)
                        .padding(.top, 16)

                    if !model.isComplete {
                        partialLoad
                    }

                    // Kept above the list even though the board does not draw
                    // them: they are the only route to the schedule and the
                    // taste screen, and the board was not told those screens
                    // exist.
                    if !model.isSearching && model.filter == nil {
                        scheduleCard
                        tasteCard
                        PickBackUp(entries: model.inProgress, path: $path)
                    }

                    LibraryList(model: model, path: $path)
                        .padding(.top, 22)
                }
            }
            .padding(.top, Metrics.scrollTopInset)
            .padding(.bottom, Metrics.scrollBottomInset)
        }
        .scrollIndicators(.hidden)
        .background(Palette.ground)
        .scrollEdge()
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

    /// Settings sits here rather than in a navigation bar.
    /// Nothing saved at all.
    ///
    /// No search field, no filter row, no shape bar — the board is explicit
    /// that those three arrive with the first entry, and it is right: three
    /// controls above an empty list are three ways to sort nothing.
    private var emptyLibrary: some View {
        EmptyState(
            title: "Nothing saved yet",
            message: """
            Swipe through the stack and anything you keep lands here, with a \
            reading state and a rating.
            """,
            actionTitle: "Open the stack",
            actionWeight: .fixes,
            action: onOpenStack
        )
    }

    /// Some of the library, and saying so.
    ///
    /// The board draws "500 of 1,204 loaded", and its own critique names the
    /// problem: that total comes from page one and never grows in front of the
    /// reader. So this states what is true — how many have arrived — and what
    /// follows from it, without a denominator it cannot stand behind.
    private var partialLoad: some View {
        HStack(spacing: 10) {
            ProgressView().tint(Palette.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(model.total.formatted()) loaded so far")
                    .typeRowTitle()
                    .foregroundStyle(Palette.textPrimary)
                Text("Counts and search cover what has arrived.")
                    .typeSmallMeta()
                    .foregroundStyle(Palette.textMuted)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Palette.surface, in: RoundedRectangle(
            cornerRadius: Metrics.radiusCard, style: .continuous
        ))
        .padding(.horizontal, Metrics.gutter)
        .padding(.top, 16)
    }

    /// Searching your own library, which at 937 entries is the difference
    /// between a list and an archive.
    private var searchField: some View {
        InlineSearchField(
            prompt: "Find in your library",
            text: $model.searchText
        )
        .padding(.horizontal, Metrics.gutter)
        .padding(.top, 16)
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

}
