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

    /// A series an intent asked to open; the root view clears it once it has.
    var pendingSeriesID: Int?

    private init() {}
}
