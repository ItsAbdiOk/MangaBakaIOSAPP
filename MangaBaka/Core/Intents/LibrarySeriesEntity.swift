import AppIntents
import Foundation

/// A series in the reader's library, as Siri and Shortcuts see it.
///
/// Library only, for the same reason as Spotlight: the catalogue is
/// thousands of series the reader has no relationship with, and "Open
/// <series>" is a request about one they do.
struct LibrarySeriesEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Series")
    static let defaultQuery = LibrarySeriesQuery()

    let id: Int
    let title: String
    /// "Reading · chapter 53 of 120", the same line Spotlight shows.
    let subtitle: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(subtitle)")
    }

    init(entry: LibraryEntry) {
        id = entry.seriesId
        title = entry.series?.displayTitle ?? "Untitled series"
        subtitle = SpotlightIndex.description(for: entry)
    }
}

struct LibrarySeriesQuery: EntityStringQuery {
    /// Gap 106: `all()` swallows the walk's own failure into `[]`, the same
    /// way `library(page:limit:)` does — so "the library could not be read"
    /// and "nothing here matches that name" were the same silence to Siri,
    /// and it said "no match" for both. Throws only when there is nothing
    /// usable at all (no rows, and a reason there are none); stale rows from
    /// an earlier successful walk are still searched, the same as everywhere
    /// else in the app that treats stale content as still useful.
    @MainActor
    private func entries() async throws -> [LibraryEntry] {
        guard let services = IntentBridge.shared.services else { return [] }
        let result = await services.librarySnapshot.load()
        if result.entries.isEmpty, let failure = result.failure {
            throw failure
        }
        return result.entries
    }

    func entities(for identifiers: [Int]) async throws -> [LibrarySeriesEntity] {
        let wanted = Set(identifiers)
        return try await entries().filter { wanted.contains($0.seriesId) }.map(LibrarySeriesEntity.init)
    }

    /// The same match the app's own search uses, so a romanised or native
    /// title finds it here too.
    func entities(matching string: String) async throws -> [LibrarySeriesEntity] {
        try await entries()
            .filter { $0.series?.matches(string) ?? false }
            .map(LibrarySeriesEntity.init)
    }

    /// What Shortcuts offers before anything is typed: what is being read.
    func suggestedEntities() async throws -> [LibrarySeriesEntity] {
        try await entries()
            .filter { $0.state == .reading }
            .prefix(10)
            .map(LibrarySeriesEntity.init)
    }
}
