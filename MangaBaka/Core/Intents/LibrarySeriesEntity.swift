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
    @MainActor
    private func entries() async -> [LibraryEntry] {
        guard let services = IntentBridge.shared.services else { return [] }
        return await services.librarySnapshot.all()
    }

    func entities(for identifiers: [Int]) async throws -> [LibrarySeriesEntity] {
        let wanted = Set(identifiers)
        return await entries().filter { wanted.contains($0.seriesId) }.map(LibrarySeriesEntity.init)
    }

    /// The same match the app's own search uses, so a romanised or native
    /// title finds it here too.
    func entities(matching string: String) async throws -> [LibrarySeriesEntity] {
        await entries()
            .filter { $0.series?.matches(string) ?? false }
            .map(LibrarySeriesEntity.init)
    }

    /// What Shortcuts offers before anything is typed: what is being read.
    func suggestedEntities() async throws -> [LibrarySeriesEntity] {
        await entries()
            .filter { $0.state == .reading }
            .prefix(10)
            .map(LibrarySeriesEntity.init)
    }
}
