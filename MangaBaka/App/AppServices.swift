import Foundation
import SwiftUI

/// Everything the app is made of, wired together once.
///
/// This was `MangaBakaApp.init`, which had grown to nineteen stored properties
/// and sixty lines of wiring — past the point where the lint could tell the
/// difference between a long function and a badly-organised one. It is not a
/// container or a service locator: it is the composition root, written out
/// plainly, and nothing reads from it at runtime except the one place that
/// hands it all to `RootView`.
/// The two setters `AppServices.wire` drives on the library.
///
/// Exists so `wire`'s library half can be recorded by a test double. See
/// `AppServices.wire` for why that was worth a protocol.
protocol LibraryFiltering: Sendable {
    func updateContentRatings(_ ratings: [String]) async
    func updateFormats(_ formats: [String]) async
}

extension LibraryService: LibraryFiltering {}

@MainActor
struct AppServices {
    let repository: SeriesRepository
    let shelf: ShelfStore
    let history: HistoryStore
    /// Volumes the reader has ticked as owned — user data, in the library file.
    let ownedVolumes: OwnedVolumes
    /// The merged volumes answer each series page drew, for the Next-volume
    /// widget — cache, in the cache file (`EditionAnswerStore`).
    let editionAnswers: EditionAnswerStore
    let client: APIClient
    let content: ContentPreferencesStore
    let formats: FormatPreferencesStore
    let library: LibraryService
    let schedule: ReleaseScheduleService
    let characters = CharacterService()
    let appleBooks = AppleBooksClient()
    /// Fills volume gaps Apple does not carry. Unauthenticated, so it answers
    /// nil whenever the shared anonymous quota is spent — Apple Books above is
    /// the source the page actually depends on.
    let googleBooks = GoogleBooksClient()
    /// Reads whichever publisher's own release feed a series carries a link
    /// to, in this order — nothing about either publisher makes one more
    /// authoritative, see `ReleaseFeedService`.
    ///
    /// Naver was removed 2026-09-14 (Q8): its only source of dates was
    /// `/api/article/list`, the undocumented JSON Naver's own page fetches,
    /// which the standing "no private APIs" rule forbids and an App Store
    /// submission makes non-negotiable. The adapter that remained after that
    /// answered `.notCarried` to everything, so it is gone too;
    /// `purgeLegacyNaverCache` below removes what it had already written.
    let releaseFeeds = ReleaseFeedService(
        providers: [WebtoonsFeedClient(), GigaViewerFeedClient()]
    )
    /// One instance each: both load a bundled file lazily (7.3 MB and
    /// 1.4 MB gzipped) and would otherwise reload it per series page.
    let embeddingIndex = EmbeddingIndex()
    let offlineCatalogue = OfflineCatalogue()
    /// One instance, shared by the series page's category lookup and
    /// `ReleaseScheduleService`'s cadence measurement (item 14). There were
    /// two, each with its own `RequestSpacing`, so the 3 s gap MangaUpdates'
    /// terms ask for was violated by construction on every page open and a
    /// 429 back-off on one was invisible to the other.
    let mangaUpdates: MangaUpdatesClient
    /// Deferred (item 107): a JSON file read out of Application Support, for
    /// a list only Settings shows and only `refreshReminders` walks — and
    /// `refreshReminders` returns before touching it when reminders are off,
    /// which is the default. Built on the first ask instead of in `init`.
    let publisherFollows = AppServices.deferredPublisherFollows()
    let openLibraryCovers = OpenLibraryCovers()
    /// The three bibliographic catalogues wired into the series page's "Other
    /// editions" section on 2026-09-14. They were built, tested and shipping
    /// before that date with nothing on screen using them.
    ///
    /// One instance each, for the reason `mangaUpdates` above records: two
    /// instances mean two spacing rules on one host, so the politeness gap is
    /// violated by construction and a 429 one learns is invisible to the other.
    /// The two Open Library clients go further and share `HostRateGate`, since
    /// they are two *different* clients on one host.
    let ann = ANNClient()
    let openLibraryEditions = OpenLibraryEditions()
    let ndl = NDLClient()
    /// One instance: a 451 KB gzipped file, loaded lazily on the first question
    /// and held. Nothing on the launch path touches it — see
    /// `WikidataIdentityTable`, which is deliberately lazier than
    /// `OfflineCatalogue` for that reason.
    let wikidata = WikidataIdentityTable()
    let taste: TasteProfile
    let catalogue: CatalogueService
    let blockedTags: BlockedTagsStore
    /// Deferred (item 107): a `UserDefaults` read plus a `JSONDecoder` pass
    /// over the reader's saved lenses, wanted by Search and Mix and by
    /// nothing else.
    let lenses = AppServices.deferredLenses()
    /// Deferred (item 107): a `UserDefaults.stringArray` read for at most six
    /// terms, wanted by the Search field alone.
    let recents = AppServices.deferredRecents()
    let session: SessionModels
    let calendar: ReleaseCalendar
    let librarySnapshot: LibrarySnapshot
    let reminders = ReleaseReminders()
    let onboarding = OnboardingState()
    /// The Keychain, read once for "is there a token at all" rather than
    /// inferred from a 401 (item 86 / Q7).
    ///
    /// This is the app's only `TokenStore()`. `SettingsView` and
    /// `ResolvingTokenProvider` used to default their own, and `TokenStore`
    /// memoised per instance, so the three disagreed about whether a token
    /// existed (second-pass review S1, 2026-09-14 — see `TokenStore.cache`).
    /// The memo is static now, so the reads are coherent whoever holds the
    /// value; passing this one through is what makes the single owner
    /// visible rather than a thing you have to know.
    let tokenStore: TokenStore
    /// True when the on-disk cache existed but could not be opened or
    /// migrated, and was renamed aside so a fresh one could be opened in its
    /// place (gap 3). `RootView.startSession` shows a one-shot toast off
    /// this so the reader is told their local saves were reset, instead of
    /// the old silent fall-through to an in-memory database that simply
    /// forgot everything on every relaunch with no explanation.
    let databaseWasReset: Bool
    /// "Can this app authenticate a request at all" — the Keychain token or,
    /// on a Debug build, the build-time `MB_PAT`.
    ///
    /// One closure rather than the two separate `{ keychain.read() != nil }`
    /// spellings this used to carry, because those ignored `MB_PAT` and so
    /// disagreed with the client on every build Abdi develops on: the Library
    /// tab said "No account" while Discover, the stack and Settings' token
    /// check were all authenticated (item 13 / S3, 2026-09-14). Defined on
    /// `ResolvingTokenProvider`, where the credential is actually resolved.
    let hasCredentials: @Sendable () -> Bool

    init() {
        mangaUpdates = MangaUpdatesClient()
        tokenStore = TokenStore()

        // Built here, not inside `makeClient`, because two things need it:
        // the client, to sign requests, and `hasCredentials` below, to answer
        // "is this reader signed in" with the same rule (item 13).
        let credentials = ResolvingTokenProvider(
            store: tokenStore, infoDictionary: Bundle.main.infoDictionary
        )
        hasCredentials = { credentials.hasCredentials }
        let apiClient = Self.makeClient(tokenProvider: credentials)
        client = apiClient
        let opened = Self.makeDatabase()
        let database = opened.database
        databaseWasReset = opened.wasReset

        // The three preference stores are read *before* the repository and
        // the library service exist, and their values go in through `init`
        // (item 62).
        //
        // They used to be posted afterwards, from a detached `Task` that
        // raced `DiscoverView`'s first `feed()`. The repository therefore
        // started with no ratings, no formats and no blocked tags, and either
        // discarded the whole feed cache on every launch (offline support
        // documented, tested and silently dead) or — with the
        // `applied`/`shouldDiscard` guard that was added to stop that — kept
        // a feed fetched under the defaults for up to 24 h, so a reader with
        // novels off or a tag blocked could get a Discover row that ignored
        // both and persisted. The repository never holds the empty state now,
        // so there is nothing to suppress and the guard is deleted.
        // Three stores on one line, for the lint's ceiling on this initialiser.
        let (store, formatStore) = (ContentPreferencesStore(), FormatPreferencesStore())
        let blocked = BlockedTagsStore()
        (content, formats, blockedTags) = (store, formatStore, blocked)

        repository = SeriesRepository(
            client: apiClient,
            database: database,
            contentRatings: store.preferences.queryValues,
            formats: formatStore.preferences.queryValues,
            blockedTags: blocked.blocked.ids
        )
        shelf = ShelfStore(database: database)
        history = HistoryStore(database: database)
        ownedVolumes = OwnedVolumes(database: database)
        editionAnswers = EditionAnswerStore(database: database)

        // The store owns the reader's choice; the repository owns acting on it.
        // Wiring them together here keeps the repository out of UserDefaults and
        // keeps the store from knowing anything about caches.

        // Reads the reader's own library and personalised data. Every call it
        // makes needs a token; without one they return nothing and the app
        // falls back to its unauthenticated behaviour.
        let libraryService = LibraryService(
            client: apiClient,
            contentRatings: store.preferences.queryValues,
            formats: formatStore.preferences.queryValues
        )
        library = libraryService

        // Built before anything that reads the library, because three of them
        // do and the library is the most expensive thing the app fetches.
        // The same Keychain read `SessionModels` gets, passed to the one
        // place the library actually comes from: without it the snapshot
        // served the previous account's six-hour disk cache to everything
        // downstream — the Library header, Discover's "Pick back up", the
        // widget tile, the Spotlight index — while the screens' own
        // `hasCredentials` correctly said "No account" (walk, 2026-09-14).
        let sharedLibrary = LibrarySnapshot(
            library: libraryService, database: database, hasCredentials: hasCredentials
        )
        librarySnapshot = sharedLibrary

        // The same `mangaUpdates` the series page's category lookup uses, so
        // the two share one `RequestSpacing` (item 14).
        schedule = ReleaseScheduleService(
            library: sharedLibrary, mangaUpdates: mangaUpdates, database: database
        )
        taste = TasteProfile(
            library: libraryService, ledger: TasteLedger(database: database), snapshot: sharedLibrary
        )
        catalogue = CatalogueService(client: apiClient)
        calendar = ReleaseCalendar(client: apiClient)

        Self.wire(
            content: store, formats: formatStore, blocked: blocked, to: repository, library: libraryService
        )

        Self.applyStoredExclusion(to: repository, library: libraryService, signedIn: hasCredentials())

        Self.startBackgroundWarmup()

        // Ratings read through a closure rather than copied in, so turning
        // Explicit off empties the recently-viewed row on the next load.
        session = SessionModels(
            repository: repository,
            history: history,
            libraryService: libraryService,
            snapshot: sharedLibrary,
            client: client,
            allowedRatings: { store.preferences.allowed.map(\.rawValue) },
            allowedFormats: { formatStore.preferences.queryValues },
            blockedTags: { blocked.blocked.ids },
            // Item 86 / Q7: `LibraryModel.hasCredentials` defaulted to
            // `{ true }` and no production caller passed it, so
            // `ScreenState.noAccount` and the screen behind it were dead
            // code — a reader with no token paid a 401 per Library visit and
            // was shown the generic failure instead.
            hasCredentials: hasCredentials
        )
    }

    /// Keeps the three preference stores and the two things that act on them
    /// in step.
    ///
    /// One function rather than three `onChange` assignments (item 137): they
    /// are n copies of one rule — "the reader's choice reaches the feed cache
    /// *and* the recommender" — and no test asserted any of them, in a
    /// project whose own `XcconfigAssertions` names "a correct rule applied
    /// n−1 times out of n" as its characteristic defect. Recommendations are
    /// built from the reader's own library and are not content filtered by
    /// default, so filtering feeds but not recommendations is the setting
    /// failing silently exactly where it matters most; and "no novels" would
    /// otherwise hold everywhere except the one screen built from taste.
    ///
    /// `library` is `any LibraryFiltering`, not `LibraryService`, for the
    /// test's sake: the kill criterion stated below used to be false. With a
    /// concrete `LibraryService` the only double available was a real one,
    /// which records nothing, so `updateContentRatings` and `updateFormats`
    /// on the library half were asserted by nothing — two of the five lines
    /// could be deleted with the suite still green, and they are the two that
    /// filter the reader's own recommendations by rating (item 59,
    /// 2026-09-14). A seam whose only purpose is a test, and said so here.
    static func wire(
        content: ContentPreferencesStore,
        formats: FormatPreferencesStore,
        blocked: BlockedTagsStore,
        to repository: any SeriesRepositoryProtocol,
        library: any LibraryFiltering
    ) {
        content.onChange = { ratings in
            await repository.updateContentRatings(ratings)
            await library.updateContentRatings(ratings)
        }
        formats.onChange = { types in
            await repository.updateFormats(types)
            await library.updateFormats(types)
        }
        blocked.onChange = { ids in
            await repository.updateBlockedTags(ids)
        }
    }

    /// The three stores that are not on the launch path (item 107).
    ///
    /// Named factories rather than `Deferred { … }` written inline at each
    /// property, so the test can exercise the exact expression `init` uses
    /// instead of a copy of it: a second `Deferred { SearchLensStore() }` in
    /// the test file would pass whether or not the property still used one.
    ///
    /// **What this saves is a guess and unmeasured.** Cold launch is ~900 ms
    /// with about 300 ms of app work; these three are a `stringArray` read,
    /// a small `JSONDecoder` pass over `UserDefaults` data, and one
    /// Application Support file read plus decode. GUESS: under 1 ms for the
    /// first two and 1–3 ms for the file, so single-digit milliseconds in
    /// total, and possibly under one. `UserDefaults.standard` itself is not
    /// saved — `ContentPreferencesStore` and two others still open it in
    /// `init`, so the first-touch cost is paid regardless. The reason to do
    /// it is that a screen nobody opens should cost nothing, not the number.
    static func deferredLenses() -> Deferred<SearchLensStore> {
        Deferred { SearchLensStore() }
    }

    static func deferredRecents() -> Deferred<RecentSearches> {
        Deferred { RecentSearches() }
    }

    static func deferredPublisherFollows() -> Deferred<PublisherFollows> {
        Deferred { PublisherFollows() }
    }

    /// The two pieces of launch work that must not be on the launch path.
    ///
    /// Off the main thread and after the first frame: the bundled taxonomy is
    /// a file read plus a 2,686-row decode, and two of its callers are views
    /// (the tag picker, the blocked-tag list), so without this the first
    /// sheet to open pays for it synchronously — GUESS 10–30 ms, unmeasured.
    /// See `TagTaxonomy.warm`.
    private static func startBackgroundWarmup() {
        Task.detached(priority: .utility) {
            TagTaxonomy.warm()
            Self.purgeLegacyNaverCache()
        }
    }

    /// Removes the on-disk cache the deleted Naver adapter used to write.
    ///
    /// Those files hold data obtained from `/api/article/list`, the private
    /// endpoint dropped on 2026-09-14 (Q8); serving them after removing the
    /// dependency would be keeping the fruit of it. A no-op after the first
    /// run and on a device that never had the directory, which is why it can
    /// sit on the launch path's background task and on the account-change
    /// path both.
    nonisolated static func purgeLegacyNaverCache() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        guard let directory = caches?.appendingPathComponent("naver", isDirectory: true) else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    /// The API client, pointed at whatever the build says.
    private static func makeClient(tokenProvider: some TokenProvider) -> APIClient {
        let info = Bundle.main.infoDictionary

        // Falls back to the documented production host if the build setting is
        // missing, so a misconfigured xcconfig cannot produce a crash.
        let base = (info?["MB_API_BASE_URL"] as? String)
            .flatMap(URL.init(string:))
            ?? URL(string: "https://api.mangabaka.org").unsafelyUnwrappedFallback

        // Resolved per request rather than chosen once, so a token entered in
        // Settings takes effect immediately instead of after a relaunch.
        return APIClient(baseURL: base, tokenProvider: tokenProvider)
    }

    /// The on-device cache.
    ///
    /// A cache that cannot be opened is not worth crashing over. Gap 3: a
    /// corrupt file used to fall through to an in-memory database — one that
    /// remembers nothing between launches — with no attempt to recover the
    /// on-disk path and no word to the reader about why their stack and
    /// library cache reset every day. `onDiskResettingIfCorrupt` renames a
    /// bad file aside and opens a fresh one in its place first; only when
    /// even that fails does this fall back to in-memory.
    private static func makeDatabase() -> AppDatabase.OpenResult {
        // The one unbounded piece of the launch path: a SQLite open, plus a
        // migration on a version change. Measured on the simulator, cold,
        // 2026-09-11: see the commit that added this interval.
        let opened = Signposts.measure("Database open") { AppDatabase.onDiskResettingIfCorrupt() }
        if let opened { return opened }
        let fallback = (try? AppDatabase.inMemory()) ?? {
            preconditionFailure("An in-memory SQLite database could not be opened.")
        }()
        // `.unopened`, not `.reset` (item 78): nothing was renamed and
        // nothing was lost here — the file is sitting there intact and merely
        // unopened, and the next launch may well open it. Reporting a reset
        // told the reader their saved stack and library cache had been thrown
        // away when they had not been.
        return AppDatabase.OpenResult(database: fallback, outcome: .unopened)
    }

    /// Cover art dominates this app's network use and is highly re-requested —
    /// the same covers appear across rows, search results and detail screens.
    /// URLSession's default disk cache is far too small for that, so scrolling
    /// back up re-downloaded artwork the device already had.
    ///
    /// Called from `MangaBakaApp.init`, not from `AppServices.init` (item
    /// 107): replacing `URLCache.shared` opens the disk cache's SQLite index
    /// synchronously, and doing it inside the "Services" signpost made that
    /// interval measure a system cache rather than the app's own objects.
    ///
    /// **Both numbers are guesses** — derived from the size of the artwork
    /// rather than from a measurement. A x350 cover is ~40 KB, a feed row is
    /// 20 of them, and a scroll through Discover touches a few hundred: 32 MB
    /// of memory is roughly 800 covers, and 256 MB of disk roughly 6,500,
    /// which is more than a large library's worth. Nobody has measured the
    /// hit rate at either size.
    static func enlargeImageCache(
        memoryCapacity: Int = 32 * 1024 * 1024,
        diskCapacity: Int = 256 * 1024 * 1024
    ) {
        URLCache.shared = URLCache(memoryCapacity: memoryCapacity, diskCapacity: diskCapacity)
    }

    /// Lets a blend exclude what the reader already tracks.
    ///
    /// This is all that is left of `applyStoredFilters` (item 62): the
    /// ratings, formats and blocked tags now go through `init` instead, so
    /// nothing races the first `feed()`. The exclusion cannot — it needs the
    /// reader's own id, which costs a request — so it stays a `Task`, and
    /// `updateLibraryExclusion`'s own doc comment explains why it measures a
    /// change against the id the cache was written under rather than against
    /// whatever this process started with.
    ///
    /// Nil when unauthenticated, which is the ordinary case and not a failure.
    ///
    /// `hasCredentials` because "unauthenticated" was being discovered by
    /// *asking*: `profileID()` sent `/v1/my/profile` on every signed-out cold
    /// launch, a request that can only ever be a 401, against the 180/min
    /// budget the whole app shares (item 15, 2026-09-14). Taken once here
    /// rather than as a closure: this runs at the end of `init`, and the
    /// token cannot change before the `Task` starts.
    private static func applyStoredExclusion(
        to repository: SeriesRepository, library: LibraryService, signedIn: Bool
    ) {
        guard signedIn else { return }
        Task {
            await repository.updateLibraryExclusion(userID: library.profileID())
        }
    }

}

private extension Optional where Wrapped == URL {
    /// The literal at the call site is a compile-time constant known to parse.
    /// This exists so that call site reads honestly instead of using `!`, which
    /// CLAUDE.md forbids on anything reachable from real input.
    var unsafelyUnwrappedFallback: URL {
        guard let self else {
            preconditionFailure("Hard-coded base URL literal failed to parse.")
        }
        return self
    }
}
