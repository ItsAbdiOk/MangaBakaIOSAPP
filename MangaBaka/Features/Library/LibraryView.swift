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
    let onOpenWrapped: () -> Void
    private let onOpenShelf: (LibraryEntry.State) -> Void
    private let onOpenSettings: () -> Void
    private let onOpenStack: () -> Void
    /// Saves an edit made from a row; returns a message when it failed.
    private let onSave: (Int, LibraryChange) async -> String?
    // Optional: LibraryModel has no repository of its own to build this from
    // (it talks to `LibraryProviding`, not `SeriesRepositoryProtocol`), so the
    // caller builds one and hands it in. The row hides itself when this is nil.
    private let continuations: ContinuationsModel?
    @State private var editing: LibraryEntry?

    init(
        model: LibraryModel,
        path: Binding<[Series]>,
        scheduleSummary: String?,
        onOpenSchedule: @escaping () -> Void,
        onOpenTaste: @escaping () -> Void,
        onOpenWrapped: @escaping () -> Void,
        onOpenShelf: @escaping (LibraryEntry.State) -> Void,
        onOpenSettings: @escaping () -> Void,
        onOpenStack: @escaping () -> Void,
        onSave: @escaping (Int, LibraryChange) async -> String? = { _, _ in nil },
        continuations: ContinuationsModel? = nil
    ) {
        self.model = model
        _path = path
        self.scheduleSummary = scheduleSummary
        self.onOpenSchedule = onOpenSchedule
        self.onOpenTaste = onOpenTaste
        self.onOpenWrapped = onOpenWrapped
        self.onOpenShelf = onOpenShelf
        self.onOpenSettings = onOpenSettings
        self.onOpenStack = onOpenStack
        self.onSave = onSave
        self.continuations = continuations
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
                switch model.screenState {
                case .loading:
                    loading
                case .noAccount:
                    noAccount
                case let .failed(error):
                    FailureState(
                        error: error,
                        retry: { await model.reload() },
                        openSettings: onOpenSettings
                    )
                    .padding(.top, 80)
                case .empty:
                    emptyLibrary
                case .list:
                    LibraryFilterRow(
                        shape: model.shape,
                        total: model.allCount,
                        selected: $model.filter
                    )
                    .padding(.top, 14)

                    LibraryShapeBar(counts: model.shape, selected: $model.filter)
                        .padding(.horizontal, Metrics.gutter)
                        .padding(.top, 16)

                    if !model.isComplete {
                        partialLoad
                    }

                    // The shelf on its own page, once a state is picked.
                    // The shelf screen has the filters the list does not —
                    // "has a note", "never rated", "left before chapter
                    // 10" — and until now nothing opened it.
                    if let state = model.filter {
                        Button { onOpenShelf(state) } label: {
                            HStack(spacing: 4) {
                                Text("Open the \(state.title) shelf")
                                    .typeInstruction()
                                    .foregroundStyle(Palette.accent)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(Palette.accent)
                            }
                            .frame(minHeight: Metrics.headerPill)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.press)
                        .padding(.horizontal, Metrics.gutter)
                        .accessibilityHint("Opens this shelf on its own page, with more filters")
                    }

                    // Kept above the list even though the board does not draw
                    // them: they are the only route to the schedule and the
                    // taste screen, and the board was not told those screens
                    // exist.
                    if !model.isSearching && model.filter == nil {
                        scheduleCard
                        tasteCard
                        wrappedCard
                        PickBackUp(entries: model.inProgress, path: $path)
                        if let continuations {
                            ContinuationsRow(
                                items: continuations.items,
                                isLoading: continuations.isLoading,
                                path: $path
                            )
                            .task(id: model.entries.map(\.id)) {
                                await continuations.load(entries: model.entries)
                            }
                        }
                    }

                    LibraryList(model: model, path: $path, onEdit: { editing = $0 })
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
        // The list beneath changed. Chips, the shape bar and the sort menu all
        // write these two, so this covers all three controls.
        .sensoryFeedback(Haptics.selection, trigger: model.filter)
        .sensoryFeedback(Haptics.selection, trigger: model.sort)
        .sheet(item: $editing) { entry in
            if let series = entry.series {
                LibraryEditSheet(entry: entry, series: series) { change in
                    await onSave(entry.seriesId, change)
                }
            }
        }
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
            .buttonStyle(.press)
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

    /// Rows in the list's own shape, shimmering, rather than a spinner: the
    /// first page lands in a third of a second and the layout must not jump.
    private var loading: some View {
        VStack(spacing: 0) {
            ForEach(0..<6, id: \.self) { index in
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Palette.imagePlaceholder)
                        .frame(width: 38, height: 38 / Metrics.coverAspect)
                    VStack(alignment: .leading, spacing: 8) {
                        Capsule().fill(Palette.surface)
                            .frame(width: index.isMultiple(of: 2) ? 180 : 130, height: 11)
                        Capsule().fill(Palette.surface)
                            .frame(width: 80, height: 9)
                    }
                    Spacer()
                }
                .padding(.vertical, 10)
            }
        }
        .padding(.horizontal, Metrics.gutter)
        .padding(.top, 24)
        .shimmering()
        .accessibilityHidden(true)
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
