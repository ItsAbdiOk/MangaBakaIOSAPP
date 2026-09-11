import Foundation

/// Genres and the tag tree beneath them.
@MainActor
@Observable
final class BrowseModel {
    private(set) var genres: [Genre] = []
    private(set) var tags: [Tag] = []
    private(set) var isLoading = false
    /// Spoiler tags stay hidden until asked for.
    var showsSpoilers = false

    private let catalogue: CatalogueService

    init(catalogue: CatalogueService) {
        self.catalogue = catalogue
    }

    /// "46 genres, or 200 of the tags beneath them."
    ///
    /// Not "the 200 most-used": `/v1/tags?limit=200` is the first 200 in the
    /// API's own order, which is not by use — Romance, a tag on thousands of
    /// series, is absent from the first 500 (measured 2026-09-10, see
    /// `CatalogueService.searchTags`). The list is sorted by use after it
    /// arrives, which orders what was fetched and cannot change what was.
    var subtitle: String {
        guard !genres.isEmpty || !tags.isEmpty else { return "Loading the vocabulary" }
        return "\(genres.count) genres, or \(tags.count.formatted()) of the tags beneath them."
    }

    /// Tags worth listing, grouped under their root.
    ///
    /// Merged tags are never shown: they point at a survivor and lead nowhere.
    /// Spoiler tags are withheld until asked for, because a tag list is exactly
    /// where a plot twist gets spoiled by accident.
    var visibleTags: [Tag] {
        tags.filter { tag in
            guard tag.isUsable else { return false }
            guard showsSpoilers || tag.isSpoiler != true else { return false }
            // A root with no series behind it is a heading, not a destination.
            return (tag.seriesCount ?? 0) > 0
        }
    }

    /// Grouped by the first segment of `name_path`, so the tree reads as a tree.
    var sections: [(name: String, tags: [Tag])] {
        let grouped = Dictionary(grouping: visibleTags) { tag in
            tag.namePath?.components(separatedBy: " > ").first ?? "Other"
        }
        return grouped
            .map { (name: $0.key, tags: $0.value.sorted { ($0.seriesCount ?? 0) > ($1.seriesCount ?? 0) }) }
            .sorted { $0.tags.count > $1.tags.count }
    }

    var spoilerLabel: String { showsSpoilers ? "Hiding nothing" : "Spoilers hidden" }

    /// Injects a vocabulary so the filtering rules can be tested without a
    /// network. Which tags are worth listing is the judgement here.
    func applyForTesting(tags: [Tag], genres: [Genre]) {
        self.tags = tags
        self.genres = genres
    }

    func load() async {
        guard tags.isEmpty else { return }
        isLoading = true
        defer { isLoading = false }
        genres = await catalogue.genres()
        tags = await catalogue.tags(limit: 200)
    }
}
