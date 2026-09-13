import CoreSpotlight
import Foundation
import Testing
@testable import MangaBaka

/// The reader's library in iOS search: the entries, with the reader's own
/// state on each, and nothing from the catalogue at large.
@Suite("Spotlight index")
struct SpotlightIndexTests {
    private func entry(
        _ id: Int, state: LibraryEntry.State = .reading, chapter: Double? = nil,
        series: Series? = nil
    ) -> LibraryEntry {
        LibraryEntry(
            id: id, seriesId: id, state: state, progressChapter: chapter, progressVolume: nil,
            rating: nil, note: nil, startDate: nil, finishDate: nil, numberOfRereads: nil,
            priority: nil, isPrivate: nil, readLink: nil, series: series
        )
    }

    @Test("One item per entry with a series, titled and in the library domain")
    func itemsFromEntries() {
        let series = SeriesFactory.make(id: 7, title: "Solo Leveling", type: "manhwa")
        let items = SpotlightIndex.items(from: [
            entry(7, series: series),
            entry(8, series: nil)
        ])
        #expect(items.count == 1)
        #expect(items[0].uniqueIdentifier == "series-7")
        #expect(items[0].domainIdentifier == SpotlightIndex.domain)
        #expect(items[0].attributeSet.title == "Solo Leveling")
        #expect(items[0].attributeSet.keywords == ["manhwa"])
    }

    /// What makes this result different from a web search for the title.
    @Test("The description is the reader's state")
    func describesState() {
        let series = SeriesFactory.make(id: 7, title: "S", type: "manhwa", totalChapters: 120)
        #expect(
            SpotlightIndex.description(for: entry(7, state: .reading, chapter: 53, series: series))
                == "Reading · chapter 53 of 120 · Manhwa"
        )
        // A finished series has no "chapter 120 of 120" to say.
        #expect(
            SpotlightIndex.description(for: entry(7, state: .completed, chapter: 120, series: series))
                == "Completed · Manhwa"
        )
    }

    /// Gap 1/g: `description(for:)` used `Int(chapter)`/`Int(totalChapters)`
    /// directly, which traps outside roughly ±9.2e18 — and this runs from
    /// `startSession` on every launch (`SpotlightIndex.swift:93-94`), so a
    /// single library entry with a chapter number that large would be a
    /// crash loop with no in-app fix. `Int(wholeOrClamped:)` cannot trap.
    /// Expected to fail before the fix with: a fatal trap ("Double value
    /// cannot be converted to Int because it is either infinite or NaN"),
    /// not a returned string.
    @Test("An absurd chapter or total does not crash the description")
    func absurdNumbersDoNotTrap() {
        let series = SeriesFactory.make(id: 7, title: "S", totalChapters: 1e300)
        let description = SpotlightIndex.description(
            for: entry(7, state: .reading, chapter: 1e300, series: series)
        )
        #expect(!description.isEmpty)
    }

    /// Only a cover the app already holds; the closure stands in for the
    /// URL cache, and a miss on the small rendering falls through to the
    /// larger one a row may have loaded instead.
    @Test("A thumbnail is whichever rendering is cached, never a fetch")
    func thumbnails() throws {
        let cover = Cover(
            raw: nil, x150: URL(string: "https://c/x150@1.jpg"), x250: URL(string: "https://c/x250@1.jpg"),
            x350: nil, blurhash: nil, width: nil, height: nil
        )
        let series = SeriesFactory.make(id: 7, title: "S", cover: cover)
        let items = SpotlightIndex.items(from: [entry(7, series: series)]) { url in
            url.absoluteString.contains("x250@2") ? Data([1, 2, 3]) : nil
        }
        #expect(items[0].attributeSet.thumbnailData == Data([1, 2, 3]))
        let none = SpotlightIndex.items(from: [entry(7, series: series)])
        #expect(none[0].attributeSet.thumbnailData == nil)
    }

    @Test("A tapped result names its series; anything else is ignored")
    func parsesActivity() {
        let ours = NSUserActivity(activityType: CSSearchableItemActionType)
        ours.userInfo = [CSSearchableItemActivityIdentifier: "series-3397"]
        #expect(SpotlightIndex.seriesID(from: ours) == 3397)

        let foreign = NSUserActivity(activityType: CSSearchableItemActionType)
        foreign.userInfo = [CSSearchableItemActivityIdentifier: "other-3397"]
        #expect(SpotlightIndex.seriesID(from: foreign) == nil)

        let handoff = NSUserActivity(activityType: "com.example.browsing")
        handoff.userInfo = [CSSearchableItemActivityIdentifier: "series-3397"]
        #expect(SpotlightIndex.seriesID(from: handoff) == nil)
    }
}

@Suite("Spotlight is wired to the session", .enabled(if: SourceTree.isAvailable))
struct SpotlightWiringTests {
    /// The index names the previous account's library, like the reminders.
    @Test("Sign-out clears the index, launch rebuilds it after the library walk")
    func sessionWiring() throws {
        let source = try SourceTree.read("MangaBaka/App/RootView+Session.swift")
        let cancel = try #require(source.range(of: "await reminders.forget()"))
        let clear = try #require(source.range(of: "await spotlight.clear()"))
        #expect(cancel.upperBound < clear.lowerBound)
        let reminders = try #require(source.range(of: "await refreshReminders()\n"))
        // Batch 6 wired gap 104 here: `reindex` used to run off `.all()`,
        // which throws away whether the walk that produced it failed, so a
        // reader offline on launch had yesterday's index wiped and replaced
        // with nothing. It now reads `.load()` and skips the reindex outright
        // when `.failure` is set, leaving yesterday's index standing.
        let reindex = try #require(source.range(of: "await spotlight.reindex(walk.entries)"))
        #expect(reminders.upperBound < reindex.lowerBound)
    }

    /// Gap 104: a failed walk must not wipe yesterday's index.
    @Test("A failed library walk leaves the Spotlight index untouched")
    func skipsReindexOnFailure() throws {
        let source = try SourceTree.read("MangaBaka/App/RootView+Session.swift")
        let guardLine = try #require(source.range(of: "guard walk.failure == nil else { return }"))
        let load = try #require(source.range(of: "let walk = await librarySnapshot.load()"))
        let reindex = try #require(source.range(of: "await spotlight.reindex(walk.entries)"))
        #expect(load.upperBound < guardLine.lowerBound)
        #expect(guardLine.upperBound < reindex.lowerBound)
    }

    @Test("A tapped result opens the series in the Library tab")
    func opensInLibrary() throws {
        let root = try SourceTree.read("MangaBaka/App/RootView.swift")
        #expect(root.contains(".onContinueUserActivity(CSSearchableItemActionType)"))
        let session = try SourceTree.read("MangaBaka/App/RootView+Session.swift")
        #expect(session.contains("selection = .library\n        shelfPath = [series]"))
    }
}
