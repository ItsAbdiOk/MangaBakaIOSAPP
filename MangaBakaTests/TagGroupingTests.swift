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

/// A series' editions, which the mockup drew as something else entirely.
@Suite("Editions")
struct SeriesEditionTests {
    private func edition(
        id: String,
        language: String? = "en",
        publisher: String? = "Ize Press",
        licensed: Bool? = true,
        volumes: Int? = 12,
        medium: String? = "print",
        status: String? = "complete"
    ) -> SeriesEdition {
        let json = """
        {"id": "\(id)",
         "title": "A Series",
         "language": {"iso": \(language.map { "\"\($0)\"" } ?? "null"), "language": null},
         "publisher": {"id": 1, "name": \(publisher.map { "\"\($0)\"" } ?? "null"), "type": "imprint"},
         "medium": \(medium.map { "\"\($0)\"" } ?? "null"),
         "status": \(status.map { "\"\($0)\"" } ?? "null"),
         "licensed": \(licensed.map(String.init) ?? "null"),
         "count_main": \(volumes.map(String.init) ?? "null"),
         "count_extra": null, "start_date": "2021-03-02", "end_date": null}
        """
        guard let decoded = try? Fixture.decoder().decode(SeriesEdition.self, from: Data(json.utf8))
        else { fatalError("SeriesEdition fixture no longer decodes: \(json)") }
        return decoded
    }

    /// The two things a reader is looking for.
    @Test("An edition leads with its language and publisher")
    func headline() {
        #expect(edition(id: "a").headline == "EN · Ize Press")
    }

    /// Only what the API answered. A missing field is left out rather than
    /// printed as unknown.
    @Test("Detail lists only what is known")
    func detailOmitsGaps() {
        #expect(edition(id: "a").detail == "12 volumes · print · complete")
        #expect(edition(id: "b", volumes: nil, medium: nil, status: nil).detail == nil)
    }

    @Test("One volume is not 1 volumes")
    func singularVolume() {
        #expect(edition(id: "a", volumes: 1).detail?.hasPrefix("1 volume ·") == true)
    }

    /// Official first, because that is the one a reader can actually buy. A
    /// scanlation listed above the licensed English release would be the wrong
    /// answer to the question the section exists to answer.
    @Test("Licensed editions lead")
    func licensedFirst() {
        let editions = [
            edition(id: "unofficial", licensed: false, volumes: 40),
            edition(id: "official", licensed: true, volumes: 12)
        ]
        #expect(editions.presentable.map(\.id) == ["official", "unofficial"])
    }

    /// Among equals, the longest run — it is the most complete release.
    @Test("Longer runs lead among equals")
    func longestRunNext() {
        let editions = [
            edition(id: "short", volumes: 3),
            edition(id: "long", volumes: 20)
        ]
        #expect(editions.presentable.map(\.id) == ["long", "short"])
    }

    /// A missing licence flag is not a claim that it is unlicensed, so it must
    /// not be printed as one — it simply loses the "Official" mark.
    @Test("An unknown licence is not called unofficial")
    func unknownLicence() {
        #expect(edition(id: "a", licensed: nil).licensed == nil)
    }

    @Test("A start date yields a year, a missing one yields nothing")
    func startYear() {
        #expect(edition(id: "a").startYear == "2021")
    }
}

/// Grouping fixed one wall and could have built another.
@Suite("The tag section stays scannable", .enabled(if: SourceTree.isAvailable))
struct TagSectionSizeTests {
    /// Seventeen sections of eight chips is more on screen than the flat list
    /// of twelve ever was. Four groups answer what a series *is*; the rest
    /// answer questions a reader only has after deciding to read it.
    @Test("Only the leading groups show until asked")
    func leadingGroupsOnly() throws {
        let source = try SourceTree.read("MangaBaka/Features/Detail/DetailTagSections.swift")
        #expect(source.contains("leadingGroups"))
        #expect(source.contains("showsAllGroups"))
        for group in ["Genres", "Themes", "Narrative Tropes", "Settings"] {
            #expect(source.contains("\"\(group)\""))
        }
    }

    @Test("Groups themselves still collapse")
    func groupsCollapse() throws {
        let source = try SourceTree.read("MangaBaka/Features/Detail/DetailTagSections.swift")
        #expect(source.contains("collapsedPerGroup"))
    }
}
