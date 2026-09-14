import AppIntents
import Foundation

/// So Shortcuts and Siri can offer every status by name, not just
/// `.rawValue`. `CaseIterable` conformance already exists on `State` itself;
/// this only adds the AppIntents-facing labels, in the same words
/// `State.title` already uses in the UI — kept in this file (rather than
/// `LibraryEntry.swift`, which this task does not own) as an extension, the
/// same way any other module would add a framework conformance without
/// touching the type's own file.
extension LibraryEntry.State: AppEnum {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Reading status")
    static let caseDisplayRepresentations: [LibraryEntry.State: DisplayRepresentation] = [
        .considering: "Considering",
        .planToRead: "Plan to read",
        .reading: "Reading",
        .rereading: "Rereading",
        .paused: "Paused",
        .completed: "Completed",
        .dropped: "Dropped"
    ]
}

/// "Add <series> to my library in MangaBaka, as <status>."
struct AddToLibraryIntent: AppIntent {
    static let title: LocalizedStringResource = "Add to library"
    static let description = IntentDescription("Adds a series to your MangaBaka library with a status.")

    @Parameter(title: "Series")
    var series: CatalogueSeriesEntity

    @Parameter(title: "Status", default: .planToRead)
    var status: LibraryEntry.State

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$series) to my library as \(\.$status)")
    }

    /// What a reader hears when there is no token to write with. A constant
    /// rather than an inline literal so `AddToLibraryIntentTests` can pin it
    /// without driving `perform()` through a real `AppServices` (heavy —
    /// no test in this codebase constructs one; `DueThisWeekIntent`'s own
    /// equivalent dialogs are untested for the same reason, only the
    /// free-function `DueThisWeek.sentence` is).
    static let noAccountDialog = "Sign in to MangaBaka in Settings first."

    /// The success line, extracted the same way — so the exact wording
    /// (which names the status, not just "Added") is pinned by a test that
    /// does not need a live library write.
    static func addedDialog(title: String, status: LibraryEntry.State) -> String {
        "Added \(title) as \(status.title)."
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let services = IntentBridge.shared.services else {
            return .result(dialog: "Open MangaBaka first, then try again.")
        }
        // `hasCredentials`, not a bare token read: `AppServices`'s own doc
        // says it is the one place Settings, Discover and now this agree on
        // whether a request can even be signed. A write attempted with no
        // token would 401 and hand back a technical error where the reader
        // needs "sign in first" instead — the crash this task's brief
        // explicitly rules out.
        guard services.hasCredentials() else {
            return .result(dialog: "\(Self.noAccountDialog)")
        }
        do {
            _ = try await services.library.add(seriesId: series.id, state: status)
        } catch {
            return .result(dialog: "\(error.userFacingMessage)")
        }
        // Patches the shared store the same way `LibraryControlModel.add`
        // does (`Features/Detail/SeriesDetailView+Store.swift`), so a
        // Library tab already on screen shows the new entry without
        // waiting for its next walk — reusing its `placeholderID(for:)`
        // rather than re-deriving the same guess here. See that function's
        // own comment for why a placeholder id is used ahead of the
        // server's real one.
        let placeholder = LibraryEntry(
            id: LibraryControlModel.placeholderID(for: series.id), seriesId: series.id, state: status,
            progressChapter: nil, progressVolume: nil, rating: nil, note: nil, startDate: nil,
            finishDate: nil, numberOfRereads: nil, priority: nil, isPrivate: nil, readLink: nil, series: nil
        )
        services.session.library.insert(placeholder)
        return .result(dialog: "\(Self.addedDialog(title: series.title, status: status))")
    }
}
