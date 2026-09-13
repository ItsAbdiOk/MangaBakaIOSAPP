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
    let releaseFeeds: ReleaseFeedService
    let embeddingIndex: EmbeddingIndex
    let offlineCatalogue: OfflineCatalogue
    let mangaUpdatesCategories: MangaUpdatesClient
    let publisherFollows: PublisherFollows
    let openLibraryCovers: OpenLibraryCovers
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
    /// True when the on-disk cache had to be reset before this launch — see
    /// `AppServices.makeDatabase` and gap 3. Told to the reader once, from
    /// `startSession`, rather than shown here directly.
    let databaseWasReset: Bool
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

    /// Internal rather than private: `RootView+Session.swift` needs to raise
    /// a toast from `startSession` (gap 3, the database-reset notice) and
    /// from the dead-tap paths on `openSeries`/`openFromSpotlight` (gap 61),
    /// and a stored `@State` cannot be reached across files at `private`.
    @State var toasts = ToastCentre()
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
    @State var searchModel: SearchModel?
    @State private var browseModel: BrowseModel?
    @State private var showsBrowse = false
    /// Internal rather than private: `RootView+Failures.swift` reads this to
    /// guard "Use as seed" against a tap landing before the tab's own
    /// `.task` has built the model (gap 77).
    @State var mixModel: MixModel?
    /// Held here for the same reason as the three above, and for one more:
    /// the `.id(titleRevision)` on the tab tree rebuilds it when the title
    /// preference changes, and a model built inline in the body went with it
    /// — the stack's queue and its "seen this run" counts were reset by a
    /// display setting. Models above the `.id` survive it.
    @State private var discoverModel: DiscoverModel?
    /// Internal rather than private: `forgetPreviousAccount` (in
    /// `RootView+Session.swift`) has to clear `ranker` on an account change
    /// (gap 89) — a taste ranker built from the previous account's library
    /// otherwise keeps weighting the new account's stack until relaunch.
    @State var stackModel: StackModel?
    /// The cover the detail page should grow out of, and the namespace the
    /// source and destination share. See `ZoomRoute`.
    @State var zoomRoute = ZoomRoute()
    @Namespace var coverTransition
    /// Real covers behind the first onboarding screen. Empty until the rising
    /// feed answers, which is the case the screen is built to survive.
    @State var onboardingCovers: [Series] = []
    /// True until the rising feed has actually answered — success or
    /// failure. Gap 63: the six placeholder rectangles rendered identically
    /// whether the covers were still in flight or the fetch had already
    /// failed (or come back empty), so a reader on a bad connection saw what
    /// looked like the first screen stuck loading forever rather than the
    /// deliberate colour-wash fallback the design already has for exactly
    /// that case — see `CoversFirstPage`'s doc comment.
    @State var isLoadingCovers = true
    /// Whether Settings should open with the token field already focused.
    @State var wantsAccountFocus = false
    /// Set when onboarding's "Connect an account" is tapped, and acted on
    /// only once `onboarding.hasCompleted` has actually flipped — see
    /// `RootView+Failures.onboardingCompletionChanged` and gap 64. Internal
    /// so that method, in another file, can read and clear it.
    @State var wantsAccountAfterOnboarding = false
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
            // What the tag picker may offer this reader: their rating
            // ceiling and their blocked list, so a picked tag can never be
            // one the search then refuses (`TagAudience`).
            .environment(\.tagAudience, TagAudience(
                allowedRatings: Set(content.preferences.queryValues),
                showsSpoilers: false,
                blockedIds: Set(blockedTags.blocked.ids)
            ))
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
                // A mangabaka.org series link, or the widgets' own
                // `mangabaka://series/<id>` — see SeriesWebLink.
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
                    isLoadingCovers: isLoadingCovers,
                    onFinish: { onboarding.complete() },
                    onConnectAccount: {
                        wantsAccountAfterOnboarding = true
                        onboarding.complete()
                    }
                )
            }
            // Gap 64: see `onboardingCompletionChanged` in
            // `RootView+Failures.swift` for why this is deferred rather than
            // acted on inside `onConnectAccount` directly.
            .onChange(of: onboarding.hasCompleted) { _, completed in onboardingCompletionChanged(completed) }
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
                        inProgress: session.library.inProgress,
                        recentlyViewed: session.recentlyViewed,
                        path: $discoverPath,
                        pulse: session.pulse,
                        chaptersRead: ReadingInsights.chaptersRead(in: session.library.entries),
                        whatsNew: whatsNew,
                        hasCompletedOnboarding: onboarding.hasCompleted
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
                        model: searchModel ?? makeSearchModel(),
                        path: $searchPath,
                        onBrowse: { showsBrowse = true },
                        lenses: lenses,
                        counts: session.counts,
                        catalogue: catalogue,
                        recents: recents,
                        library: library
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
            if searchModel == nil { searchModel = makeSearchModel() }
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
            //
            // Gap 119: this used to pass `error.userFacingMessage` straight
            // through, which is copy written to stand alone on a full-screen
            // failure ("Showing what was downloaded. Nothing new can load
            // until you're back.") — feed wording, sitting after "Saved on
            // this phone but not checked yet:" on the account card, where it
            // read like a mismatched sentence rather than a reason.
            // `shortReason` is the phrase built for that cramped spot.
            return error.needsAccount ? .rejected : .unknown(error.shortReason)
        }
    }
}

/// A publisher, studio or creator to open, by the name a series gives it.
struct PublisherRoute: Hashable, Identifiable {
    let name: String
    let kind: PublisherView.Kind
    var id: String { "\(kind)-\(name)" }
}
