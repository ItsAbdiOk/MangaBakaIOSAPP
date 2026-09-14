import Foundation
import Observation

/// The one door between App Intents and the running app.
///
/// An intent runs in the app's process but outside its view tree, so it has
/// no `AppServices` handed to it and no path to push a series. This holds
/// both: the services, set once when the app is made, and a series id the
/// root view watches and opens. A singleton because the intents framework
/// instantiates intents itself, with no way to inject anything.
@MainActor
@Observable
final class IntentBridge {
    static let shared = IntentBridge()

    /// What an intent may read. Nil until `MangaBakaApp` has built the
    /// services, which is before any intent can run in this process.
    @ObservationIgnored var services: AppServices?

    /// One request to open one series.
    ///
    /// A request rather than a bare `Int` because `RootView` keys a
    /// `.task(id:)` on it, and a bare id makes two things impossible to tell
    /// apart: "open 42" and "open 42 again". The `token` makes every request
    /// distinct, so a second tap on the same series re-opens it — which a
    /// bare id could never do — and, more importantly, so the task does not
    /// have to clear the id it is keyed on in order to avoid re-running.
    struct Open: Equatable, Sendable {
        let id: Int
        let token = UUID()
    }

    /// A series an intent, a widget or a web link asked to open; the root view
    /// clears it once it actually has.
    ///
    /// This was `pendingSeriesID: Int?`, and `RootView`'s task set it to nil
    /// as its *first* statement — writing to the `@Observable` value its own
    /// `.task(id:)` was keyed on. SwiftUI then cancelled the running task and
    /// started a fresh one, which returned at the guard; the cancelled one
    /// resumed from its first `await` and hit gap 76's `Task.isCancelled`
    /// guards, so it returned too. Every Siri "Open X", every widget tap and
    /// every mangabaka.org link for a series *not already in the library* was
    /// a dead tap that spent a request first. Library series still opened,
    /// because that branch has no cancellation guard — so the failure was
    /// invisible on a stocked library and total on an empty one, which is the
    /// state a new installer is in (second-pass review S2, 2026-09-14).
    var pending: Open?

    private init() {}
}
