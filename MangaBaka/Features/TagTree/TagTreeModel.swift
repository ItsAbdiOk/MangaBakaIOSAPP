import Foundation

/// The bundled tag taxonomy, reshaped into a tree a screen can drill through
/// one level at a time — `docs/designs/api-opportunities.md` §4 ("The tag
/// tree as a browsing surface"), the last unbuilt item in that doc as of
/// 2026-09-14. `TagTaxonomy` already carries `parentId`/`level`
/// (`TagTaxonomy.swift`); this is the tree derived from that, not a second
/// copy of it.
///
/// Every derivation below is `nonisolated static` over a plain `[Tag]`, so
/// `TagTreeModelTests` can test children/path/descendantIDs without mounting
/// a view — the same split `BrowseView.label(for:)` already uses for its own
/// pure row-label rule.
@MainActor
@Observable
final class TagTreeModel {
    /// The vocabulary this tree is drawn from — the bundled taxonomy by
    /// default, injectable for a test fixture or (later) a live-merged list.
    let tags: [Tag]

    init(tags: [Tag] = TagTaxonomy.bundled()) {
        self.tags = tags
    }

    /// Nothing to draw a tree from — a packaging bug (`TagTaxonomy.loadFailed`)
    /// or a fixture with nothing in it. The view shows a plain message rather
    /// than a blank list that reads as "still loading" (`BrowseModel.subtitle`
    /// draws the same distinction, gap 39, for the same reason).
    var isEmpty: Bool { tags.isEmpty }

    /// Top-level tags, sorted by name.
    var roots: [Tag] { Self.children(of: nil, in: tags) }

    /// Direct children of `parentID`, sorted by name — or, for the root level
    /// (`parentID == nil`), every tag with no parent *plus* any orphan: a tag
    /// whose `parentId` names an id this taxonomy does not have.
    /// `TagTaxonomyTests.parentIdsResolve` holds that the bundled taxonomy has
    /// none today, so this branch is defensive rather than load-bearing — but
    /// dropping an orphan instead would make a future taxonomy edit silently
    /// lose a whole branch, and the entire point of this tree is that every
    /// tag stays reachable by drilling down. Surfacing it at the root costs
    /// nothing but one extra top-level row, so that is the choice made here.
    /// Merged tags (`!tag.isUsable`) are never shown — they point at a
    /// survivor and lead nowhere, same filter as `BrowseModel.visibleTags`.
    nonisolated static func children(of parentID: Int?, in tags: [Tag]) -> [Tag] {
        let ids = Set(tags.map(\.id))
        let usable = tags.filter(\.isUsable)
        let matches: [Tag]
        if let parentID {
            matches = usable.filter { $0.parentId == parentID }
        } else {
            matches = usable.filter { tag in
                guard let parentId = tag.parentId else { return true }
                return !ids.contains(parentId)
            }
        }
        return matches.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    /// Root-to-leaf breadcrumb for `tagID` — `[Activities, Sports, Boxing]`
    /// for Boxing. A tag absent from `tags` answers `[]`.
    ///
    /// Cycle-safe by construction: `visited` stops the walk the moment a tag
    /// would appear twice, so a taxonomy edit that accidentally made a tag its
    /// own ancestor terminates with a short path instead of looping forever —
    /// there is no such cycle in the bundled data today (nothing tests for
    /// one; `parentIdsResolve` only checks dangling ids, not loops), so this
    /// is defensive in the same spirit as the orphan handling above.
    nonisolated static func path(to tagID: Int, in tags: [Tag]) -> [Tag] {
        let byID = Dictionary(tags.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var chain: [Tag] = []
        var visited = Set<Int>()
        var current = byID[tagID]
        while let tag = current, visited.insert(tag.id).inserted {
            chain.append(tag)
            current = tag.parentId.flatMap { byID[$0] }
        }
        return chain.reversed()
    }

    /// Every tag beneath `tagID`, at any depth. Used only to *count* "how
    /// many series live under this whole branch" for the "include sub-tags"
    /// toggle — not to filter a search.
    ///
    /// It cannot filter one: the live API's `tag_mode` has no working OR.
    /// `SearchQuery.tagMode`'s own doc comment: `tag=Isekai&tag=Regression`
    /// answers the same 164 with no mode, `tag_mode=or`, and `tag_mode=and`
    /// (measured 2026-09-13), which means a query naming several tag ids
    /// always narrows to series carrying *all* of them, never "any of
    /// these" — the opposite of what "browse this branch" means. So
    /// `TagTreeSeriesModel` only ever searches the one tapped tag; this set
    /// exists purely for the count shown beside "Browse".
    ///
    /// Iterative with an explicit `visited` set, for the same cycle-safety
    /// as `path(to:in:)`.
    nonisolated static func descendantIDs(of tagID: Int, in tags: [Tag]) -> Set<Int> {
        let childrenByParent = Dictionary(grouping: tags.filter(\.isUsable), by: \.parentId)
        var result = Set<Int>()
        var queue = [tagID]
        var visited = Set<Int>()
        while let id = queue.popLast() {
            guard visited.insert(id).inserted else { continue }
            for child in childrenByParent[id] ?? [] where result.insert(child.id).inserted {
                queue.append(child.id)
            }
        }
        return result
    }

    /// "Action, 12 sub-tags" / "Boxing, no sub-tags" — read once by
    /// VoiceOver instead of three separate stops for the name, a bare number,
    /// and an unlabelled disclosure indicator. The same shape
    /// `BrowseView.label(for:)` builds for its own tag rows, minus the
    /// series count (`BrowseView`'s tags are leaves the reader searches from;
    /// this tree's rows are nodes the reader drills through, so what matters
    /// here is how many ways there are to go deeper).
    nonisolated static func accessibilityLabel(for tag: Tag, childCount: Int) -> String {
        let count = switch childCount {
        case 0: "no sub-tags"
        case 1: "1 sub-tag"
        default: "\(childCount) sub-tags"
        }
        return "\(tag.name), \(count)"
    }
}
