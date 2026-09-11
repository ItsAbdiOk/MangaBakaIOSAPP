import SwiftUI

/// The app with Apple's own chrome.
///
/// A plain `TabView` with the system tab bar visible, and a real
/// `NavigationStack` with a real navigation bar behind every tab. The shipping
/// app hides the system bar and draws a floating capsule to the mockup's
/// design; this shows what is underneath.
///
/// **The point of the branch, in Abdi's words:** when iOS 26 shipped, apps
/// using Apple's own navigation bar got Liquid Glass for free. This is the
/// version that inherits those upgrades.
struct AppleRootView: View {
    let repository: SeriesRepository
    let session: SessionModels
    let content: ContentPreferencesStore
    let formats: FormatPreferencesStore

    @State private var discoverPath: [Series] = []
    @State private var libraryPath: [Series] = []
    @State private var titleRevision = 0

    var body: some View {
        TabView {
            Tab("Discover", systemImage: "sparkles") {
                NavigationStack(path: $discoverPath) {
                    AppleDiscoverView(
                        model: DiscoverModel(repository: repository),
                        path: $discoverPath
                    )
                    .navigationDestination(for: Series.self) { series in
                        AppleSeriesDetailView(series: series)
                    }
                }
            }
            Tab("Library", systemImage: "books.vertical") {
                NavigationStack(path: $libraryPath) {
                    AppleLibraryView(model: session.library, path: $libraryPath)
                        .navigationDestination(for: Series.self) { series in
                            AppleSeriesDetailView(series: series)
                        }
                }
            }
            Tab("Settings", systemImage: "gearshape") {
                NavigationStack {
                    AppleSettingsView(
                        content: content,
                        formats: formats,
                        titleRevision: $titleRevision
                    )
                }
            }
        }
        // Kept, because it is the one piece of the shipping app's chrome that
        // IS Apple's: the floating bar minimising as you scroll.
        .tabBarMinimizeBehavior(.onScrollDown)
    }
}
