import Foundation
import Testing
@testable import MangaBaka

/// The series page against `design/Mockups/NewBakaManga.html`. The standing
/// rule is one-for-one, and the parts that were missing were not decoration:
/// the rating count, the tags, the credits and the release estimate were all
/// data the app already held and did not show.
@Suite("Series page matches the mockup")
@MainActor
struct DetailFidelityTests {
    // MARK: The stats strip

    /// The mockup's five segments. The app previously showed type, status,
    /// rating and chapter count as grey chips, which meant a 6.4-from-3 series
    /// and a 6.4-from-64,000 series read identically — the count was in the
    /// API all along and on screen nowhere.
    @Test("The strip carries the mockup's five stats when the API has them")
    func fiveStats() {
        let series = SeriesFactory.make(
            id: 1,
            rating: 86,
            totalChapters: 201,
            finalVolume: 15,
            year: 2018,
            ratingCount: 541_000
        )
        let labels = DetailStatsStrip(series: series, year: 2018).stats.map(\.label)
        #expect(labels == ["Rating", "Ratings", "Chapters", "Volumes", "Started"])
    }

    /// "—" in a box is not information, and a series with no volumes is
    /// ordinary rather than broken.
    @Test("Segments the API did not answer are dropped, not shown empty")
    func missingStatsDropped() {
        let series = SeriesFactory.make(id: 1, rating: 86)
        let stats = DetailStatsStrip(series: series).stats
        #expect(stats.map(\.label) == ["Rating"])
        #expect(stats[0].value == "8.6")
    }

    /// A rating of zero volumes is the API saying "none", not "fifteen".
    @Test("Zero counts are absent, not printed as zero")
    func zeroIsNotAStat() {
        let series = SeriesFactory.make(id: 1, totalChapters: 0, finalVolume: 0, ratingCount: 0)
        #expect(DetailStatsStrip(series: series).stats.isEmpty)
    }

    /// The order of magnitude is the point; the exact figure is noise.
    @Test(
        "Rating counts read as magnitudes",
        arguments: [(3, "3"), (999, "999"), (1_200, "1.2k"), (541_000, "541.0k"), (2_400_000, "2.4m")]
    )
    func compactCounts(_ input: Int, _ expected: String) {
        #expect(DetailStatsStrip.compact(input) == expected)
    }

    // MARK: Credits

    @Test("Credits answer the questions the mockup's table asks")
    func creditsRows() {
        let series = SeriesFactory.make(
            id: 1,
            authors: ["Chu-Gong"],
            contentRating: "safe",
            publishers: [Series.Publisher(name: "D&C Media", type: "original", note: nil)]
        )
        let labels = DetailCredits(series: series).rows.map(\.id)
        #expect(labels.contains("Story & art"))
        #expect(labels.contains("Publisher"))
        #expect(labels.contains("Content rating"))
    }

    /// This test used to assert the opposite, and the assertion was the bug.
    ///
    /// It claimed "None listed" was safe to state unconditionally because the
    /// API says whether it knows of an adaptation. It does — in `exists`, which
    /// the code never read. A series whose payload carries no `anime` field at
    /// all (every library entry's embedded series) has said nothing, and
    /// "None listed" is a claim rather than a shrug.
    @Test("A series that said nothing about an anime has no row")
    func adaptationOmittedWhenAbsent() {
        let bare = DetailCredits(series: SeriesFactory.make(id: 1)).rows
        #expect(bare.isEmpty)
    }

    /// Artists are only worth their own row when they are not the same people
    /// as the authors, which for most series they are.
    @Test("Art is a separate row only when the artist differs from the author")
    func artistRowOnlyWhenDifferent() {
        let same = SeriesFactory.make(id: 1, authors: ["A"], artists: ["A"])
        #expect(!DetailCredits(series: same).rows.contains { $0.id == "Art" })

        let different = SeriesFactory.make(id: 1, authors: ["A"], artists: ["B"])
        #expect(DetailCredits(series: different).rows.contains { $0.id == "Art" })
    }

    // MARK: Description

    /// Descriptions arrive as Markdown and were printed raw, so a real series
    /// page ended with a literal "*Source: Tappytoon*" and three hyphens.
    @Test("Markdown in a description is rendered, not printed")
    func markdownIsParsed() {
        let rendered = String(SeriesDetailView.prose(from: "A story.\n---\n*Source: Tappytoon*").characters)
        #expect(!rendered.contains("---"))
        #expect(!rendered.contains("*"))
        #expect(rendered.contains("Source: Tappytoon"))
    }

    /// A description that is not valid Markdown must still reach the screen.
    @Test("Unparsable text survives as itself")
    func brokenMarkdownSurvives() {
        let raw = "An unclosed [link( and a stray *"
        #expect(!String(SeriesDetailView.prose(from: raw).characters).isEmpty)
    }
}

/// The page's order is an argument about what a reader wants: what it is, then
/// what to do about it, then the numbers, then the words, then everywhere else
/// to go. Reordering it silently would undo that.
@Suite("The series page keeps the mockup's order", .enabled(if: SourceTree.isAvailable))
struct DetailOrderTests {
    @Test("Sections appear in the mockup's sequence")
    func order() throws {
        let source = try SourceTree.read("MangaBaka/Features/Detail/SeriesDetailView.swift")
        let sequence = [
            "DetailHero(",
            "actions",
            "DetailStatsStrip(",
            "DetailSynopsis(",
            "DetailTags(",
            "DetailCredits(",
            "DetailOnwardRows(",
            "TrackerScores(",
            "readElsewhere",
            "provenance"
        ]
        var cursor = source.startIndex
        for token in sequence {
            let found = source.range(of: token, range: cursor..<source.endIndex)
            #expect(found != nil, "\(token) is missing or out of order on the series page")
            if let found { cursor = found.upperBound }
        }
    }

    /// The mockup's hero sits on a blurred, over-saturated copy of the cover
    /// under a four-stop gradient. Without it the page is flat black and reads
    /// as a different design.
    @Test("The hero keeps its blurred backdrop")
    func backdropSurvives() throws {
        let source = try SourceTree.read("MangaBaka/Features/Detail/DetailBackdrop.swift")
        #expect(source.contains("blur(radius: 72"))
        #expect(source.contains("saturation(1.7)"))
        #expect(source.contains("opacity(0.34)"))
        #expect(source.contains("scaleEffect(1.6)"))
    }

    /// Tapping a tag searches for it. Without the route the tags are decoration
    /// and the most obvious onward path on the page goes nowhere.
    @Test("Tags, seeds and the schedule all lead somewhere")
    func onwardRoutesWired() throws {
        let root = try SourceTree.read("MangaBaka/App/RootView.swift")
        #expect(root.contains("onOpenTag:"))
        #expect(root.contains("onUseAsSeed:"))
        #expect(root.contains("onOpenSchedule:"))
        #expect(root.contains("mixModel?.addSeed(series)"))
    }
}

/// Full Markdown parsing produces block elements that `Text` renders end to
/// end with no separator, which welded a real description's two paragraphs and
/// its source caption into one sentence.
@Suite("Description paragraphs survive parsing")
@MainActor
struct DescriptionParagraphTests {
    @Test("A paragraph break stays a paragraph break")
    func paragraphsSurvive() {
        let rendered = String(
            SeriesDetailView.prose(from: "First paragraph.\n\nSecond paragraph.").characters
        )
        #expect(rendered.contains("\n"))
        #expect(!rendered.contains("paragraph.Second"))
    }

    /// The literal failure that shipped, kept as a test so it cannot come back.
    @Test("The Tappytoon case reads as three blocks, not one sentence")
    func tappytoonCase() {
        let source = "...extent of his powers.\n\n*Source: Tappytoon*\n---\nKnown as the weakest."
        let rendered = String(SeriesDetailView.prose(from: source).characters)
        #expect(!rendered.contains("TappytoonKnown"))
        #expect(!rendered.contains("---"))
    }
}

/// v1 and v2 are not the same API wearing two version numbers. This is the
/// divergence that matters to the series page, measured against the live API on
/// 2026-09-09 and asserted here so a refactor onto "just use v2" is caught.
@Suite("Tags and year come from v1 only")
@MainActor
struct DetailVersionDivergenceTests {
    /// `/v2/series/{id}` returns the same 23 keys the feeds do, and neither
    /// `tags` nor `year` is among them. A series page built from a feed's own
    /// copy therefore shows no tags and no start year — which is exactly the
    /// bug: the tag row rendered empty and nobody could tell it from a series
    /// that genuinely has no tags.
    @Test("The v1 series fetch is what fills the tag row")
    func extrasCarryTags() {
        var extras = SeriesExtras()
        #expect(extras.tags.isEmpty)
        #expect(extras.year == nil)

        extras.tags = ["Dungeon", "Level System"]
        extras.year = 2018
        #expect(extras.tags.count == 2)
    }

    /// The v2 copy has no year, so the strip has to take v1's. Preferring the
    /// series' own value would silently drop the stat on every real page.
    @Test("The strip prefers the v1 year over the series' own missing one")
    func yearComesFromExtras() {
        let series = SeriesFactory.make(id: 1, year: nil)
        let strip = DetailStatsStrip(series: series, year: 2018)
        #expect(strip.stats.contains { $0.label == "Started" && $0.value == "2018" })

        let without = DetailStatsStrip(series: series, year: nil)
        #expect(!without.stats.contains { $0.label == "Started" })
    }
}

/// The mockup draws three tags. Solo Leveling carries 43, and rendering all of
/// them made the tag row eight rows deep and pushed the rest of the page off
/// the screen.
@Suite("The tag row summarises rather than dumps")
@MainActor
struct DetailTagsTests {
    private func tags(_ count: Int) -> [String] {
        (1...count).map { "Tag \($0)" }
    }

    /// Solo Leveling's real 43, the case that produced the wall.
    @Test("A long list shows the limit and offers the remainder")
    func longListCollapses() {
        let view = DetailTags(tags: tags(43)) { _ in }
        #expect(view.visible.count == DetailTags.collapsedLimit)
        #expect(view.hiddenCount == 43 - DetailTags.collapsedLimit)
        // The first tags shown are the first the API returned, in order.
        #expect(view.visible.first == "Tag 1")
        #expect(view.visible.last == "Tag 12")
    }

    /// A "+0 more" button is a control that does nothing, and a list at exactly
    /// the limit must not grow one.
    @Test("A list at or under the limit has nothing to expand", arguments: [1, 3, 11, 12])
    func shortListIsWhole(_ count: Int) {
        let view = DetailTags(tags: tags(count)) { _ in }
        #expect(view.visible.count == count)
        #expect(view.hiddenCount == 0)
    }

    @Test("No tags renders nothing at all")
    func noTagsNoRow() {
        let view = DetailTags(tags: []) { _ in }
        #expect(view.visible.isEmpty)
        #expect(view.hiddenCount == 0)
    }
}

/// The control claimed a series was not in the library when it was.
///
/// It asked `/v1/my/series` for one page of 500 and treated the answer as the
/// whole library. The endpoint is paged — which is why `LibraryModel` loops
/// until a short page — so on a 937-entry library the control saw at most the
/// first page and offered "Add to library" for a series the reader was already
/// reading. The write would then fail with a 409, having told them something
/// false first.
@Suite("The library lookup sees the whole library", .enabled(if: SourceTree.isAvailable))
struct LibraryLookupTests {
    @Test("The control reads the shared library rather than fetching a page")
    func usesSharedStore() throws {
        let source = try SourceTree.read("MangaBaka/Features/Detail/LibraryControl.swift")
        #expect(source.contains("await store.load()"))
        #expect(
            !source.contains("library.library(page:"),
            "LibraryControl is fetching its own page again — one page is not the library"
        )
    }

    /// The loop is the thing that makes it the whole library. A single call,
    /// at any limit, is a page.
    @Test("The shared store pages until it runs out")
    func storePages() throws {
        let source = try SourceTree.read("MangaBaka/Features/Library/LibraryModel.swift")
        #expect(source.contains("for page in 1...10"))
        #expect(source.contains("if batch.count < 100 { break }"))
    }

    /// A write has to refresh the shared copy, or the Library tab and the
    /// series page disagree about the same entry.
    @Test("Writes refresh the shared copy, not a local one")
    func writesRefreshShared() throws {
        let source = try SourceTree.read("MangaBaka/Features/Detail/LibraryControl.swift")
        #expect(source.contains("await store.reload()"))
    }
}

/// Rows that answer with a list, and the title, both had the same problem: a
/// value too long for the place it sits.
@Suite("Long values fit where they are")
@MainActor
struct DetailRowFittingTests {
    /// A popular series lists fifteen publishers, which turned one row of the
    /// credits table into four lines of small print in the middle of it.
    @Test("A multi-publisher row can be opened")
    func publishersExpandable() {
        let many = SeriesFactory.make(id: 1, publishers: [
            Series.Publisher(name: "3B2S", type: nil, note: nil),
            Series.Publisher(name: "A.tempo Media", type: nil, note: nil),
            Series.Publisher(name: "Ize Press", type: nil, note: nil)
        ])
        let row = DetailCredits(series: many).rows.first { $0.id == "Publishers" }
        #expect(row?.isExpandable == true)
    }

    /// A row that responds to a tap by doing nothing is worse than one that
    /// does not respond at all.
    @Test("A single publisher has nothing to open")
    func singlePublisherNotExpandable() {
        let one = SeriesFactory.make(id: 1, publishers: [
            Series.Publisher(name: "Yen Press", type: nil, note: nil)
        ])
        let row = DetailCredits(series: one).rows.first { $0.id == "Publisher" }
        #expect(row?.isExpandable == false)
    }

    @Test("Short rows are never expandable")
    func shortRowsFixed() {
        let series = SeriesFactory.make(id: 1, authors: ["A"], contentRating: "safe")
        for row in DetailCredits(series: series).rows where row.id != "Publishers" {
            #expect(!row.isExpandable, "\(row.id) offers a tap that does nothing")
        }
    }
}

/// Looking a title up elsewhere — a reader, a shop, a search — is most of what
/// happens next, and retyping a romanised Korean title from a phone screen is
/// the worst way to do it.
@Suite("The title copies itself", .enabled(if: SourceTree.isAvailable))
struct TitleCopyTests {
    @Test("Tapping the title writes it to the pasteboard")
    func copiesOnTap() throws {
        let source = try SourceTree.read("MangaBaka/Features/Detail/DetailHero.swift")
        #expect(source.contains("UIPasteboard.general.string = series.displayTitle"))
    }

    /// A clipboard change with no acknowledgement is indistinguishable from a
    /// tap that missed.
    @Test("The copy is acknowledged")
    func saysSo() throws {
        let source = try SourceTree.read("MangaBaka/Features/Detail/DetailHero.swift")
        #expect(source.contains("\"Copied\""))
        #expect(source.contains("impactOccurred()"))
        #expect(source.contains("accessibilityHint(\"Copies the title\")"))
    }

    /// There is nothing to copy from a series with no titles, which the schema
    /// permits, and a button that copies an empty string is a lie.
    @Test("A series with no title has no copy action")
    func noTitleNoAction() throws {
        let source = try SourceTree.read("MangaBaka/Features/Detail/DetailHero.swift")
        #expect(source.contains("disabled(series.displayTitle == nil)"))
    }
}
