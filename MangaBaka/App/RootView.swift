import SwiftUI

/// The tab shell.
///
/// The mockup replaces the system tab bar with a floating capsule of four tabs
/// and a separate search button. A real `TabView` still runs underneath with
/// its own bar hidden, so per-tab navigation stacks, lazy loading and state
/// restoration all keep working; the system tab bar draws over it and drives the
/// selection. Rebuilding tab switching by hand would have traded all of that
/// away for a visual change.
struct RootView: View {
    let repository: SeriesRepository
    let shelf: ShelfStore
    let history: HistoryStore
    let client: APIClient
    let content: ContentPreferencesStore
    let formats: FormatPreferencesStore
    let library: LibraryService
    let schedule: ReleaseScheduleService
    let characters: CharacterService
    let taste: TasteProfile
    let catalogue: CatalogueService
    let blockedTags: BlockedTagsStore
    let lenses: SearchLensStore
    let recents: RecentSearches
    /// The models that live for the session rather than for a screen. Built in
    /// `MangaBakaApp` alongside everything else they depend on, rather than
    /// lazily here — a lazily-initialised @State plus an accessor, per model,
    /// is four things to read where there should be one.
    let session: SessionModels
    let onboarding: OnboardingState

    @State private var toasts = ToastCentre()
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
    /// The cover the detail page should grow out of, and the namespace the
    /// source and destination share. Nil falls back to an ordinary push.
    @State private var zoomSource: String?
    @Namespace private var coverTransition
    /// Real covers behind the first onboarding screen. Empty until the rising
    /// feed answers, which is the case the screen is built to survive.
    @State private var onboardingCovers: [Series] = []
    /// Whether Settings should open with the token field already focused.
    @State private var wantsAccountFocus = false

    var body: some View {
        tabs
            .task {
                guard !onboarding.hasCompleted, onboardingCovers.isEmpty else { return }
                onboardingCovers = await repository.feed(.rising, forceRefresh: false).series
            }
            .fullScreenCover(isPresented: .constant(!onboarding.hasCompleted)) {
                OnboardingView(
                    covers: onboardingCovers,
                    onFinish: { onboarding.complete() },
                    onConnectAccount: {
                        onboarding.complete()
                        selection = .library
                        wantsAccountFocus = true
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
                        recentlyViewed: session.recentlyViewed,
                        path: $discoverPath,
                        zoomSource: $zoomSource,
                        namespace: coverTransition,
                        onOpenStack: { selection = .stack }
                    )
                    .navigationDestination(for: Series.self) { detail($0, path: $discoverPath) }
                }
            }
            Tab(AppTab.stack.title, systemImage: AppTab.stack.symbol, value: AppTab.stack) {
                NavigationStack(path: $stackPath) {
                    StackView(
                        model: StackModel(repository: repository, shelf: shelf, library: library),
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
                        onOpenSettings: { showsSettings = true },
                        onOpenStack: { selection = .stack }
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
                                blockedTags: blockedTags,
                                catalogue: catalogue,
                                focusAccount: wantsAccountFocus,
                                history: history
                            )
                        }
                }
            }
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
                        model: searchModel ?? SearchModel(repository: repository),
                        path: $searchPath,
                        onBrowse: { showsBrowse = true },
                        lenses: lenses,
                        counts: session.counts,
                        catalogue: catalogue,
                        recents: recents
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
            taste: taste,
            contentRatings: content.preferences.allowed.map(\.rawValue),
            path: path,
            onUseAsSeed: { series in
                mixModel?.addSeed(series)
                selection = .mix
                toasts.show("Added to the mix")
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
        // Opening the page is what counts as having viewed it. Recorded here
        // rather than inside the detail view so every route into it — a feed,
        // the stack, search, a related-series row — is remembered the same way.
        .task { await session.recentlyViewed.record(series) }
        // Grows out of the cover that was tapped. Only Discover marks its
        // covers as sources so far; every other route falls through to the
        // ordinary push, which is what an unmatched id already does.
        .navigationTransition(.zoom(sourceID: zoomSource ?? "none", in: coverTransition))
    }

    /// Confirms a token by asking MangaBaka who it belongs to. A name coming
    /// back proves the token works.
    ///
    /// The client resolves credentials per request, and Settings writes to the
    /// Keychain before calling this, so the token under test is the one used.
    private func validateToken(_ token: String) async -> TokenCheck {
        do {
            return .accepted(try await client.verifiedProfile().displayName)
        } catch {
            // Only MangaBaka saying no means the token is bad. Everything else
            // is a statement about the network, and the token is still whatever
            // it was before the reader lost signal.
            return error.needsAccount ? .rejected : .unknown(error.userFacingMessage)
        }
    }
}
