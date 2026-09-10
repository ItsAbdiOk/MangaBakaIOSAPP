import Foundation
import Testing
@testable import MangaBaka

/// Grouping a series' tags. Solo Leveling carries 146 across seventeen groups,
/// which is a wall as a flat list and a table of contents once grouped.
@Suite("Tag grouping")
struct TagGroupingTests {
    private func tag(
        id: Int,
        name: String,
        path: String? = nil,
        genre: Bool = false,
        spoiler: Bool = false,
        weight: String = "unweighted",
        impliedBy: [Int] = [],
        rating: String? = "safe"
    ) -> SeriesTag {
        SeriesTag(
            id: id,
            name: name,
            namePath: path ?? "Themes > \(name)",
            isGenre: genre,
            isSpoiler: spoiler,
            isExplicit: false,
            impliedByTagIds: impliedBy,
            contentRating: rating,
            weight: weight,
            seriesCount: nil
        )
    }

    // MARK: Groups

    /// The first segment of `name_path` is the group; genres are lifted out of
    /// their own path because a reader scans for them first.
    @Test("Tags land in the group their path names")
    func groupsFromPath() {
        let tags = [
            tag(id: 1, name: "Action", genre: true),
            tag(id: 2, name: "Politics", path: "Themes > Politics"),
            tag(id: 3, name: "Dungeon", path: "Locations > Dungeon")
        ]
        let groups = TagGrouping.groups(from: tags, allowedRatings: nil)
        #expect(groups.map(\.name) == ["Genres", "Themes", "Locations"])
    }

    /// Coarsest first, and anything the API adds later falls to the end rather
    /// than disappearing.
    @Test("An unknown group sorts last, not away")
    func unknownGroupSurvives() {
        let tags = [
            tag(id: 1, name: "Whatever", path: "Newly Invented Group > Whatever"),
            tag(id: 2, name: "Action", genre: true)
        ]
        let groups = TagGrouping.groups(from: tags, allowedRatings: nil)
        #expect(groups.map(\.name) == ["Genres", "Newly Invented Group"])
    }

    @Test("A tag with no path is not lost")
    func pathlessTag() {
        let bare = SeriesTag(
            id: 1, name: "Loose", namePath: nil, isGenre: false, isSpoiler: false,
            isExplicit: false, impliedByTagIds: nil, contentRating: nil,
            weight: nil, seriesCount: nil
        )
        let groups = TagGrouping.groups(from: [bare], allowedRatings: nil)
        #expect(groups.first?.name == "Other")
        #expect(groups.first?.tags.count == 1)
    }

    // MARK: Order

    /// The ordering signal the app never had. A flat list put "Language
    /// Barrier" beside "Level System" as though they described the series
    /// equally well.
    @Test("Core tags lead their group")
    func weightOrdersWithinGroup() {
        let tags = [
            tag(id: 1, name: "Incidental one", weight: "incidental"),
            tag(id: 2, name: "Core one", weight: "core"),
            tag(id: 3, name: "Recurrent one", weight: "recurrent")
        ]
        let group = TagGrouping.groups(from: tags, allowedRatings: nil).first
        #expect(group?.tags.map(\.name) == ["Core one", "Recurrent one", "Incidental one"])
    }

    @Test("Weights rank as the API means them", arguments: [
        ("core", 0), ("defining", 1), ("recurrent", 2), ("incidental", 3), ("unweighted", 4)
    ])
    func weightRanking(_ raw: String, _ rank: Int) {
        #expect(SeriesTag.Weight(raw).rawValue == rank)
    }

    /// An unknown weight must not sort above a core tag.
    @Test("An unrecognised weight sorts last")
    func unknownWeight() {
        #expect(SeriesTag.Weight("brand-new") == .unweighted)
        #expect(SeriesTag.Weight(nil) == .unweighted)
    }

    /// Matched by id, not by name. The taste endpoint returns genre tags and a
    /// series page lists fine-grained ones, so name matching found exactly one
    /// tag in a series carrying 146 — which is what prompted this.
    @Test("The reader's own tags lead, ahead even of core")
    func favouredLeadByID() {
        let tags = [
            tag(id: 1, name: "Core one", weight: "core"),
            tag(id: 2, name: "Mine", weight: "unweighted")
        ]
        let group = TagGrouping.groups(from: tags, allowedRatings: nil, favouredIDs: [2]).first
        #expect(group?.tags.map(\.name) == ["Mine", "Core one"])
    }

    /// Same weight, same group: alphabetical, so the order does not shuffle
    /// between launches.
    @Test("Ties break alphabetically")
    func stableTies() {
        let tags = [
            tag(id: 1, name: "Zebra", weight: "core"),
            tag(id: 2, name: "Apple", weight: "core")
        ]
        let group = TagGrouping.groups(from: tags, allowedRatings: nil).first
        #expect(group?.tags.map(\.name) == ["Apple", "Zebra"])
    }

    // MARK: Content filter

    /// A tag is rated independently of its series, and an explicit tag *name*
    /// is itself the thing someone filtering content does not want to read.
    @Test("A tag the reader excluded is not shown")
    func filtersTagsByRating() {
        let tags = [
            tag(id: 1, name: "Fine", rating: "safe"),
            tag(id: 2, name: "Not fine", rating: "pornographic")
        ]
        let groups = TagGrouping.groups(from: tags, allowedRatings: ["safe", "suggestive"])
        #expect(groups.flatMap(\.tags).map(\.name) == ["Fine"])
    }

    @Test("No filter set means everything")
    func nilRatingsAllowAll() {
        let tags = [tag(id: 1, name: "A", rating: "pornographic")]
        #expect(TagGrouping.groups(from: tags, allowedRatings: nil).flatMap(\.tags).count == 1)
    }

    // MARK: Implication and spoilers

    /// "Murder" arrives implied by "Crimes". Showing both without saying so
    /// reads as the API repeating itself.
    @Test("An implied tag knows it was implied")
    func impliedFlag() {
        #expect(tag(id: 1, name: "Murder", impliedBy: [357]).isImplied)
        #expect(!tag(id: 2, name: "Crimes").isImplied)
    }

    @Test("A spoiler tag is marked as one")
    func spoilerFlag() {
        #expect(tag(id: 1, name: "Twist", spoiler: true).spoils)
        #expect(!tag(id: 2, name: "Plain").spoils)
    }

    /// The middle of the path is what makes an implied tag make sense: it says
    /// the tag is a kind of something.
    @Test("Lineage is the path without the group or the name")
    func lineage() {
        let deep = tag(id: 1, name: "Large Scale Battles",
                       path: "Activities > Conflict > Large Scale Battles")
        #expect(deep.lineage == "Conflict")

        let shallow = tag(id: 2, name: "Politics", path: "Themes > Politics")
        #expect(shallow.lineage == nil)
    }
}
