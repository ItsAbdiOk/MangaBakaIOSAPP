import Foundation

/// A bundled copy of MangaBaka's tag taxonomy, so the tag picker opens
/// instantly and works offline before the network answer arrives.
///
/// Source: MangaBaka's `/v1/tags`, fetched by the sibling Tags Gen project on
/// 2026-08-27 (`Tags Gen/metadata_cache/mangabaka-taxonomy.json`, 2,686 rows).
/// Licensed CC BY-NC-SA 4.0; MangaBaka attribution is already shown elsewhere
/// in the app. Being over a year stale is expected — this is a fast, offline
/// first paint, not a replacement for the live fetch that follows it.
enum TagTaxonomy {
    /// One row of the bundled JSON. A separate type from `Tag` because the
    /// wire shapes differ: this file has `path`/`root` instead of a
    /// `parentId`, and no `description` or `contentRating` at all.
    private struct Row: Decodable {
        let id: Int
        let name: String
        let path: String
        let root: String
        let bucket: String
        let seriesCount: Int
        let level: Int
        let isGenre: Bool
        let isSpoiler: Bool
        let mergedWith: Int?
    }

    private static let cached: [Tag] = load()

    /// The bundled taxonomy, decoded once and cached for the process
    /// lifetime — 2,686 rows is cheap to hold, expensive to re-decode per
    /// sheet open.
    static func bundled() -> [Tag] { cached }

    private static func load() -> [Tag] {
        guard let url = Bundle.main.url(forResource: "TagTaxonomy", withExtension: "json") else {
            // Missing from the bundle is a packaging bug, not a network
            // failure: the picker falls back to an empty offline list and the
            // network fetch that follows still works.
            return []
        }
        guard let data = try? Data(contentsOf: url) else { return [] }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let rows = try? decoder.decode([Row].self, from: data) else { return [] }

        // A merged tag points at a survivor and should never be shown or
        // linked to — the same filter CatalogueService.tags applies to the
        // live fetch.
        let usable = rows.filter { $0.mergedWith == nil }

        // Three paths appear twice in MangaBaka's taxonomy as of the 2026-08-27
        // fetch — "Blunt Female Lead", "Ghost Female Lead" and "Narcissistic
        // Male Lead" each have an unmerged twin with seriesCount 0. Highest
        // count wins, so a child resolves to the parent that actually has
        // series behind it. `uniqueKeysWithValues` traps on these.
        let pathToId = Dictionary(
            usable.sorted { $0.seriesCount > $1.seriesCount }.map { ($0.path, $0.id) },
            uniquingKeysWith: { first, _ in first }
        )

        let tags = usable.map { row -> Tag in
            let parentPath = row.path.components(separatedBy: " > ").dropLast().joined(separator: " > ")
            return Tag(
                id: row.id,
                name: row.name,
                namePath: row.path,
                parentId: parentPath.isEmpty ? nil : pathToId[parentPath],
                level: row.level,
                description: nil,
                seriesCount: row.seriesCount,
                isGenre: row.isGenre,
                isSpoiler: row.isSpoiler,
                mergedWith: row.mergedWith,
                contentRating: nil
            )
        }

        // Same order CatalogueService.tags uses: broadest tag first.
        return tags.sorted { $0.seriesCount ?? 0 > $1.seriesCount ?? 0 }
    }
}
