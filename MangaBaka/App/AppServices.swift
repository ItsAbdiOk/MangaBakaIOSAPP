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
@MainActor
struct AppServices {
    let repository: SeriesRepository
    let shelf: ShelfStore
    let history: HistoryStore
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
    /// to. Webtoons and GigaViewer before Naver: Naver is the Korean original
    /// and never becomes the reader's own edition — see `ReleaseFeedService`.
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
    let publisherFollows = PublisherFollows()
    let openLibraryCovers = OpenLibraryCovers()
    let taste: TasteProfile
    let catalogue: CatalogueService
    let blockedTags: BlockedTagsStore
    let lenses = SearchLensStore()
    let recents = RecentSearches()
    let session: SessionModels
    let calendar: ReleaseCalendar
    let librarySnapshot: LibrarySnapshot
    let reminders = ReleaseReminders()
    let onboarding = OnboardingState()
    /// The Keychain, read once for "is there a token at all" rather than
    /// inferred from a 401 (item 86 / Q7). `TokenStore` memoises its own
    /// reads behind a lock, so holding one instance is what makes the
    /// `hasCredentials` closure below cost nothing per call.
    let tokenStore: TokenStore
    /// True when the on-disk cache existed but could not be opened or
    /// migrated, and was renamed aside so a fresh one could be opened in its
    /// place (gap 3). `RootView.startSession` shows a one-shot toast off
    /// this so the reader is told their local saves were reset, instead of
    /// the old silent fall-through to an in-memory database that simply
    /// forgot everything on every relaunch with no explanation.
    let databaseWasReset: Bool

    init() {
        let updates = MangaUpdatesClient()
        mangaUpdates = updates
        let keychain = TokenStore()
        tokenStore = keychain

        let apiClient = Self.makeClient()
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
        let store = ContentPreferencesStore()
        content = store
        let formatStore = FormatPreferencesStore()
        formats = formatStore
        let blocked = BlockedTagsStore()
        blockedTags = blocked

        repository = SeriesRepository(
            client: apiClient,
            database: database,
            contentRatings: store.preferences.queryValues,
            formats: formatStore.preferences.queryValues,
            blockedTags: blocked.blocked.ids
        )
        shelf = ShelfStore(database: database)
        history = HistoryStore(database: database)

        // The store owns the reader's choice; the repository owns acting on it.
        // Wiring them together here keeps the repository out of UserDefaults and
        // keeps the store from knowing anything about caches.
        let built = repository

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
        let sharedLibrary = LibrarySnapshot(library: libraryService, database: database)
        librarySnapshot = sharedLibrary

        // The same `mangaUpdates` the series page's category lookup uses, so
        // the two share one `RequestSpacing` (item 14).
        schedule = ReleaseScheduleService(
            library: sharedLibrary, mangaUpdates: updates, database: database
        )
        taste = TasteProfile(
            library: libraryService,
            ledger: TasteLedger(database: database),
            snapshot: sharedLibrary
        )
        catalogue = CatalogueService(client: apiClient)
        calendar = ReleaseCalendar(client: apiClient)

        Self.wire(content: store, formats: formatStore, blocked: blocked,
                  to: built, library: libraryService)

        Self.applyStoredExclusion(to: repository, library: libraryService)

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
            hasCredentials: { keychain.read() != nil }
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
    static func wire(
        content: ContentPreferencesStore,
        formats: FormatPreferencesStore,
        blocked: BlockedTagsStore,
        to repository: any SeriesRepositoryProtocol,
        library: LibraryService
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
    private static func makeClient() -> APIClient {
        let info = Bundle.main.infoDictionary

        // Falls back to the documented production host if the build setting is
        // missing, so a misconfigured xcconfig cannot produce a crash.
        let base = (info?["MB_API_BASE_URL"] as? String)
            .flatMap(URL.init(string:))
            ?? URL(string: "https://api.mangabaka.org").unsafelyUnwrappedFallback

        // Resolved per request rather than chosen once, so a token entered in
        // Settings takes effect immediately instead of after a relaunch.
        return APIClient(baseURL: base, tokenProvider: ResolvingTokenProvider(infoDictionary: info))
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
    private static func applyStoredExclusion(to repository: SeriesRepository, library: LibraryService) {
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
