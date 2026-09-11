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

    init() {
        // Cover art dominates this app's network use and is highly re-requested
        // — the same covers appear across rows, search results and detail
        // screens. URLSession's default disk cache is far too small for that,
        // so scrolling back up re-downloads artwork the device already had.
        Self.enlargeImageCache()

        let apiClient = Self.makeClient()
        client = apiClient
        let database = Self.makeDatabase()

        repository = SeriesRepository(client: apiClient, database: database)
        shelf = ShelfStore(database: database)
        history = HistoryStore(database: database)

        // The store owns the reader's choice; the repository owns acting on it.
        // Wiring them together here keeps the repository out of UserDefaults and
        // keeps the store from knowing anything about caches.
        let built = repository
        let store = ContentPreferencesStore()
        content = store

        let formatStore = FormatPreferencesStore()
        formats = formatStore

        // Reads the reader's own library and personalised data. Every call it
        // makes needs a token; without one they return nothing and the app
        // falls back to its unauthenticated behaviour.
        let libraryService = LibraryService(
            client: apiClient,
            contentRatings: store.preferences.queryValues
        )
        library = libraryService

        // Built before anything that reads the library, because three of them
        // do and the library is the most expensive thing the app fetches.
        let sharedLibrary = LibrarySnapshot(library: libraryService, database: database)
        librarySnapshot = sharedLibrary

        schedule = ReleaseScheduleService(library: libraryService, database: database)
        taste = TasteProfile(
            library: libraryService,
            ledger: TasteLedger(database: database),
            snapshot: sharedLibrary
        )
        catalogue = CatalogueService(client: apiClient)
        calendar = ReleaseCalendar(client: apiClient)

        let blocked = BlockedTagsStore()
        blocked.onChange = { ids in await built.updateBlockedTags(ids) }
        blockedTags = blocked

        // Recommendations are built from the reader's own library and are not
        // content filtered by default, so the same choice has to reach both.
        // Filtering feeds but not recommendations is the setting failing
        // silently exactly where it matters most.
        store.onChange = { ratings in
            await built.updateContentRatings(ratings)
            await libraryService.updateContentRatings(ratings)
        }
        // The format choice has to reach the recommender too, or "no novels"
        // would hold everywhere except the one screen built from taste.
        formatStore.onChange = { types in
            await built.updateFormats(types)
            await libraryService.updateFormats(types)
        }

        Self.applyStoredFilters(
            to: repository,
            library: libraryService,
            content: store,
            formats: formatStore,
            blocked: blocked
        )

        // Ratings read through a closure rather than copied in, so turning
        // Explicit off empties the recently-viewed row on the next load.
        session = SessionModels(
            repository: repository,
            history: history,
            libraryService: libraryService,
            snapshot: sharedLibrary,
            client: client,
            allowedRatings: { store.preferences.allowed.map(\.rawValue) }
        )
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
    /// A cache that cannot be opened is not worth crashing over: fall back to
    /// an in-memory one so the app still works, just without offline support
    /// until the next launch.
    private static func makeDatabase() -> AppDatabase {
        // The one unbounded piece of the launch path: a SQLite open, plus a
        // migration on a version change. Measured on the simulator, cold,
        // 2026-09-11: see the commit that added this interval.
        let opened = Signposts.measure("Database open") { try? AppDatabase.onDisk() }
        if let opened { return opened }
        return (try? AppDatabase.inMemory()) ?? {
            preconditionFailure("An in-memory SQLite database could not be opened.")
        }()
    }

    /// Cover art dominates this app's network use and is highly re-requested —
    /// the same covers appear across rows, search results and detail screens.
    /// URLSession's default disk cache is far too small for that, so scrolling
    /// back up re-downloaded artwork the device already had.
    private static func enlargeImageCache() {
        URLCache.shared = URLCache(
            memoryCapacity: 32 * 1024 * 1024,
            diskCapacity: 256 * 1024 * 1024
        )
    }

    /// Hands the repository and the library service the choices already on
    /// disk, before the first request goes out.
    ///
    /// Its own function because the initialiser reached the lint's ceiling, and
    /// because this is one idea rather than four: everything the reader has
    /// already decided, applied once, in one place.
    ///
    /// A first application is deliberately not treated as a change — see
    /// `SeriesRepository.updateFormats`. Treating it as one discarded the feed
    /// cache on every launch.
    private static func applyStoredFilters(
        to repository: SeriesRepository,
        library: LibraryService,
        content: ContentPreferencesStore,
        formats: FormatPreferencesStore,
        blocked: BlockedTagsStore
    ) {
        let ratings = content.preferences.queryValues
        let types = formats.preferences.queryValues
        let blockedIDs = blocked.blocked.ids
        Task {
            await repository.updateContentRatings(ratings)
            await repository.updateFormats(types)
            await library.updateFormats(types)
            await repository.updateBlockedTags(blockedIDs)
            // Lets a blend exclude what the reader already tracks. Nil when
            // unauthenticated, which is the ordinary case and not a failure.
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
