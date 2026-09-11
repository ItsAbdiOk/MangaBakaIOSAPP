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
                taste: services.taste,
                catalogue: services.catalogue,
                blockedTags: services.blockedTags,
                lenses: services.lenses,
                recents: services.recents,
                session: services.session,
                calendar: services.calendar,
                librarySnapshot: services.librarySnapshot,
                reminders: services.reminders,
                onboarding: services.onboarding
            )
        }
    }
}
