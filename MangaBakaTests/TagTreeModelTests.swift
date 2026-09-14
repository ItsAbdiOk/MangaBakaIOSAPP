import Testing
import Foundation
@testable import MangaBaka

/// `TagTreeModel`'s pure derivations: `children`, `path`, `descendantIDs`.
///
/// `TagTreeModel` does not exist before this change, so every test in this
/// file fails to compile without it — `error: cannot find 'TagTreeModel' in
/// scope` — rather than failing at runtime. That is the whole proof: there
/// was no tag tree to test.
@Suite("Tag tree")
struct TagTreeModelTests {
    /// A small fixture with a 3-deep branch (`root` → `child` → `grandchild`)
    /// and an orphan whose `parentId` (999) names a tag this fixture does not
    /// have — the case `TagTreeModel.children(of:in:)`'s doc comment says is
    /// untested in the bundled data today but must not crash if it ever
    /// happens. A merged tag (`survivorId`) is included too, to prove it is
    /// dropped everywhere a real tag would appear.
    private static func makeTag(
        id: Int, name: String, parentId: Int?, level: Int,
        seriesCount: Int = 10, mergedWith: Int? = nil
    ) -> MangaBaka.Tag {
        MangaBaka.Tag(
            id: id, name: name, namePath: name, parentId: parentId, level: level,
            description: nil, seriesCount: seriesCount, isGenre: false, isSpoiler: false,
            mergedWith: mergedWith, contentRating: nil
        )
    }

    private static let root = makeTag(id: 1, name: "Root", parentId: nil, level: 1)
    private static let child = makeTag(id: 2, name: "Child", parentId: 1, level: 2)
    private static let grandchild = makeTag(id: 3, name: "Grandchild", parentId: 2, level: 3)
    /// Dangling parent: 999 exists nowhere in this fixture.
    private static let orphan = makeTag(id: 4, name: "Orphan", parentId: 999, level: 2)
    private static let merged = makeTag(id: 5, name: "MergedAway", parentId: 1, level: 2, mergedWith: 1)

    private static let fixture = [root, child, grandchild, orphan, merged]

    @Test("root level is real roots plus any orphan, sorted by name, merged tags dropped")
    func rootChildren() {
        let roots = TagTreeModel.children(of: nil, in: Self.fixture)
        #expect(roots.map(\.name) == ["Orphan", "Root"])
    }

    @Test("a real parent's children exclude a merged tag")
    func realParentChildren() {
        #expect(TagTreeModel.children(of: Self.root.id, in: Self.fixture).map(\.name) == ["Child"])
    }

    @Test("a leaf has no children")
    func leafHasNoChildren() {
        #expect(TagTreeModel.children(of: Self.grandchild.id, in: Self.fixture).isEmpty)
    }

    @Test("path is root-to-leaf")
    func pathToLeaf() {
        let names = TagTreeModel.path(to: Self.grandchild.id, in: Self.fixture).map(\.name)
        #expect(names == ["Root", "Child", "Grandchild"])
    }

    @Test("an orphan's path is itself alone, not a crash")
    func pathToOrphan() {
        #expect(TagTreeModel.path(to: Self.orphan.id, in: Self.fixture).map(\.name) == ["Orphan"])
    }

    @Test("a tag id absent from the taxonomy answers an empty path")
    func pathToUnknownID() {
        #expect(TagTreeModel.path(to: 12_345, in: Self.fixture).isEmpty)
    }

    @Test("descendants are every tag beneath a node, not just its direct children")
    func descendantsOfRoot() {
        let descendants = TagTreeModel.descendantIDs(of: Self.root.id, in: Self.fixture)
        #expect(descendants == Set([Self.child.id, Self.grandchild.id]))
    }

    @Test("a leaf has no descendants")
    func descendantsOfLeaf() {
        #expect(TagTreeModel.descendantIDs(of: Self.grandchild.id, in: Self.fixture).isEmpty)
    }

    @Test("an id nothing points to answers no descendants, not a crash")
    func descendantsOfUnknownID() {
        #expect(TagTreeModel.descendantIDs(of: 12_345, in: Self.fixture).isEmpty)
    }

    @Test("accessibility label names the tag and its sub-tag count")
    func accessibilityLabelWording() {
        #expect(TagTreeModel.accessibilityLabel(for: Self.root, childCount: 1) == "Root, 1 sub-tag")
        #expect(TagTreeModel.accessibilityLabel(for: Self.root, childCount: 3) == "Root, 3 sub-tags")
        #expect(TagTreeModel.accessibilityLabel(for: Self.root, childCount: 0) == "Root, no sub-tags")
    }

    // MARK: Against the real bundled taxonomy

    @Test("a known root in the real taxonomy has more than zero children")
    func realRootHasChildren() throws {
        // id 537 is "Activities", level 1 — TagTaxonomyTests.knownRootTag
        // already establishes it exists in the bundled data.
        let children = TagTreeModel.children(of: 537, in: TagTaxonomy.bundled())
        #expect(!children.isEmpty)
    }
}
