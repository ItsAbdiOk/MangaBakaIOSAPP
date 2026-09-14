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

/// Gap 39 (FAILURES-SUMMARY.md): the subtitle used to check only whether the
/// vocabulary was empty, never whether it had failed or was still loading —
/// so a fetch that failed with nothing cached left "Loading the vocabulary"
/// on screen forever, because that string is exactly what "empty" always
/// produced regardless of cause.
@Suite("Browse vocabulary failure", .serialized)
@MainActor
struct BrowseVocabularyFailureTests {
    private let baseURL = URL(string: "https://api.example.invalid").unsafeTestURL

    private func makeModel() -> BrowseModel {
        BrowseModel(catalogue: CatalogueService(client: APIClient(
            baseURL: baseURL,
            session: URLProtocolStub.makeSession(),
            tokenProvider: UnauthenticatedTokenProvider()
        )))
    }

    /// Expected to fail before the fix with: `subtitle` equal to
    /// "Loading the vocabulary" — the old subtitle only ever checked
    /// `genres.isEmpty && tags.isEmpty`, which stays true after a failed
    /// fetch with nothing cached, so the claim to still be loading never
    /// went away. `isLoading`/`failed` did not exist as a pair at all: the
    /// model only exposed `failure`, and nothing read it.
    @Test("A failed fetch with nothing cached stops claiming to load")
    func failedFetchStopsClaimingToLoad() async {
        URLProtocolStub.setHandler { _ in .fail(URLError(.notConnectedToInternet)) }
        defer { URLProtocolStub.reset() }

        let model = makeModel()
        await model.load()

        #expect(model.isLoading == false)
        #expect(model.failed == true)
        #expect(model.subtitle != "Loading the vocabulary")
    }

    @Test("A successful fetch is never reported as failed")
    func successIsNotFailure() async {
        URLProtocolStub.setHandler { _ in .respond(.init(body: Data(#"{"status":200,"data":[]}"#.utf8))) }
        defer { URLProtocolStub.reset() }

        let model = makeModel()
        await model.load()

        #expect(model.failed == false)
        #expect(model.subtitle != "Loading the vocabulary")
    }
}

/// What VoiceOver actually says on a tag row.
///
/// `AccessibilityTests.tagRowIsOneElement` pinned the *call*
/// (`accessibilityLabel(Self.label(for: tag))`) and nothing else, so a
/// `label(for:)` that returned `""` — or dropped the count, or stopped saying
/// "spoiler tag" — passed it. The call-site pin stays there, because whether
/// the modifier is attached is not observable outside SwiftUI; what the label
/// says is, and it is asserted here.
///
/// Expected to fail against a same-named stub with: `label(for:)` returning
/// anything but these exact strings — an empty body fails all four.
/// Not gated on `SourceTree`: these run on Xcode Cloud, where the pin does not.
@Suite("A tag row says what it is")
struct BrowseTagLabelTests {
    private func tag(name: String, count: Int?, spoiler: Bool?) -> MangaBaka.Tag {
        MangaBaka.Tag(
            id: 1, name: name, namePath: nil, parentId: nil, level: 1,
            description: nil, seriesCount: count, isGenre: nil, isSpoiler: spoiler,
            mergedWith: nil, contentRating: nil
        )
    }

    /// The doc comment's own example.
    @Test("Name and count, comma-separated")
    func nameAndCount() {
        #expect(BrowseView.label(for: tag(name: "Boxing", count: 19, spoiler: false)) == "Boxing, 19 series")
    }

    /// `seriesCount` is nullable on the wire (`Tag.seriesCount`), and a row
    /// that announced "Boxing, series" would be worse than one that just
    /// announced the name.
    @Test("A tag with no count announces only its name")
    func missingCountIsOmitted() {
        #expect(BrowseView.label(for: tag(name: "Boxing", count: nil, spoiler: nil)) == "Boxing")
    }

    /// The reason this label exists at all: a sighted reader sees the spoiler
    /// marker, and without this clause a VoiceOver reader hears the tag with
    /// no warning that it gives the plot away.
    @Test("A spoiler tag says so, last")
    func spoilerIsAnnounced() {
        #expect(
            BrowseView.label(for: tag(name: "Boxing", count: 19, spoiler: true))
                == "Boxing, 19 series, spoiler tag"
        )
        #expect(
            BrowseView.label(for: tag(name: "Boxing", count: nil, spoiler: true))
                == "Boxing, spoiler tag"
        )
    }

    /// `isSpoiler` is `Bool?`: nil is "the API did not say", not "yes".
    @Test("An unknown spoiler flag is not announced as a spoiler")
    func unknownSpoilerIsSilent() {
        #expect(!BrowseView.label(for: tag(name: "Boxing", count: 19, spoiler: nil)).contains("spoiler"))
    }
}
