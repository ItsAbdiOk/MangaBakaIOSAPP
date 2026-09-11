import SwiftUI

@main
struct MangaBakaApp: App {
    /// Everything the app is made of, built once.
    ///
    /// One property rather than nineteen, because the list had grown to the
    /// point where adding anything to it meant fighting the lint rather than
    /// thinking about the thing being added — which is the lint doing its job.
    private let services = AppServices()

    var body: some Scene {
        WindowGroup {
            // THE APPLE-IDIOMATIC BRANCH.
            //
            // The shipping root is below and untouched; this line is the only
            // thing that differs at the top level. Swap them to compare, or
            // check out `main` to see the real app.
            AppleRootView(
                repository: services.repository,
                session: services.session,
                content: services.content,
                formats: services.formats
            )
        }
    }

    /// The shipping app's root, kept here on this branch so the comparison is
    /// one line rather than a merge.
    var shippingBody: some Scene {
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
