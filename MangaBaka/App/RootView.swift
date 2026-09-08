import SwiftUI

/// The tab shell.
///
/// Glass appears on the tab bar and nowhere that scrolls — the spec limits it
/// deliberately, and live blur under a moving cover feed is expensive on both
/// GPU and battery.
struct RootView: View {
    let repository: SeriesRepository
    let shelf: ShelfStore

    @State private var selection: AppTab = .discover
    @State private var discoverPath: [Series] = []
    @State private var stackPath: [Series] = []
    @State private var shelfPath: [Series] = []

    /// Named AppTab, not Tab: SwiftUI's own Tab view is used below and the two
    /// names collide.
    enum AppTab: Hashable, CaseIterable {
        case discover, stack, shelf

        var title: String {
            switch self {
            case .discover: "Discover"
            case .stack: "Stack"
            case .shelf: "Shelf"
            }
        }

        var symbol: String {
            switch self {
            case .discover: "square.grid.2x2"
            case .stack: "rectangle.portrait.on.rectangle.portrait"
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
                        model: StackModel(repository: repository, shelf: shelf),
                        path: $stackPath
                    )
                    .navigationDestination(for: Series.self) { detail($0, path: $stackPath) }
                }
            }
            Tab(AppTab.shelf.title, systemImage: AppTab.shelf.symbol, value: AppTab.shelf) {
                NavigationStack(path: $shelfPath) {
                    ShelfView(shelf: shelf, path: $shelfPath)
                        .navigationDestination(for: Series.self) { detail($0, path: $shelfPath) }
                }
            }
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
}
