import CoreSpotlight
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
    let appleBooks: AppleBooksClient
    let googleBooks: GoogleBooksClient
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
    let calendar: ReleaseCalendar
    let librarySnapshot: LibrarySnapshot
    let reminders: ReleaseReminders
    /// The library in iOS search. A struct with no state, so it is built here
    /// rather than passed through `AppServices`.
    let spotlight = SpotlightIndex()
    @State private var whatsNew = WhatsNewState()
    /// "More of what you finished" on the Library screen; see Continuations.
    @State var continuations: ContinuationsModel?
    /// A publisher or studio page, pushed from any series page. See
    /// `PublisherRoute`: the paths are [Series], so this rides beside them.
    @State var openPublisher: PublisherRoute?
    private let bridge = IntentBridge.shared
    let onboarding: OnboardingState

    @State private var toasts = ToastCentre()
    // Internal rather than private so the Library tab, which lives in
    // RootView+Session.swift, can reach them. The split is the lint's doing:
    // that one tab carries five destinations and was more than half this
    // type's body.
    @State var selection: AppTab = .discover
    @State var discoverPath: [Series] = []
    @State private var stackPath: [Series] = []
    @State var shelfPath: [Series] = []
    @State var showsSchedule = false
    @State var showsTaste = false
    @State var showsWrapped = false
    @State var showsSettings = false
    @State var openShelf: LibraryModel.Shelf?
    @State private var searchPath: [Series] = []
    @State private var mixPath: [Series] = []
    @State private var searchModel: SearchModel?
    @State private var browseModel: BrowseModel?
    @State private var showsBrowse = false
    @State private var mixModel: MixModel?
    /// Held here for the same reason as the three above, and for one more:
    /// the `.id(titleRevision)` on the tab tree rebuilds it when the title
    /// preference changes, and a model built inline in the body went with it
    /// — the stack's queue and its "seen this run" counts were reset by a
    /// display setting. Models above the `.id` survive it.
    @State private var discoverModel: DiscoverModel?
    @State private var stackModel: StackModel?
    /// The cover the detail page should grow out of, and the namespace the
    /// source and destination share. See `ZoomRoute`.
    @State private var zoomRoute = ZoomRoute()
    @Namespace private var coverTransition
    /// Real covers behind the first onboarding screen. Empty until the rising
    /// feed answers, which is the case the screen is built to survive.
    @State var onboardingCovers: [Series] = []
    /// Whether Settings should open with the token field already focused.
    @State var wantsAccountFocus = false
    /// Bumped when the title preference changes, so every screen redraws with
    /// the new names. Titles are read in a hundred places and changed roughly
    /// never; a version number is cheaper than making all of them observe.
    @State var titleRevision = 0

    var body: some View {
        tabs
            .id(titleRevision)
            // The one everybody expects. A re-tap pops to root and changes
            // nothing here, so it stays silent.
            .sensoryFeedback(Haptics.selection, trigger: selection)
            .environment(\.zoomNamespace, coverTransition)
            .environment(\.zoomRoute, zoomRoute)
            .task { await startSession() }
            // Primes `characters`' outage memory before any series page asks
            // for a cast, so the first one opened does not pay AniList's own
            // timeout before falling back to Shikimori. Its own detached
            // task, not folded into `startSession()`: that function's own
            // awaits (reminders, then Spotlight) are sequential, and this
            // check has no bearing on either — chaining it in front of them
            // would make a slow AniList delay work that does not depend on it.
            .task { await characters.primeAniListHealth() }
            // A library series tapped in Spotlight. The page opens in the
            // Library tab, which is where the reader's state on it lives.
            // "Open <series>" from Siri or Shortcuts; see IntentBridge.
            .task(id: bridge.pendingSeriesID) {
                guard let id = bridge.pendingSeriesID else { return }
                bridge.pendingSeriesID = nil
                await openSeries(id: id)
            }
            // A mangabaka.org series link. Dormant until the site hosts the
            // association file; see SeriesWebLink.
            .onOpenURL { url in
                guard let id = SeriesWebLink.seriesID(from: url) else { return }
                Task { await openSeries(id: id) }
            }
            .onContinueUserActivity(CSSearchableItemActionType) { activity in
                guard let id = SpotlightIndex.seriesID(from: activity) else { return }
                Task { await openFromSpotlight(seriesID: id) }
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

    /// The tab selection, with a re-tap of the current tab popping it to its
    /// root. `TabView` reports a change of selection and nothing on a re-tap,
    /// so the binding's setter is where the re-tap is seen: same value in,
    /// pop. `popToRoot` had sat under a comment describing this behaviour
    /// with no caller for it.
    private var tabSelection: Binding<AppTab> {
        Binding(
            get: { selection },
            set: { tab in
                if tab == selection { popToRoot(tab) }
                selection = tab
            }
        )
    }

    private var tabs: some View {
        TabView(selection: tabSelection) {
            Tab(AppTab.discover.title, systemImage: AppTab.discover.symbol, value: AppTab.discover) {
                NavigationStack(path: $discoverPath) {
                    DiscoverView(
                        model: discoverModel ?? DiscoverModel(repository: repository),
                        recentlyViewed: session.recentlyViewed,
                        path: $discoverPath,
                        pulse: session.pulse,
                        chaptersRead: ReadingInsights.chaptersRead(in: session.library.entries),
                        whatsNew: whatsNew,
                        hasCompletedOnboarding: onboarding.hasCompleted,
                        onOpenStack: { selection = .stack }
                    )
                    .navigationDestination(for: Series.self) { detail($0, path: $discoverPath) }
                }
            }
            Tab(AppTab.stack.title, systemImage: AppTab.stack.symbol, value: AppTab.stack) {
                NavigationStack(path: $stackPath) {
                    StackView(
                        model: stackModel
                            ?? StackModel(repository: repository, shelf: shelf, library: library),
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
                        catalogue: catalogue,
                        lenses: lenses
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
                        BrowseDestination(
                            model: browseModel ?? BrowseModel(catalogue: catalogue),
                            blocked: blockedTags,
                            catalogue: catalogue
                        ) { pick in
                            searchModel?.applyBrowse(
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
            // Created once and kept: rebuilding them per tab switch would drop
            // a half-typed query or an assembled set of mix seeds.
            if searchModel == nil { searchModel = SearchModel(repository: repository) }
            if mixModel == nil { mixModel = MixModel(repository: repository, shelf: shelf) }
            if browseModel == nil { browseModel = BrowseModel(catalogue: catalogue) }
            if discoverModel == nil { discoverModel = DiscoverModel(repository: repository) }
            if continuations == nil { continuations = ContinuationsModel(repository: repository) }
            if stackModel == nil {
                stackModel = StackModel(repository: repository, shelf: shelf, library: library)
            }
            // The reader's tags, for ordering the stack's blends. After the
            // models exist, and off the launch path: it walks the library.
            stackModel?.ranker = await taste.ranker()
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
            showsWrapped = false
            showsSettings = false
        case .search:
            searchPath.removeAll()
            showsBrowse = false
        }
    }

    func detail(_ series: Series, path: Binding<[Series]>) -> some View {
        SeriesDetailView(
            series: series,
            repository: repository,
            library: library,
            libraryStore: session.library,
            schedule: schedule,
            characters: characters,
            taste: taste,
            appleBooks: appleBooks,
            googleBooks: googleBooks,
            onOpenPublisher: { openPublisher = PublisherRoute(name: $0, kind: .publisher) },
            onOpenAuthor: { openPublisher = PublisherRoute(name: $0, kind: .author) },
            contentRatings: content.preferences.allowed.map(\.rawValue),
            path: path,
            onUseAsSeed: { series in
                mixModel?.addSeed(series)
                selection = .mix
                toasts.show("Added to the mix")
            },
            onOpenTag: { tag in
                // `applyBrowse`, not a raw assignment plus `search()`. Tapping
                // a tag is the same gesture as picking one on the browse
                // screen, and that method is what it is for: it remembers the
                // text it applied so the field's own change observer does not
                // schedule a second, identical request 300ms later (two calls
                // per tap against a 30 req/min budget shared with everyone on
                // the same network — see `SearchModel.queryDidChange`), it
                // cancels any keystroke debounce already pending, and it sets
                // a stable sort. The sort matters beyond tidiness: without one
                // the API is free to reorder between pages, and this app pages
                // by asking for page 2 and dropping ids it has already seen.
                searchModel?.applyBrowse(tag: tag)
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
        // The publisher page, pushed on whichever stack this page is in. A
        // series it lists pushes back onto the same path.
        .navigationDestination(item: $openPublisher) { route in
            PublisherView(
                name: route.name, kind: route.kind, catalogue: catalogue,
                repository: repository, path: path
            )
        }
        // Grows out of the cover that was tapped. Every screen that pushes a
        // series marks its covers with `.zoomSource`; a route that did not
        // falls through to the ordinary push, which is what an unmatched id
        // already does.
        .navigationTransition(.zoom(sourceID: zoomRoute.source ?? "none", in: coverTransition))
    }

    /// Confirms a token by asking MangaBaka who it belongs to. A name coming
    /// back proves the token works.
    ///
    /// The client resolves credentials per request, and Settings writes to the
    /// Keychain before calling this, so the token under test is the stored
    /// one. This used to take a token parameter it never read, which made the
    /// call read as "validate what is in the field" — the reordering of save
    /// and check that would break it.
    func validateStoredToken() async -> TokenCheck {
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

/// A publisher, studio or creator to open, by the name a series gives it.
struct PublisherRoute: Hashable, Identifiable {
    let name: String
    let kind: PublisherView.Kind
    var id: String { "\(kind)-\(name)" }
}
