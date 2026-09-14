import SwiftUI

/// The tab tree itself: the five tabs, the selection binding that also handles
/// a re-tap, and what a re-tap pops.
///
/// Its own file for the lint's type-body ceiling. `RootView` carries twenty-eight
/// dependencies, six session-lived models built in its `init` (item 61) and the
/// launch/link/foreground handlers in `body`; the tab tree is the one part of it
/// that reads as a complete idea on its own — the same reason
/// `RootView+Session.swift` and `RootView+Failures.swift` exist.
///
/// The members reached from here are internal rather than private for exactly
/// that reason, and for no other.
extension RootView {
    /// The tab selection, with a re-tap of the current tab popping it to its
    /// root. `TabView` reports a change of selection and nothing on a re-tap,
    /// so the binding's setter is where the re-tap is seen: same value in,
    /// pop. `popToRoot` had sat under a comment describing this behaviour
    /// with no caller for it.
    var tabSelection: Binding<AppTab> {
        Binding(
            get: { selection },
            set: { tab in
                if tab == selection { popToRoot(tab) }
                selection = tab
            }
        )
    }

    var tabs: some View {
        TabView(selection: tabSelection) {
            Tab(AppTab.discover.title, systemImage: AppTab.discover.symbol, value: AppTab.discover) {
                NavigationStack(path: $discoverPath) {
                    DiscoverView(
                        model: discoverModel,
                        inProgress: session.library.inProgress,
                        recentlyViewed: session.recentlyViewed,
                        path: $discoverPath,
                        pulse: session.pulse,
                        // Item 106: this used to reduce all ~939 entries on
                        // every body pass — every toast, every selection, every
                        // path change. `LibraryModel` recomputes it when
                        // `entries` changes and at no other time.
                        chaptersRead: session.library.chaptersRead,
                        whatsNew: whatsNew,
                        hasCompletedOnboarding: onboarding.hasCompleted
                    )
                    .navigationDestination(for: Series.self) { detail($0, path: $discoverPath) }
                }
            }
            Tab(AppTab.stack.title, systemImage: AppTab.stack.symbol, value: AppTab.stack) {
                NavigationStack(path: $stackPath) {
                    StackView(
                        model: stackModel,
                        path: $stackPath,
                        onOpenShelf: { selection = .library },
                        onConfirm: { toasts.show($0) }
                    )
                    .navigationDestination(for: Series.self) { detail($0, path: $stackPath) }
                }
            }
            Tab(AppTab.mix.title, systemImage: AppTab.mix.symbol, value: AppTab.mix) {
                NavigationStack(path: $mixPath) {
                    MixView(
                        model: mixModel,
                        path: $mixPath,
                        // Picking a seed is a search, so send the reader to the
                        // screen that already does that well rather than
                        // building a second, worse picker inside Mix.
                        catalogue: catalogue,
                        lenses: lenses.value
                    )
                    .navigationDestination(for: Series.self) { detail($0, path: $mixPath) }
                }
            }
            libraryTab
            // `.search` is what renders it as the circle beside the capsule
            // rather than a fifth item inside it — the mockup's arrangement,
            // done by the system.
            Tab(
                AppTab.search.title,
                systemImage: AppTab.search.symbol,
                value: AppTab.search,
                role: .search
            ) {
                NavigationStack(path: $searchPath) {
                    SearchView(
                        model: searchModel,
                        path: $searchPath,
                        onBrowse: { showsBrowse = true },
                        lenses: lenses.value,
                        counts: session.counts,
                        catalogue: catalogue,
                        recents: recents.value,
                        library: library
                    )
                    .navigationDestination(for: Series.self) { detail($0, path: $searchPath) }
                    .navigationDestination(isPresented: $showsBrowse) {
                        BrowseDestination(
                            model: browseModel,
                            blocked: blockedTags,
                            catalogue: catalogue
                        ) { pick in
                            searchModel.applyBrowse(
                                genre: pick.genre,
                                tag: pick.tag,
                                publisher: pick.publisher
                            )
                            showsBrowse = false
                        }
                    }
                }
            }
        }
        // The system tab bar, not a drawing of one.
        //
        // This was hand-built to match the mockup's floating capsule plus a
        // detached search circle, with the real bar hidden underneath. On iOS 26
        // that is what the system bar already *is* — a floating glass capsule —
        // and `TabRole.search` is what detaches search from it. Hand-drawing it
        // cost the things Apple ships with it and nobody can reasonably rebuild:
        // the selection indicator that resizes to its label and slides between
        // tabs under a dragging finger, the scroll-away behaviour, and the
        // specular response of real Liquid Glass to what is behind it.
        .tabBarMinimizeBehavior(.onScrollDown)
        .toasts(toasts)
        // Also in the environment, so a control buried a long way down — the
        // copy-artwork menu on a character portrait — can confirm itself
        // without every view between here and it carrying the centre through.
        .environment(toasts)
        .task {
            // The six models themselves are built in `init` (item 61), so
            // there is nothing to create here. The reader's tags, for
            // ordering the stack's blends, are: this walks the library, so it
            // stays off the launch path.
            stackModel.ranker = await taste.ranker()
        }
        .tint(Palette.accent)
        .preferredColorScheme(.dark)
    }

    /// Tapping the current tab returns to its root.
    func popToRoot(_ tab: AppTab) {
        switch tab {
        case .discover: discoverPath.removeAll()
        case .stack: stackPath.removeAll()
        case .mix: mixPath.removeAll()
        case .library:
            shelfPath.removeAll()
            showsSchedule = false
            showsTaste = false
            showsWrapped = false
            showsSettings = false
        case .search:
            searchPath.removeAll()
            showsBrowse = false
        }
    }
}
