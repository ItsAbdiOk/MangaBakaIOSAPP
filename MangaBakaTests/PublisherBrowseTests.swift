import Testing
import Foundation
@testable import MangaBaka

/// Publishers as a way in.
@Suite("Browsing by publisher")
struct PublisherBrowseTests {
    @Test("A publisher becomes a real filter on the query")
    func publisherReachesTheAPI() {
        // Verified against the live API on 2026-09-10: publisher=Seven Seas
        // answers 1,265 of 304,096, a name it does not know answers 0 rather
        // than being ignored, and the rows really are theirs.
        var query = SearchQuery()
        query.publisher = "Seven Seas"

        let names = query.queryItems.filter { $0.name == "publisher" }.map(\.value)
        #expect(names == ["Seven Seas"])
    }

    @Test("A publisher on its own is a real query")
    func publisherIsNotEmpty() {
        // The same trap "Surprise me" fell into: a query the app reads as empty
        // returns before making a request, and the screen keeps its idle state
        // while the reader waits for results that were never asked for.
        var query = SearchQuery()
        query.publisher = "Ize Press"
        #expect(!query.isEmpty)
    }

    @Test("An empty publisher is not sent")
    func blankPublisherIsDropped() {
        var query = SearchQuery(text: "murim")
        query.publisher = ""
        #expect(!query.queryItems.contains { $0.name == "publisher" })
    }

    @Test("A saved lens says which publisher it is for")
    func describedInALens() {
        var query = SearchQuery()
        query.publisher = "Seven Seas"
        #expect(SearchLens.describe(query).contains("publisher: Seven Seas"))
    }

    @Test("Arriving from browse narrows the query rather than replacing it")
    @MainActor
    func browseAdds() async {
        // UX#11, decision 2026-09-13: Browse adds, like the panel's own
        // publisher picker, and the pick shows as a token beside the text.
        // Inverted from "replaces" — expected to fail on HEAD~ with:
        // `model.query.text == "leftover"` → actual `nil`.
        let model = SearchModel(repository: StubRepositoryBase())
        model.query = SearchQuery(text: "leftover", types: ["novel"])

        model.applyBrowse(publisher: "Ize Press")

        #expect(model.query.publisher == "Ize Press")
        #expect(model.query.text == "leftover")
        #expect(model.query.types == ["novel"])
    }
}
