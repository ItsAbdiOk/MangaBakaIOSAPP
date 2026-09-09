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
    let characters: ShikimoriClient
    let catalogue: CatalogueService
    let blockedTags: BlockedTagsStore
    let lenses: SearchLensStore
    let onboarding: OnboardingState

    @State private var selection: AppTab = .discover
    @State private var discoverPath: [Series] = []
    @State private var stackPath: [Series] = []
    @State private var shelfPath: [Series] = []
    @State private var showsSchedule = false
    @State private var showsTaste = false
    @State private var showsSettings = false
    @State private var libraryModel: LibraryModel?
    @State private var openShelf: LibraryModel.Shelf?
    @State private var searchPath: [Series] = []
    @State private var mixPath: [Series] = []
    @State private var searchModel: SearchModel?
    @State private var browseModel: BrowseModel?
    @State private var showsBrowse = false
    @State private var mixModel: MixModel?

    var body: some View {
        tabs
            .fullScreenCover(isPresented: .constant(!onboarding.hasCompleted)) {
                OnboardingView(
                    onFinish: { onboarding.complete() },
                    onConnectAccount: {
                        onboarding.complete()
                        selection = .library
                        showsSettings = true
                    }
                )
            }
    }

    private var tabs: some View {
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
                        },
                        onOpenSettings: { showsSettings = true }
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
                        .navigationDestination(isPresented: $showsSettings) {
                            SettingsView(
                                validate: validateToken,
                                content: content,
                                formats: formats,
                                blockedTags: blockedTags
                            )
                        }
                }
                .toolbar(.hidden, for: .tabBar)
            }
            Tab(AppTab.search.title, systemImage: AppTab.search.symbol, value: AppTab.search) {
                NavigationStack(path: $searchPath) {
                    SearchView(
                        model: searchModel ?? SearchModel(repository: repository),
                        path: $searchPath,
                        onBrowse: { showsBrowse = true },
                        lenses: lenses
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
        .task {
            // Created once and kept: rebuilding them per tab switch would drop
            // a half-typed query or an assembled set of mix seeds.
            if searchModel == nil { searchModel = SearchModel(repository: repository) }
            if mixModel == nil { mixModel = MixModel(repository: repository, shelf: shelf) }
            if libraryModel == nil { libraryModel = LibraryModel(library: library) }
            if browseModel == nil { browseModel = BrowseModel(catalogue: catalogue) }
        }
        .tint(Palette.accent)
        .preferredColorScheme(.dark)
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
            showsSettings = false
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

    private func detail(_ series: Series, path: Binding<[Series]>) -> some View {
        SeriesDetailView(
            series: series,
            repository: repository,
            library: library,
            libraryStore: libraryModel ?? LibraryModel(library: library),
            schedule: schedule,
            characters: characters,
            path: path,
            onUseAsSeed: { series in
                mixModel?.addSeed(series)
                selection = .mix
            },
            onOpenTag: { tag in
                searchModel?.query = SearchQuery(tags: [tag])
                Task { await searchModel?.search() }
                selection = .search
            },
            onOpenSchedule: {
                selection = .library
                showsSchedule = true
            }
        )
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
