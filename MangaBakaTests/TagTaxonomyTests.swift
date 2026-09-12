import Testing
import Foundation
@testable import MangaBaka

/// The bundled tag taxonomy: the offline fallback the tag picker shows before
/// the network answer arrives. See `TagTaxonomy`.
@Suite("Tag taxonomy")
struct TagTaxonomyTests {
    @Test("decodes to well over the known 2,686 rows, minus nothing surprising")
    func decodesEnoughTags() {
        #expect(TagTaxonomy.bundled().count > 2_500)
    }

    @Test("merged tags are absent")
    func mergedTagsAreAbsent() {
        // The source file carries mergedWith for a tag that points at a
        // survivor; `bundled()` must drop those before anyone sees them.
        #expect(TagTaxonomy.bundled().allSatisfy { $0.isUsable })
    }

    @Test("a known root tag exists by id")
    func knownRootTag() throws {
        let activities = try #require(TagTaxonomy.bundled().first { $0.id == 537 })
        #expect(activities.name == "Activities")
        #expect(activities.level == 1)
    }

    @Test("a known leaf tag exists by its full path")
    func knownLeafTag() throws {
        let calligraphy = try #require(
            TagTaxonomy.bundled().first { $0.namePath == "Activities > Arts & Crafts > Calligraphy" }
        )
        #expect(calligraphy.name == "Calligraphy")
    }

    @Test("duplicate paths in the source do not trap, and resolve to the populated tag")
    func duplicatePathsResolveToThePopulatedTag() throws {
        // MangaBaka ships three paths twice, each a real tag plus an unmerged
        // twin with seriesCount 0. Before the uniquingKeysWith fix this did not
        // fail — it trapped in Dictionary(uniqueKeysWithValues:) and took the
        // whole test target down with it.
        for path in [
            "Character Types > Female Lead > Blunt Female Lead",
            "Character Types > Female Lead > Ghost Female Lead",
            "Character Types > Male Lead > Narcissistic Male Lead"
        ] {
            let matches = TagTaxonomy.bundled().filter { $0.namePath == path }
            #expect(matches.count == 2, "\(path) should still be the known duplicate pair")
            #expect(matches.contains { ($0.seriesCount ?? 0) > 0 }, "\(path) lost its populated tag")
        }
    }

    @Test("every tag with a parent resolves to a real parent tag")
    func parentIdsResolve() {
        let ids = Set(TagTaxonomy.bundled().map(\.id))
        let orphans = TagTaxonomy.bundled().filter { tag in
            guard let parentId = tag.parentId else { return false }
            return !ids.contains(parentId)
        }
        #expect(orphans.isEmpty, "dangling parents: \(orphans.prefix(5).map(\.namePath))")
    }

    @Test("isUsable filtering still leaves well over a thousand tags")
    func usableFilteringLeavesPlenty() {
        #expect(TagTaxonomy.bundled().filter(\.isUsable).count > 1_000)
    }

    @Test("the bundled resource stays under 1 MB")
    func resourceStaysSmall() throws {
        let url = try #require(
            Bundle(for: BundleMarker.self).url(forResource: "TagTaxonomy", withExtension: "json")
                ?? Bundle.main.url(forResource: "TagTaxonomy", withExtension: "json"),
            "TagTaxonomy.json is not in the bundle, which means it would not ship"
        )
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = try #require(attributes[.size] as? Int)
        #expect(size < 1_000_000)
    }
}

/// Somewhere to hang `Bundle(for:)` so the test can find its own bundle's
/// resources rather than the host app's. See `PrivacyManifestTests`.
private final class BundleMarker {}
