import AppIntents
import Foundation

/// Any series in the bundled offline catalogue, not only the reader's
/// library.
///
/// `LibrarySeriesEntity`/`LibrarySeriesQuery` are library-only by design
/// (see that file's own doc) — right for "Open a series", wrong for "Add a
/// series", which by definition is about a series not in the library yet.
/// This searches the same `OfflineCatalogue` the app's own search screen
/// falls back to offline, rather than a second data path.
struct CatalogueSeriesEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Series")
    static let defaultQuery = CatalogueSeriesQuery()

    let id: Int
    let title: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)")
    }
}

struct CatalogueSeriesQuery: EntityStringQuery {
    /// `identifiers` round-trips ids Shortcuts already resolved (e.g. a
    /// saved shortcut re-running) back to a display title.
    ///
    /// `OfflineCatalogue.titles(for:)` is the one lookup it offers for a
    /// known set of ids — used already by "Similar by description" for the
    /// same reason: one dictionary pass over the bundled index instead of
    /// one request per id.
    func entities(for identifiers: [Int]) async throws -> [CatalogueSeriesEntity] {
        guard let services = await IntentBridge.shared.services else { return [] }
        let titles = await services.offlineCatalogue.titles(for: identifiers)
        return identifiers.compactMap { id in titles[id].map { CatalogueSeriesEntity(id: id, title: $0) } }
    }

    /// A plain title search against the bundled index — no filters, since
    /// Shortcuts is choosing one series by name, not browsing a shelf.
    func entities(matching string: String) async throws -> [CatalogueSeriesEntity] {
        guard let services = await IntentBridge.shared.services else { return [] }
        let hits = await services.offlineCatalogue.matches(
            SearchQuery(text: string), allowedRatings: [], allowedTypes: [], blockedTags: [],
            limit: 10, offset: 0
        )
        return hits.map {
            CatalogueSeriesEntity(id: $0.series.id, title: $0.series.displayTitle ?? "Untitled series")
        }
    }
}
