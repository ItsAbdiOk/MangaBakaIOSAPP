import SwiftUI

@main
struct MangaBakaApp: App {
    private let repository: SeriesRepository

    init() {
        let info = Bundle.main.infoDictionary

        // Falls back to the documented production host if the build setting is
        // missing, so a misconfigured xcconfig cannot produce a crash.
        let base = (info?["MB_API_BASE_URL"] as? String)
            .flatMap(URL.init(string:))
            ?? URL(string: "https://api.mangabaka.org").unsafelyUnwrappedFallback

        // Unauthenticated is a fully functional mode: every discovery endpoint
        // is public. A PAT is picked up only if the developer supplied one.
        let provider: TokenProvider = PATTokenProvider(infoDictionary: info)
            ?? UnauthenticatedTokenProvider()

        let client = APIClient(baseURL: base, tokenProvider: provider)

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

        repository = SeriesRepository(client: client, database: database)
    }

    var body: some Scene {
        WindowGroup {
            DiscoveryView(model: DiscoveryModel(repository: repository))
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
