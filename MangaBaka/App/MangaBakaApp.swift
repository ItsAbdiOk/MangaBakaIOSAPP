import SwiftUI

@main
struct MangaBakaApp: App {
    private let repository: SeriesRepository
    private let shelf: ShelfStore
    private let client: APIClient
    private let content: ContentPreferencesStore
    private let formats: FormatPreferencesStore
    private let library: LibraryService
    private let schedule: ReleaseScheduleService
    private let characters = ShikimoriClient()
    private let catalogue: CatalogueService
    private let blockedTags: BlockedTagsStore
    private let lenses = SearchLensStore()
    private let onboarding = OnboardingState()

    init() {
        // Cover art dominates this app's network use and is highly re-requested
        // — the same covers appear across rows, search results and detail
        // screens. URLSession's default disk cache is far too small for that,
        // so scrolling back up re-downloads artwork the device already had.
        URLCache.shared = URLCache(
            memoryCapacity: 32 * 1024 * 1024,
            diskCapacity: 256 * 1024 * 1024
        )

        let info = Bundle.main.infoDictionary

        // Falls back to the documented production host if the build setting is
        // missing, so a misconfigured xcconfig cannot produce a crash.
        let base = (info?["MB_API_BASE_URL"] as? String)
            .flatMap(URL.init(string:))
            ?? URL(string: "https://api.mangabaka.org").unsafelyUnwrappedFallback

        // Resolved per request rather than chosen once, so a token entered in
        // Settings takes effect immediately instead of after a relaunch.
        let provider = ResolvingTokenProvider(infoDictionary: info)

        let apiClient = APIClient(baseURL: base, tokenProvider: provider)
        client = apiClient

        // A cache that cannot be opened is not worth crashing over: fall back
        // to an in-memory one so the app still works, just without offline
        // support until the next launch.
        let database: AppDatabase
        do {
            database = try AppDatabase.onDisk()
        } catch {
            database = (try? AppDatabase.inMemory()) ?? {
                preconditionFailure("An in-memory SQLite database could not be opened.")
            }()
        }

        repository = SeriesRepository(client: apiClient, database: database)
        shelf = ShelfStore(database: database)

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

        schedule = ReleaseScheduleService(library: libraryService, database: database)
        catalogue = CatalogueService(client: apiClient)

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

        // Apply the stored choices before the first request goes out, or the
        // opening feed would be fetched under the default filters.
        let initialRatings = store.preferences.queryValues
        let initialFormats = formatStore.preferences.queryValues
        Task {
            await built.updateContentRatings(initialRatings)
            await built.updateFormats(initialFormats)
            await libraryService.updateFormats(initialFormats)

            // Lets a blend exclude what the reader already tracks. Nil when
            // unauthenticated, which is the ordinary case and not a failure.
            await built.updateBlockedTags(blocked.blocked.ids)
            await built.updateLibraryExclusion(userID: libraryService.profileID())
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView(
                repository: repository,
                shelf: shelf,
                client: client,
                content: content,
                formats: formats,
                library: library,
                schedule: schedule,
                characters: characters,
                catalogue: catalogue,
                blockedTags: blockedTags,
                lenses: lenses,
                onboarding: onboarding
            )
        }
    }
}

private extension Optional where Wrapped == URL {
    /// The literal above is a compile-time constant known to parse. This exists
    /// so the call site reads honestly instead of using `!`, which CLAUDE.md
    /// forbids on anything reachable from real input.
    var unsafelyUnwrappedFallback: URL {
        guard let self else {
            preconditionFailure("Hard-coded base URL literal failed to parse.")
        }
        return self
    }
}
