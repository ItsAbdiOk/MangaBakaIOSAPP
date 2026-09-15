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

    /// **Two tab-bar behaviours the walks reported are iOS 26's, not ours,
    /// and are deliberately not fought (2026-09-14).**
    ///
    /// 1. *It collapses to two circles.* Screenshots from two independent
    ///    walks show the four-tab capsule replaced by the current tab's icon
    ///    alone plus the search circle, in the same y-band — a different
    ///    rendering, not a clipped or scrolled one. That is the system's
    ///    Liquid Glass tab bar minimising on scroll. Nothing below sets
    ///    `tabViewStyle` or `tabBarMinimizeBehavior`, so what is on screen is
    ///    the platform default, and every other iOS 26 app does the same
    ///    thing. `.tabBarMinimizeBehavior(.never)` would switch it off; that
    ///    is a product call about matching the platform, not a defect, and it
    ///    is left alone.
    /// 2. *A scroll starting low on screen is swallowed and lands on another
    ///    tab.* The bar is the system's own, fixed to the window with its own
    ///    hit area, and a touch that begins inside it belongs to it. There is
    ///    no supported way to make a system tab bar forward a drag to the
    ///    content behind it, and a hand-drawn capsule was already tried and
    ///    removed (see `RootView`'s doc comment) — it cost per-tab navigation
    ///    stacks, lazy loading and state restoration.
    ///
    /// Recorded here rather than in a report so the next person to meet
    /// either does not re-derive it. `Metrics.scrollBottomInset` carries the
    /// related unresolved question about how much padding this bar needs.
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
                        library: library,
                        libraryStore: session.library
                    )
                    .navigationDestination(for: Series.self) { detail($0, path: $searchPath) }
                    .navigationDestination(isPresented: $showsBrowse) {
                        BrowseDestination(
                            model: browseModel,
                            blocked: blockedTags,
                            catalogue: catalogue,
                            onPick: { pick in
                                searchModel.applyBrowse(
                                    genre: pick.genre,
                                    tag: pick.tag,
                                    publisher: pick.publisher
                                )
                                showsBrowse = false
                            },
                            onOpenTagTree: { showsTagTree = true }
                        )
                    }
                    .sheet(isPresented: $showsTagTree) { tagTreeSheet }
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

    /// The tag tree, in a sheet with an untyped stack of its own so `Tag`
    /// levels can push. A series tapped inside lands on the search stack
    /// (`path: $searchPath`) *behind* the sheet, so the sheet closes the
    /// moment that path grows — the detail is then the top of the screen.
    private var tagTreeSheet: some View {
        NavigationStack {
            TagTreeView(model: TagTreeModel(), repository: repository, path: $searchPath)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { showsTagTree = false }
                    }
                }
        }
        .onChange(of: searchPath.count) { before, after in
            if after > before { showsTagTree = false }
        }
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
            showsTagTree = false
        }
    }
}
