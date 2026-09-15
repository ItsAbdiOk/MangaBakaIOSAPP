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
    /// One client, shared with `ReleaseScheduleService` (item 14). Two
    /// instances each kept their own `RequestSpacing`, so cadence and
    /// categories hit MangaUpdates concurrently on every page open and a
    /// 429 back-off on one was invisible to the other.
    let mangaUpdates: MangaUpdatesClient
    /// Deferred, not built (item 107). Settings' follow list and
    /// `refreshReminders` are the only things that ask, and neither happens
    /// before the first frame — see `AppServices.deferredPublisherFollows`.
    let publisherFollows: Deferred<PublisherFollows>
    let openLibraryCovers: OpenLibraryCovers
    /// The three bibliographic catalogues behind the series page's "Other
    /// editions" section. One instance each, like every other client here: each
    /// holds a disk cache and a spacing rule, and a second instance would keep
    /// its own and violate the host's limit by construction (item 14's lesson,
    /// applied before it could happen again).
    let ann: ANNClient
    let openLibraryEditions: OpenLibraryEditions
    let ndl: NDLClient
    /// The bundled Wikidata identity table. One instance for the same reason
    /// `embeddingIndex` and `offlineCatalogue` are: it loads a 451 KB gzipped
    /// file lazily and holds it, and a per-page instance would reload it per
    /// page.
    let wikidata: WikidataIdentityTable
    let ownedVolumes: OwnedVolumes
    let editionAnswers: EditionAnswerStore
    let taste: TasteProfile
    let catalogue: CatalogueService
    let blockedTags: BlockedTagsStore
    /// Deferred, not built (item 107): Search and Mix ask, nothing else does.
    let lenses: Deferred<SearchLensStore>
    /// Deferred, not built (item 107): only the Search field asks.
    let recents: Deferred<RecentSearches>
    /// The models that live for the session rather than for a screen. Built in
    /// `MangaBakaApp` alongside everything else they depend on, rather than
    /// lazily here — a lazily-initialised @State plus an accessor, per model,
    /// is four things to read where there should be one.
    let session: SessionModels
    let calendar: ReleaseCalendar
    let librarySnapshot: LibrarySnapshot
    let reminders: ReleaseReminders
    /// The app's single `TokenStore`, passed rather than defaulted.
    ///
    /// `SettingsView` used to build its own, and `TokenStore` memoised per
    /// instance, so the token Settings wrote was invisible to the client that
    /// had to validate it — see `TokenStore.cache` (second-pass review S1).
    let tokenStore: TokenStore
    /// "Is anybody signed in" as the API client itself answers it, `MB_PAT`
    /// included — see `AppServices.hasCredentials` (item 13).
    let hasCredentials: @Sendable () -> Bool
    /// True when the on-disk cache had to be reset before this launch — see
    /// `AppServices.makeDatabase` and gap 3. Told to the reader once, from
    /// `startSession`, rather than shown here directly.
    let databaseWasReset: Bool
    /// The library in iOS search. A struct with no state, so it is built here
    /// rather than passed through `AppServices`.
    let spotlight = SpotlightIndex()
    @State var whatsNew = WhatsNewState()
    /// "More of what you finished" on the Library screen; see Continuations.
    @State var continuations: ContinuationsModel
    @State var binge: BingeModel
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
    @State var stackPath: [Series] = []
    @State var shelfPath: [Series] = []
    @State var showsSchedule = false
    @State var showsTaste = false
    @State var showsWrapped = false
    @State var showsSettings = false
    @State var searchPath: [Series] = []
    @State var mixPath: [Series] = []
    @State var searchModel: SearchModel
    @State var browseModel: BrowseModel
    @State var showsBrowse = false
    /// The tag tree is a sheet with its own stack rather than a push: the
    /// search stack's path is `[Series]`, and a typed path cannot hold the
    /// `Tag` values the tree pushes level by level.
    @State var showsTagTree = false
    /// Internal rather than private: `RootView+Failures.swift` reads this to
    /// guard "Use as seed" against a tap landing before the tab's own
    /// `.task` has built the model (gap 77).
    @State var mixModel: MixModel
    /// Held here for the same reason as the three above, and for one more:
    /// the `.id(titleRevision)` on the tab tree rebuilds it when the title
    /// preference changes, and a model built inline in the body went with it
    /// — the stack's queue and its "seen this run" counts were reset by a
    /// display setting. Models above the `.id` survive it.
    @State var discoverModel: DiscoverModel
    /// Internal rather than private: `forgetPreviousAccount` (in
    /// `RootView+Session.swift`) has to clear `ranker` on an account change
    /// (gap 89) — a taste ranker built from the previous account's library
    /// otherwise keeps weighting the new account's stack until relaunch.
    @State var stackModel: StackModel
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
    /// Item 11: `refreshReminders()`'s own doc comment has always promised
    /// "and when the app comes back to the foreground", and no `scenePhase`
    /// handler existed anywhere in the app — so a pending list built at
    /// launch went stale for as long as the process lived. Tracked rather
    /// than read off `onChange`'s old value: returning from the background
    /// arrives as .background → .inactive → .active, so the old value at the
    /// moment it matters is .inactive, which is also what a Control Centre
    /// pull looks like.
    @Environment(\.scenePhase) private var scenePhase
    @State private var wasBackgrounded = false
    /// One handle, so two quick foregrounds do not run two walks.
    @State private var reminderRefresh: Task<Void, Never>?

    /// What the tag picker may offer this reader, held rather than rebuilt.
    ///
    /// Item 106: this was constructed inline in `body`, so two `Set`s were
    /// heap-allocated on every body pass — every toast, every tab selection,
    /// every path change — to express two values that change only when the
    /// reader opens Settings. Microseconds each, and filed by the review as
    /// "so nobody adds a third"; the point is that the pass allocates nothing
    /// for it now, not that a frame was being missed. **Unmeasured**: no
    /// before/after Instruments trace was taken, because the two inputs are
    /// four rating strings and a blocked list that is usually empty — there
    /// is no number here worth quoting and I would rather say so than invent
    /// one.
    ///
    /// Seeded in `init` rather than by `.onChange(initial: true)`: the
    /// initial-fire version would render the first frame against an empty
    /// audience, and an empty `allowedRatings` is the picker showing the
    /// reader nothing rather than showing them too much.
    @State private var tagAudience: TagAudience

    /// Builds the six session-lived models up front, rather than leaving them
    /// nil until the tab tree's own `.task` runs.
    ///
    /// Item 61: they used to be optional `@State`, and the first body pass
    /// reached them through `?? DiscoverModel(…)` fallbacks. `DiscoverView`,
    /// `StackView` and the rest capture what they are handed in
    /// `State(initialValue:)`, so the tab kept the throwaway — and the `.task`
    /// then stored a *second* set that only `RootView` could see. Every
    /// `stackModel.ranker` write, including `forgetPreviousAccount`'s
    /// `= nil`, landed on the object nobody was showing. `SessionModels`
    /// already builds its own this way and says why.
    init(
        repository: SeriesRepository,
        shelf: ShelfStore,
        history: HistoryStore,
        client: APIClient,
        content: ContentPreferencesStore,
        formats: FormatPreferencesStore,
        library: LibraryService,
        schedule: ReleaseScheduleService,
        characters: CharacterService,
        appleBooks: AppleBooksClient,
        googleBooks: GoogleBooksClient,
        releaseFeeds: ReleaseFeedService,
        embeddingIndex: EmbeddingIndex,
        offlineCatalogue: OfflineCatalogue,
        mangaUpdates: MangaUpdatesClient,
        publisherFollows: Deferred<PublisherFollows>,
        openLibraryCovers: OpenLibraryCovers,
        ann: ANNClient,
        openLibraryEditions: OpenLibraryEditions,
        ndl: NDLClient,
        wikidata: WikidataIdentityTable,
        ownedVolumes: OwnedVolumes,
        editionAnswers: EditionAnswerStore,
        taste: TasteProfile,
        catalogue: CatalogueService,
        blockedTags: BlockedTagsStore,
        lenses: Deferred<SearchLensStore>,
        recents: Deferred<RecentSearches>,
        session: SessionModels,
        calendar: ReleaseCalendar,
        librarySnapshot: LibrarySnapshot,
        reminders: ReleaseReminders,
        tokenStore: TokenStore,
        hasCredentials: @escaping @Sendable () -> Bool,
        databaseWasReset: Bool,
        onboarding: OnboardingState
    ) {
        self.repository = repository
        self.shelf = shelf
        self.history = history
        self.client = client
        self.content = content
        self.formats = formats
        self.library = library
        self.schedule = schedule
        self.characters = characters
        self.appleBooks = appleBooks
        self.googleBooks = googleBooks
        self.releaseFeeds = releaseFeeds
        self.embeddingIndex = embeddingIndex
        self.offlineCatalogue = offlineCatalogue
        self.mangaUpdates = mangaUpdates
        self.publisherFollows = publisherFollows
        self.openLibraryCovers = openLibraryCovers
        self.ann = ann
        self.openLibraryEditions = openLibraryEditions
        self.ndl = ndl
        self.wikidata = wikidata
        self.ownedVolumes = ownedVolumes
        self.editionAnswers = editionAnswers
        self.taste = taste
        self.catalogue = catalogue
        self.blockedTags = blockedTags
        self.lenses = lenses
        self.recents = recents
        self.session = session
        self.calendar = calendar
        self.librarySnapshot = librarySnapshot
        self.reminders = reminders
        self.tokenStore = tokenStore
        self.hasCredentials = hasCredentials
        self.databaseWasReset = databaseWasReset
        self.onboarding = onboarding
        _continuations = State(initialValue: ContinuationsModel(repository: repository))
        _binge = State(initialValue: BingeModel(
            repository: repository, releaseFeeds: releaseFeeds, history: history
        ))
        _searchModel = State(initialValue: SearchModel(
            repository: repository,
            offline: offlineCatalogue,
            allowedRatings: { content.preferences.queryValues },
            allowedFormats: { formats.preferences.queryValues },
            blockedTagIDs: { blockedTags.blocked.ids }
        ))
        _browseModel = State(initialValue: BrowseModel(catalogue: catalogue))
        _mixModel = State(initialValue: MixModel(repository: repository, shelf: shelf))
        _discoverModel = State(initialValue: DiscoverModel(repository: repository))
        // The shared snapshot, not a private walk of its own (lane C):
        // `StackModel` reads the library to keep what is already tracked out
        // of the queue, and a second walk is 24.7 MB on a real account.
        // Item 106: seeded from the same two stores the `onChange` pair in
        // `body` keeps it in step with.
        _tagAudience = State(initialValue: TagAudience(
            allowedRatings: Set(content.preferences.queryValues),
            showsSpoilers: false,
            blockedIds: Set(blockedTags.blocked.ids)
        ))
        _stackModel = State(initialValue: StackModel(
            repository: repository, shelf: shelf, library: library, snapshot: librarySnapshot
        ))
    }

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
            //
            // Item 106: read from `tagAudience`, which is rebuilt only when
            // one of the two stores actually changes. The `onChange`
            // comparisons below are a four-element `Set<Rating>` and an array
            // of blocked tags — no allocation — where building the value took
            // two every pass.
            .environment(\.tagAudience, tagAudience)
            .onChange(of: content.preferences) { _, preferences in
                tagAudience.allowedRatings = Set(preferences.queryValues)
            }
            .onChange(of: blockedTags.blocked) { _, blocked in
                tagAudience.blockedIds = Set(blocked.ids)
            }
            .task { await startSession() }
            // `primeAniListHealth` used to run here — a POST to
            // graphql.anilist.co on every cold launch, from every reader,
            // including those who never open a series page. Deleted
            // 2026-09-14 on Abdi's call (Q4): both cast sources are asked
            // concurrently now, so there is no AniList timeout to get ahead
            // of, and it held one of the 0.7 s slots exactly when the first
            // real cast request wanted it. See `CharacterService`.
            //
            // Dates move and series leave the library while the app sits in
            // the background, so the pending list is corrected on return
            // (item 11) — the foreground half of what `refreshReminders`'
            // own doc comment has always promised.
            .onChange(of: scenePhase) { _, phase in foregroundChanged(to: phase) }
            // A library series tapped in Spotlight. The page opens in the
            // Library tab, which is where the reader's state on it lives.
            // "Open <series>" from Siri or Shortcuts; see IntentBridge.
            .task(id: bridge.pending?.token) {
                guard let request = bridge.pending else { return }
                await openSeries(id: request.id)
                // Cleared *after* the navigation, never before it. Clearing
                // first wrote to the value this modifier is keyed on, which
                // cancelled this very task before it had navigated — see
                // `IntentBridge.pending`. Keyed on `token` rather than `id`
                // so this clear cannot be mistaken for a new request, and
                // guarded so a second "Open X" that arrived while the first
                // was in flight is not thrown away by the first one finishing.
                if bridge.pending?.token == request.token { bridge.pending = nil }
            }
            // A mangabaka.org series link. Dormant until the site hosts the
            // association file; see SeriesWebLink.
            .onOpenURL { url in
                // A mangabaka.org series link, or the widgets' own
                // `mangabaka://series/<id>` — see SeriesWebLink.
                //
                // Through the bridge rather than an unstructured
                // `Task { await openSeries(id:) }` (item 65): that bypassed
                // the `Task.isCancelled` guards `openSeries` relies on, so
                // two rapid widget taps could land the *older* series on top
                // (gap 76, re-opened for links). One entry point for Siri,
                // widgets and web links, and it is the one already
                // cancelled-and-restarted by `.task(id:)` above.
                guard let id = SeriesWebLink.seriesID(from: url) else { return }
                bridge.pending = IntentBridge.Open(id: id)
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

    /// Rebuilds the pending reminders when the app comes back from the
    /// background.
    ///
    /// Item 11: `refreshReminders()` ran only at launch and from the Settings
    /// switch, while its own doc comment promised the foreground too — and
    /// no `scenePhase` handler existed anywhere in `App/` or `Features/`.
    /// Only a real background round trip counts: a Control Centre pull is
    /// .inactive → .active and would otherwise re-walk on every glance, and
    /// launch itself is already covered by `startSession`.
    private func foregroundChanged(to phase: ScenePhase) {
        switch phase {
        case .background:
            wasBackgrounded = true
        case .active where wasBackgrounded:
            wasBackgrounded = false
            // One handle: two quick foregrounds should leave one walk
            // running, not two racing to reschedule the same list.
            reminderRefresh?.cancel()
            reminderRefresh = Task { await refreshReminders() }
        default:
            break
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
