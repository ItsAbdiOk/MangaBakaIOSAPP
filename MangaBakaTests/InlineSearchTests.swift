import Foundation
import Testing
@testable import MangaBaka

/// Searching your own shelves. At 937 entries and a 429-item dropped shelf,
/// scrolling is not a way to find a title you can already name.
@Suite("Searching what you already have")
struct InlineSearchTests {
    private func series(titles: [(String, String)], authors: [String] = []) -> Series {
        SeriesFactory.make(
            id: 1,
            titles: titles.map { SeriesTitle(language: $0.0, traits: [], title: $0.1, isPrimary: true) },
            authors: authors
        )
    }

    /// A series is known by whichever of its names the reader learned first.
    /// Matching only the displayed title meant a search could not find a series
    /// by its Korean name, its official English one, or an alternative
    /// romanisation — which is most of the ways people actually refer to these.
    @Test("Every title the series carries is searchable, not just the shown one")
    func matchesAnyTitle() {
        let subject = series(titles: [("en", "Solo Leveling"), ("ko", "나 혼자만 레벨업")])
        #expect(subject.matches("solo"))
        #expect(subject.matches("나 혼자만"))
        #expect(subject.matches("LEVELING"))
        #expect(!subject.matches("omniscient"))
    }

    /// "Everything by this artist" is a real question about your own shelf.
    @Test("Authors are searchable too")
    func matchesAuthors() {
        let subject = series(titles: [("en", "Solo Leveling")], authors: ["Chu-Gong"])
        #expect(subject.matches("chu-gong"))
        #expect(subject.matches("Chu"))
    }

    /// An empty box is not a filter. Returning false would empty every list the
    /// moment the field appeared.
    @Test("An empty needle matches everything", arguments: ["", "   "])
    func emptyMatchesAll(_ needle: String) {
        #expect(series(titles: [("en", "Anything")]).matches(needle))
    }

    /// A series with no titles and no authors is decodable — the schema permits
    /// it — and must not crash or claim a match.
    @Test("A series with no names matches nothing typed")
    func noTitlesMatchesNothing() {
        let subject = SeriesFactory.make(id: 1, titles: [])
        #expect(!subject.matches("anything"))
        #expect(subject.matches(""))
    }
}

/// The field only appears where it earns its place.
///
/// This suite used to pin two screens against each other, and a `12`-entry
/// threshold literal inside `ShelfDetailView`. That screen was deleted
/// (review Q6), and with it the second copy these tests existed to keep in
/// step — so the pin on its threshold went too rather than being re-homed
/// onto a file that never had one.
@Suite("Inline search is shared and conditional", .enabled(if: SourceTree.isAvailable))
struct InlineSearchReachabilityTests {
    @Test("The library screen uses the shared field")
    func oneField() throws {
        let source = try SourceTree.read("MangaBaka/Features/Library/LibraryView.swift")
        #expect(source.contains("InlineSearchField("))
    }
}
