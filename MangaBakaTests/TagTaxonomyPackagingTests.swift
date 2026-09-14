import Foundation
import Testing
@testable import MangaBaka

/// Is the bundled tag taxonomy actually in the build?
///
/// `CatalogueTests.bundledTaxonomyReportsFailureConsistently` checks that
/// `bundled()` and `loadFailed` agree with each other. They do whether the
/// resource is packaged or not — both sides of its `if` are satisfiable — so
/// on its own it cannot fail on the packaging bug it was written for (review
/// item 117). These two can.
/// Gated per test, not per suite (2026-09-14): the gate on the suite also
/// skipped the tests below that assert on a value and never touch the
/// checkout, so they did not run on Xcode Cloud at all — and nothing
/// reports the difference between a local run and a cloud one.
@Suite("Tag taxonomy packaging")
struct TagTaxonomyPackagingTests {
    /// The checkout: the file is there and is a whole taxonomy, so a truncated
    /// or half-written commit fails here rather than quietly shipping a picker
    /// with four tags in it.
    @Test("The taxonomy resource in the checkout is whole", .enabled(if: SourceTree.isAvailable))
    func taxonomyResourceIsWhole() throws {
        let path = "\(SourceTree.root)/MangaBaka/Resources/TagTaxonomy.json"
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let rows = try #require(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])

        // 2,686 rows in the 2026-08-27 fetch, all of them unmerged (counted
        // 2026-09-14). The floor is 2,000 — low enough that a normal taxonomy
        // revision never trips it, high enough that a truncated file always
        // does. The margin is a guess; the 2,686 is measured.
        #expect(rows.count >= 2_000, "the packaged taxonomy has \(rows.count) rows")
    }

    /// The build: when these tests are hosted by the app — so `Bundle.main` is
    /// the app bundle, which is what the pre-push hook and Xcode Cloud both
    /// run — the resource must really be in it. Dropping `TagTaxonomy.json`
    /// from the target is exactly the packaging failure `loadFailed` exists to
    /// name, and nothing failed on it before 2026-09-14.
    @Test("When the app bundle is the main bundle, the taxonomy is really in it")
    func taxonomyIsPackagedIntoTheApp() {
        guard Bundle.main.bundleIdentifier == "dev.abdirahmanmohamed.mangabaka" else {
            // Unhosted: `Bundle.main` is xctest's own, which was never going
            // to carry an app resource. Say nothing rather than a false alarm.
            return
        }
        #expect(!TagTaxonomy.loadFailed, "TagTaxonomy.json is missing from the app bundle")
        #expect(!TagTaxonomy.bundled().isEmpty)
    }
}
