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

    private static let loadResult: (tags: [Tag], failed: Bool) = load()

    /// The bundled taxonomy, decoded once and cached for the process
    /// lifetime — 2,686 rows is cheap to hold, expensive to re-decode per
    /// sheet open.
    static func bundled() -> [Tag] { loadResult.tags }

    /// Forces the lazy `loadResult` to run now, on whichever thread calls
    /// this, instead of on whichever caller happens to ask first.
    ///
    /// Two of `bundled()`'s four callers are views — `TagPickerSheet.swift:364`
    /// and `BlockedTagsSection.swift:207` — so if the picker opens before
    /// anything else has touched `TagTaxonomy`, the file read and 2,686-row
    /// decode run synchronously on the main thread. GUESS 10–30 ms
    /// (unmeasured; `measure { }` over `load()` would settle it) — not
    /// dropped-frame territory by itself, but free to avoid entirely by
    /// calling this from a background task before the picker can open.
    /// `nonisolated` so a background caller — and a test — can call it from
    /// any isolation without hopping actors first.
    ///
    /// Wire it in from `OfflineCatalogue`'s background setup with one line:
    /// `TagTaxonomy.warm()` (belongs to another lane; not called from here).
    nonisolated static func warm() {
        _ = loadResult
    }

    /// Whether the bundled resource was missing, unreadable, or failed to
    /// decode — distinguishing a packaging bug from a taxonomy that
    /// genuinely has nothing in it, which `bundled()` alone cannot: both
    /// answer `[]`. Additive: `bundled()`'s signature and existing callers
    /// are unchanged, since the two failures already surface the same
    /// "empty offline list" and every caller today only reads the list.
    /// `let`, not `var` — a mutable global would need actor isolation under
    /// strict concurrency; a tuple computed once alongside `loadResult`
    /// needs none.
    static var loadFailed: Bool { loadResult.failed }

    /// The bundled list with a live page folded in, by id.
    ///
    /// **Fold, never replace.** `/v1/tags?limit=500` is the first 500 rows in
    /// root-alphabetical order — measured 2026-09-13: four of the seventeen
    /// roots (Activities, Audience Demographics, Character Archetype,
    /// Character Traits), `pagination.count` 7,146, `next` set. The picker
    /// used to do `tags = live` when that landed, so going online *lost*
    /// Themes, Settings, Relationship and the other thirteen groups, and the
    /// placeholder shrank from "Search 2,686 tags" to "Search 500 tags".
    ///
    /// Where both have a row the live one wins: it carries `contentRating`
    /// and today's `seriesCount`, which the bundled row cannot. Rows only
    /// the bundle has are kept as they are — a year stale, but present.
    /// Nothing is filtered here; callers apply `isUsable` as they already do.
    static func merge(bundled: [Tag], live: [Tag]) -> [Tag] {
        // The bundled file has three unmerged twins sharing a path but not
        // an id (see `load`), so keying by id is safe; `uniquingKeysWith`
        // only guards against a live page repeating itself.
        var byId = Dictionary(bundled.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for tag in live { byId[tag.id] = tag }
        // Same order `load` and `CatalogueService.tags` use, with the name
        // as a tie-break so a dictionary walk cannot reorder equal counts
        // between two body passes.
        return byId.values.sorted {
            let (left, right) = ($0.seriesCount ?? 0, $1.seriesCount ?? 0)
            return left == right ? $0.name < $1.name : left > right
        }
    }

    private static func load() -> (tags: [Tag], failed: Bool) {
        guard let url = Bundle.main.url(forResource: "TagTaxonomy", withExtension: "json") else {
            // Missing from the bundle is a packaging bug, not a network
            // failure: the picker falls back to an empty offline list and the
            // network fetch that follows still works.
            return ([], true)
        }
        guard let data = try? Data(contentsOf: url) else { return ([], true) }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let rows = try? decoder.decode([Row].self, from: data) else { return ([], true) }

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
        return (tags.sorted { $0.seriesCount ?? 0 > $1.seriesCount ?? 0 }, false)
    }
}

/// Who a tag list is being shown to: what they allow, and what they blocked.
///
/// The picker used to show every usable tag to everyone (C#5): a reader on
/// the default safe + suggestive setting could browse "Sexual Content" in a
/// filter sheet, and a tag blocked in Settings could be picked into a search
/// that then sent `tag=X&tag_not=<id of X>` — measured 2026-09-13,
/// `tag=Isekai&tag_not=94` answers 0 — and the empty state advised loosening
/// a filter the reader could not see. Its own value type, not a view
/// property, so the rule is testable without mounting the sheet.
struct TagAudience: Equatable, Sendable {
    /// `ContentPreferences.queryValues` — "safe", "suggestive", …
    var allowedRatings: Set<String>
    /// Spoiler tags are withheld by default, as `BrowseModel.visibleTags`
    /// already does: a tag list is exactly where a plot twist gets spoiled
    /// by accident.
    var showsSpoilers: Bool
    /// `BlockedTags.ids`.
    var blockedIds: Set<Int>

    /// The reader who has changed nothing in Settings. What a caller gets
    /// until the real stores are wired in — conservative on purpose, since
    /// showing less to a reader who allowed more is a nuisance and showing
    /// more to one who did not is the bug this exists to close.
    static let `default` = TagAudience(
        allowedRatings: Set(ContentPreferences.default.queryValues),
        showsSpoilers: false,
        blockedIds: []
    )

    /// The bundled taxonomy carries no `content_rating` (`TagTaxonomy.Row`),
    /// and the rating is not a function of the root — live 2026-09-13,
    /// `/v1/tags?q=Sexual Content&limit=60`: of 60 rows under that root, 37
    /// pornographic, 18 erotica, 2 suggestive (Nudity, Exhibitionism), 3 safe
    /// (Mature, Ecchi, Adult). So an unrated row under this root is treated
    /// as erotica — wrong for five of sixty, in the direction of showing
    /// less — until a live row with the real rating replaces it in
    /// `TagTaxonomy.merge`. Elsewhere in the tree the live page was 496
    /// safe of 500, so unrated rows there are shown.
    static let unratedAdultRoot = "Sexual Content"

    /// Whether the row belongs on screen at all.
    func isShown(_ tag: Tag) -> Bool {
        if tag.isSpoiler == true, !showsSpoilers { return false }
        if let rating = tag.contentRating { return allowedRatings.contains(rating) }
        let root = tag.namePath?.components(separatedBy: " > ").first ?? tag.name
        if root == Self.unratedAdultRoot { return allowedRatings.contains("erotica") }
        return true
    }

    /// Shown, but greyed with the reason: hiding it would be the old
    /// silent zero from the other side, with the reader unable to work out
    /// why the tag they know exists is not in the list.
    func isBlocked(_ tag: Tag) -> Bool {
        blockedIds.contains(tag.id)
    }
}
