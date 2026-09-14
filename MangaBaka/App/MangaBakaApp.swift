import SwiftUI

@main
struct MangaBakaApp: App {
    /// Everything the app is made of, built once.
    ///
    /// One property rather than nineteen, because the list had grown to the
    /// point where adding anything to it meant fighting the lint rather than
    /// thinking about the thing being added — which is the lint doing its job.
    ///
    /// Signposted: this is the launch work the 0.08 ms number never included,
    /// visible in Instruments as "Services".
    private let services = Signposts.measure("Services") { AppServices() }

    init() {
        // Before anything asks for an image, and deliberately outside the
        // "Services" signpost above (item 107): replacing `URLCache.shared`
        // opens the replacement's 256 MB disk index synchronously, so
        // measuring it as part of building the app's own objects made that
        // interval about the system's SQLite rather than about this code.
        AppServices.enlargeImageCache()
        // The intents' only way in; see IntentBridge.
        IntentBridge.shared.services = services
    }

    var body: some Scene {
        WindowGroup {
            RootView(
                repository: services.repository,
                shelf: services.shelf,
                history: services.history,
                client: services.client,
                content: services.content,
                formats: services.formats,
                library: services.library,
                schedule: services.schedule,
                characters: services.characters,
                appleBooks: services.appleBooks,
                googleBooks: services.googleBooks,
                releaseFeeds: services.releaseFeeds,
                embeddingIndex: services.embeddingIndex,
                offlineCatalogue: services.offlineCatalogue,
                mangaUpdates: services.mangaUpdates,
                publisherFollows: services.publisherFollows,
                openLibraryCovers: services.openLibraryCovers,
                taste: services.taste,
                catalogue: services.catalogue,
                blockedTags: services.blockedTags,
                lenses: services.lenses,
                recents: services.recents,
                session: services.session,
                calendar: services.calendar,
                librarySnapshot: services.librarySnapshot,
                reminders: services.reminders,
                tokenStore: services.tokenStore,
                hasCredentials: services.hasCredentials,
                databaseWasReset: services.databaseWasReset,
                onboarding: services.onboarding
            )
        }
    }
}
