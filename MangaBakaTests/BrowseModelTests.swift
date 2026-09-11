import Foundation
import Testing
@testable import MangaBaka

/// Which tags are worth listing, out of seven thousand.
@Suite("Browse tags")
@MainActor
struct BrowseModelTests {
    private func tag(
        _ id: Int,
        _ name: String,
        path: String? = nil,
        count: Int? = 100,
        spoiler: Bool = false,
        mergedWith: Int? = nil
    ) throws -> MangaBaka.Tag {
        let merged = mergedWith.map(String.init) ?? "null"
        return try Fixture.decoder().decode(MangaBaka.Tag.self, from: Data("""
        {"id":\(id),"name":"\(name)","name_path":"\(path ?? name)",
         "series_count":\(count.map(String.init) ?? "null"),
         "is_spoiler":\(spoiler),"merged_with":\(merged)}
        """.utf8))
    }

    private func model(_ tags: [MangaBaka.Tag]) -> BrowseModel {
        let model = BrowseModel(catalogue: CatalogueService(client: APIClient(
            baseURL: URL(string: "https://api.example.invalid").unsafeTestURL,
            tokenProvider: UnauthenticatedTokenProvider()
        )))
        model.applyForTesting(tags: tags, genres: [])
        return model
    }

    /// The fetch is the first N tags in the API's order, not the N most used
    /// — Romance is absent from the first 500 — so the subtitle must not
    /// claim "most-used".
    @Test("The subtitle does not claim the tags are the most used")
    func subtitleDoesNotOverclaim() throws {
        let subtitle = model([try tag(1, "Action", count: 10)]).subtitle
        #expect(!subtitle.localizedCaseInsensitiveContains("most"))
        #expect(subtitle.contains("1 of the tags"))
    }

    /// A merged tag points at a survivor. Listing it sends the reader nowhere.
    @Test("Merged tags are never listed")
    func mergedAreHidden() throws {
        let tags = [try tag(1, "Live"), try tag(2, "Dead", mergedWith: 1)]
        #expect(model(tags).visibleTags.map(\.name) == ["Live"])
    }

    /// A tag list is exactly where a plot twist gets spoiled by accident.
    @Test("Spoiler tags stay hidden until asked for")
    func spoilersHiddenByDefault() throws {
        let tags = [try tag(1, "Boxing"), try tag(2, "Is Actually Dead", spoiler: true)]
        let subject = model(tags)

        #expect(subject.visibleTags.map(\.name) == ["Boxing"])
        subject.showsSpoilers = true
        #expect(subject.visibleTags.count == 2)
    }

    /// A root with nothing behind it is a heading, not a destination.
    @Test("Tags carrying no series are not offered")
    func emptyTagsHidden() throws {
        let tags = [try tag(1, "Activities", count: 0), try tag(2, "Boxing", count: 19)]
        #expect(model(tags).visibleTags.map(\.name) == ["Boxing"])
    }

    /// The tree is the interesting part: 7,105 flat tags is a wall.
    @Test("Tags are grouped by the root of their path, biggest group first")
    func groupsByPathRoot() throws {
        let tags = [
            try tag(1, "Boxing", path: "Activities > Boxing", count: 19),
            try tag(2, "Airsoft", path: "Activities > Airsoft", count: 14),
            try tag(3, "Vampires", path: "Beings > Vampires", count: 900)
        ]
        let sections = model(tags).sections
        #expect(sections.first?.name == "Activities")
        #expect(sections.first?.tags.count == 2)
        // Within a section, the heaviest tag leads.
        #expect(sections.first?.tags.first?.name == "Boxing")
    }
}
