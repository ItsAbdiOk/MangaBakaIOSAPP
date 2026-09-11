import Foundation
import os

/// Named markers around the moments a reader actually waits for.
///
/// Instruments can already tell you which function ran for how long. It cannot
/// tell you how long it took from tapping a cover to the page being readable,
/// because that is not a function — it spans a navigation, three concurrent
/// requests and an image decode. These name those spans.
///
/// **Free when nobody is listening.** `OSSignposter` compiles to a check
/// against a disabled log, so this costs nothing in a shipped build with no
/// profiler attached.
enum Signposts {
    /// One subsystem, one category, so everything shows on one Instruments
    /// track in the order it happened rather than scattered across several.
    static let signposter = OSSignposter(
        subsystem: "dev.abdirahmanmohamed.mangabaka",
        category: "journeys"
    )

    /// Wraps an await in a named interval.
    ///
    /// Takes the name as a `StaticString` because that is what the signpost API
    /// requires: the name has to exist before the app runs so the profiler can
    /// resolve it.
    /// `isolated (any Actor)?` so a caller's isolation is inherited rather
    /// than crossed. Without it the closure is treated as leaving the actor it
    /// was written in, and every `@MainActor` model that wants to measure
    /// something has to make its own state Sendable to do it.
    static func measure<T>(
        _ name: StaticString,
        isolation: isolated (any Actor)? = #isolation,
        _ body: () async -> T
    ) async -> T {
        let id = signposter.makeSignpostID()
        let state = signposter.beginInterval(name, id: id)
        let result = await body()
        signposter.endInterval(name, state)
        return result
    }

    /// The synchronous form, for work that happens before there is anything
    /// to await — the composition root above all. The launch number quoted
    /// in findings-todo (0.08 ms) was `didFinishLaunching`, which this app
    /// does nothing in; the construction that matters happens after it, in
    /// `AppServices.init`, and had no interval around it.
    static func measure<T>(_ name: StaticString, _ body: () throws -> T) rethrows -> T {
        let id = signposter.makeSignpostID()
        let state = signposter.beginInterval(name, id: id)
        defer { signposter.endInterval(name, state) }
        return try body()
    }
}
