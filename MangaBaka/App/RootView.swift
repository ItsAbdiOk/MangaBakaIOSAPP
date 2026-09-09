import SwiftUI

/// The tab shell.
///
/// The mockup replaces the system tab bar with a floating capsule of four tabs
/// and a separate search button. A real `TabView` still runs underneath with
/// its own bar hidden, so per-tab navigation stacks, lazy loading and state
/// restoration all keep working; `AppTabBar` only draws over it and drives the
/// selection. Rebuilding tab switching by hand would have traded all of that
/// away for a visual change.
struct RootView: View {
    let repository: SeriesRepository
    let shelf: ShelfStore
    let client: APIClient
    let content: ContentPreferencesStore
    let formats: FormatPreferencesStore
    let library: LibraryService
    let schedule: ReleaseScheduleService
    let catalogue: CatalogueService
    let blockedTags: BlockedTagsStore

    @State private var selection: AppTab = .discover
    @State private var discoverPath: [Series] = []
    @State private var stackPath: [Series] = []
    @State private var shelfPath: [Series] = []
    @State private var showsSchedule = false
    @State private var showsTaste = false
    @State private var libraryModel: LibraryModel?
    @State private var openShelf: LibraryModel.Shelf?
    @State private var searchPath: [Series] = []
    @State private var mixPath: [Series] = []
    @State private var searchModel: SearchModel?
    @State private var browseModel: BrowseModel?
    @State private var showsBrowse = false
    @State private var mixModel: MixModel?
    @State private var cacheAge: TimeInterval?

    /// Named AppTab, not Tab: SwiftUI's own Tab view is used below and the two
    /// names collide.
    enum AppTab: Hashable, CaseIterable {
        case discover, stack, mix, library, search

        var title: String {
            switch self {
            case .discover: "Discover"
            case .stack: "Stack"
            case .mix: "Mix"
            // The mockup's fourth tab. It still shows the local shelf until the
            // designed Library screen is built, so the label leads and the
            // contents follow rather than the other way round.
            case .library: "Library"
            case .search: "Search"
            }
        }

        /// Chosen to read like the mockup's line-art glyphs.
        var symbol: String {
            switch self {
            case .discover: "circle.circle"
            case .stack: "line.3.horizontal"
            case .mix: "circle.on.circle"
            case .library: "chart.bar.fill"
            case .search: "magnifyingglass"
            }
        }
    }

    var body: some View {
        TabView(selection: $selection) {
            Tab(AppTab.discover.title, systemImage: AppTab.discover.symbol, value: AppTab.discover) {
                NavigationStack(path: $discoverPath) {
                    DiscoverView(
                        model: DiscoverModel(repository: repository),
                        path: $discoverPath,
                        onOpenStack: { selection = .stack }
                    )
                    .navigationDestination(for: Series.self) { detail($0, path: $discoverPath) }
                }
                .toolbar(.hidden, for: .tabBar)
            }
            Tab(AppTab.stack.title, systemImage: AppTab.stack.symbol, value: AppTab.stack) {
                NavigationStack(path: $stackPath) {
                    StackView(
                        model: StackModel(repository: repository, shelf: shelf, library: library),
                        path: $stackPath,
                        onOpenShelf: { selection = .library }
                    )
                    .navigationDestination(for: Series.self) { detail($0, path: $stackPath) }
                }
                .toolbar(.hidden, for: .tabBar)
            }
            Tab(AppTab.mix.title, systemImage: AppTab.mix.symbol, value: AppTab.mix) {
                NavigationStack(path: $mixPath) {
                    MixView(
                        model: mixModel ?? MixModel(repository: repository, shelf: shelf),
                        path: $mixPath,
                        // Picking a seed is a search, so send the reader to the
                        // screen that already does that well rather than
                        // building a second, worse picker inside Mix.
                        onPickSeed: { selection = .search }
                    )
                    .navigationDestination(for: Series.self) { detail($0, path: $mixPath) }
                }
                .toolbar(.hidden, for: .tabBar)
            }
            Tab(AppTab.library.title, systemImage: AppTab.library.symbol, value: AppTab.library) {
                NavigationStack(path: $shelfPath) {
                    LibraryView(
                        model: libraryModel ?? LibraryModel(library: library),
                        path: $shelfPath,
                        scheduleSummary: nil,
                        onOpenSchedule: { showsSchedule = true },
                        onOpenTaste: { showsTaste = true },
                        onOpenShelf: { state in
                            openShelf = libraryModel?.shelves.first { $0.state == state }
                        }
                    )
                        .navigationDestination(for: Series.self) { detail($0, path: $shelfPath) }
                        .navigationDestination(item: $openShelf) { shelf in
                            ShelfDetailView(
                                shelf: shelf,
                                path: $shelfPath,
                                onSave: saveLibraryChange
                            )
                        }
                        .navigationDestination(isPresented: $showsTaste) {
                            TasteView(
                                model: TasteModel(library: library),
                                entries: libraryModel?.entries ?? []
                            )
                        }
                        .navigationDestination(isPresented: $showsSchedule) {
                            ScheduleView(
                                model: ScheduleModel(service: schedule),
                                path: $shelfPath
                            )
                        }
                        .toolbar {
                            ToolbarItem(placement: .topBarLeading) {
                                Button { showsSchedule = true } label: {
                                    Image(systemName: "calendar")
                                }
                                .accessibilityLabel("Next chapters")
                            }
                            ToolbarItem(placement: .topBarTrailing) {
                                NavigationLink {
                                    SettingsView(
                                        validate: validateToken,
                                        content: content,
                                        formats: formats
                                    )
                                } label: {
                                    Image(systemName: "gearshape")
                                }
                            }
                        }
                }
                .toolbar(.hidden, for: .tabBar)
            }
            Tab(AppTab.search.title, systemImage: AppTab.search.symbol, value: AppTab.search) {
                NavigationStack(path: $searchPath) {
                    SearchView(
                        model: searchModel ?? SearchModel(repository: repository),
                        path: $searchPath,
                        onBrowse: { showsBrowse = true }
                    )
                    .navigationDestination(for: Series.self) { detail($0, path: $searchPath) }
                    .navigationDestination(isPresented: $showsBrowse) {
                        BrowseView(
                            model: browseModel ?? BrowseModel(catalogue: catalogue),
                            blocked: blockedTags,
                            onPickGenre: { genre in
                                searchModel?.applyBrowse(genre: genre.value)
                                showsBrowse = false
                            },
                            onPickTag: { tag in
                                searchModel?.applyBrowse(tag: tag.name)
                                showsBrowse = false
                            }
                        )
                    }
                }
                .toolbar(.hidden, for: .tabBar)
            }
        }
        // Hidden on each tab's CONTENT, not on the TabView. Applied to the
        // TabView it silently does nothing, which left the system bar mounted
        // underneath the capsule: two tab bars, both live, and taps near the
        // search button landing in the gap between them.
        .overlay(alignment: .bottom) {
            AppTabBar(
                selection: $selection,
                isSearching: selection == .search,
                onSearch: { selection = .search },
                onReselect: popToRoot
            )
        }
        .overlay(alignment: .top) {
            // Only at a tab's root. The bar is drawn over everything, so on a
            // pushed screen it sat on top of the navigation bar and hid its
            // back button — leaving an edge-swipe as the only way out.
            if isAtRoot {
                AppTopBar(cacheAge: cacheAge)
            }
        }
        .task {
            // Created once and kept: rebuilding them per tab switch would drop
            // a half-typed query or an assembled set of mix seeds.
            if searchModel == nil { searchModel = SearchModel(repository: repository) }
            if mixModel == nil { mixModel = MixModel(repository: repository, shelf: shelf) }
            if libraryModel == nil { libraryModel = LibraryModel(library: library) }
            if browseModel == nil { browseModel = BrowseModel(catalogue: catalogue) }
        }
        .task {
            // Nothing is cached when the app opens — the first feed has not
            // landed yet — so a single read at launch always found nothing and
            // the pill never appeared. This re-reads as feeds arrive and as the
            // age ticks over. One indexed MAX() every half minute.
            while !Task.isCancelled {
                await refreshCacheAge()
                try? await Task.sleep(for: .seconds(30))
            }
        }
        .onChange(of: selection) { _, _ in
            Task { await refreshCacheAge() }
        }
        .tint(Palette.accent)
        .preferredColorScheme(.dark)
    }

    /// Whether the selected tab is showing its root screen.
    private var isAtRoot: Bool {
        switch selection {
        case .discover: discoverPath.isEmpty
        case .stack: stackPath.isEmpty
        case .mix: mixPath.isEmpty
        // The shelf and schedule screens are pushed by their own bindings
        // rather than onto shelfPath, so checking the path alone reported
        // "at root" while a screen was open — and the top bar covered its
        // back button.
        case .library:
            shelfPath.isEmpty && openShelf == nil && !showsSchedule && !showsTaste
        case .search: searchPath.isEmpty && !showsBrowse
        }
    }

    /// Tapping the current tab returns to its root.
    private func popToRoot(_ tab: AppTab) {
        switch tab {
        case .discover: discoverPath.removeAll()
        case .stack: stackPath.removeAll()
        case .mix: mixPath.removeAll()
        case .library:
            shelfPath.removeAll()
            openShelf = nil
            showsSchedule = false
            showsTaste = false
        case .search:
            searchPath.removeAll()
            showsBrowse = false
        }
    }

    /// Writes a change to the reader's real library, then re-reads so the
    /// screen shows what the server now holds rather than what was typed.
    private func saveLibraryChange(seriesId: Int, change: LibraryChange) async -> String? {
        do {
            try await library.update(seriesId: seriesId, change: change)
        } catch {
            return error.userFacingMessage
        }
        await libraryModel?.reload()
        openShelf = libraryModel?.shelves.first { $0.state == openShelf?.state }
        return nil
    }

    private func refreshCacheAge() async {
        guard let newest = await repository.newestCacheDate() else {
            cacheAge = nil
            return
        }
        cacheAge = Date().timeIntervalSince(newest)
    }

    private func detail(_ series: Series, path: Binding<[Series]>) -> some View {
        SeriesDetailView(series: series, repository: repository, path: path)
    }

    /// Confirms a token by asking MangaBaka who it belongs to. A name coming
    /// back proves the token works.
    ///
    /// The client resolves credentials per request, and Settings writes to the
    /// Keychain before calling this, so the token under test is the one used.
    private func validateToken(_ token: String) async -> String? {
        await client.profile()?.displayName
    }
}
