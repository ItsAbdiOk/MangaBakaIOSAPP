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
        let cancel = try #require(source.range(of: "await reminders.cancelAll()"))
        let clear = try #require(source.range(of: "await spotlight.clear()"))
        #expect(cancel.upperBound < clear.lowerBound)
        let reminders = try #require(source.range(of: "await refreshReminders()\n"))
        let reindex = try #require(source.range(of: "await spotlight.reindex(await librarySnapshot.all())"))
        #expect(reminders.upperBound < reindex.lowerBound)
    }

    @Test("A tapped result opens the series in the Library tab")
    func opensInLibrary() throws {
        let root = try SourceTree.read("MangaBaka/App/RootView.swift")
        #expect(root.contains(".onContinueUserActivity(CSSearchableItemActionType)"))
        let session = try SourceTree.read("MangaBaka/App/RootView+Session.swift")
        #expect(session.contains("selection = .library\n        shelfPath = [series]"))
    }
}
