import SwiftUI

/// The tab shell.
///
/// Glass appears on the tab bar and nowhere that scrolls — the spec limits it
/// deliberately, and live blur under a moving cover feed is expensive on both
/// GPU and battery.
struct RootView: View {
    let repository: SeriesRepository
    let shelf: ShelfStore
    let client: APIClient
    let content: ContentPreferencesStore
    let formats: FormatPreferencesStore
    let library: LibraryService

    @State private var selection: AppTab = .discover
    @State private var discoverPath: [Series] = []
    @State private var stackPath: [Series] = []
    @State private var shelfPath: [Series] = []
    @State private var searchPath: [Series] = []
    @State private var mixPath: [Series] = []
    @State private var searchModel: SearchModel?
    @State private var mixModel: MixModel?

    /// Named AppTab, not Tab: SwiftUI's own Tab view is used below and the two
    /// names collide.
    enum AppTab: Hashable, CaseIterable {
        case discover, stack, search, mix, shelf

        var title: String {
            switch self {
            case .discover: "Discover"
            case .stack: "Stack"
            case .search: "Search"
            case .mix: "Mix"
            case .shelf: "Shelf"
            }
        }

        var symbol: String {
            switch self {
            case .discover: "square.grid.2x2"
            case .stack: "rectangle.portrait.on.rectangle.portrait"
            case .search: "magnifyingglass"
            case .mix: "wand.and.sparkles"
            case .shelf: "bookmark"
            }
        }
    }

    var body: some View {
        TabView(selection: $selection) {
            Tab(AppTab.discover.title, systemImage: AppTab.discover.symbol, value: AppTab.discover) {
                NavigationStack(path: $discoverPath) {
                    DiscoverView(
                        model: DiscoverModel(repository: repository),
                        path: $discoverPath
                    )
                    .navigationDestination(for: Series.self) { detail($0, path: $discoverPath) }
                }
            }
            Tab(AppTab.stack.title, systemImage: AppTab.stack.symbol, value: AppTab.stack) {
                NavigationStack(path: $stackPath) {
                    StackView(
                        model: StackModel(
                            repository: repository,
                            shelf: shelf,
                            library: library
                        ),
                        path: $stackPath
                    )
                    .navigationDestination(for: Series.self) { detail($0, path: $stackPath) }
                }
            }
            Tab(AppTab.search.title, systemImage: AppTab.search.symbol, value: AppTab.search) {
                NavigationStack(path: $searchPath) {
                    SearchView(
                        model: searchModel ?? SearchModel(repository: repository),
                        path: $searchPath
                    )
                    .navigationDestination(for: Series.self) { detail($0, path: $searchPath) }
                }
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
            }
            Tab(AppTab.shelf.title, systemImage: AppTab.shelf.symbol, value: AppTab.shelf) {
                NavigationStack(path: $shelfPath) {
                    ShelfView(shelf: shelf, path: $shelfPath)
                        .navigationDestination(for: Series.self) { detail($0, path: $shelfPath) }
                        .toolbar {
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
            }
        }
        .task {
            // Created once and kept: rebuilding them per tab switch would drop
            // a half-typed query or an assembled set of mix seeds.
            if searchModel == nil { searchModel = SearchModel(repository: repository) }
            if mixModel == nil { mixModel = MixModel(repository: repository, shelf: shelf) }
        }
        .tint(Palette.accent)
        .preferredColorScheme(.dark)
        // The tab bar floats over content. Reserving its height as safe area
        // is what keeps the last row of every screen reachable; a hard-coded
        // bottom padding would be wrong on any device it was not measured on.
        .tabBarMinimizeBehavior(.onScrollDown)
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
