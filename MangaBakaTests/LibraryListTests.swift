import Testing
import Foundation
import SwiftUI
import UIKit
@testable import MangaBaka

/// The library as one list: what it shows, in what order, and what it leaves
/// out.
@Suite("Library list")
@MainActor
struct LibraryListTests {
    private func entry(
        _ id: Int,
        _ state: LibraryEntry.State,
        title: String = "Series",
        rating: Double? = nil,
        finished: Date? = nil,
        progressChapter: Double? = nil,
        progressVolume: Double? = nil,
        totalChapters: Double? = nil,
        finalVolume: Double? = nil
    ) -> LibraryEntry {
        LibraryEntry(
            id: id, seriesId: id, state: state, progressChapter: progressChapter,
            progressVolume: progressVolume, rating: rating, note: nil, startDate: nil,
            finishDate: finished, numberOfRereads: nil, priority: nil,
            isPrivate: nil, readLink: nil,
            series: SeriesFactory.make(
                id: id, title: title, totalChapters: totalChapters, finalVolume: finalVolume
            )
        )
    }

    private func model(_ entries: [LibraryEntry]) async -> LibraryModel {
        let model = LibraryModel(library: StubLibrary(entries: entries))
        await model.load()
        return model
    }

    @Test("Dropped is counted everywhere and listed nowhere, unless asked for")
    func droppedIsCountedNotListed() async throws {
        let model = await model([
            entry(1, .reading, title: "Reading one"),
            entry(2, .dropped, title: "Gave up")
        ])

        // It is a real part of the library and the shape bar says so.
        #expect(model.shape.contains { $0.state == .dropped && $0.count == 1 })
        // But a list of everything you read that opens with what you gave up
        // on is a worse answer than one that does not.
        #expect(model.listed.map(\.seriesId) == [1])

        model.filter = .dropped
        #expect(model.listed.map(\.seriesId) == [2], "asked for, it appears")
    }

    @Test("Dropped comes last among the states")
    func droppedIsLast() async throws {
        let model = await model([
            entry(1, .dropped),
            entry(2, .reading),
            entry(3, .completed)
        ])

        #expect(model.shape.last?.state == .dropped)
        #expect(model.shape.first?.state == .reading)
    }

    @Test("Sorting by title ignores a leading article")
    func titleSortIgnoresArticles() async throws {
        // Sorting on the raw title files a quarter of an English-language
        // library under "The".
        let model = await model([
            entry(1, .reading, title: "The Greatest Estate Developer"),
            entry(2, .reading, title: "Havoc"),
            entry(3, .reading, title: "A Returner's Magic")
        ])
        model.sort = .title

        #expect(model.listed.map { $0.series?.displayTitle } == [
            "The Greatest Estate Developer", "Havoc", "A Returner's Magic"
        ])
    }

    @Test("An entry with no date sorts last, not first")
    func undatedEntriesSinkOnRecency() async throws {
        let old = Date(timeIntervalSince1970: 1_700_000_000)
        let model = await model([
            entry(1, .reading, finished: nil),
            entry(2, .reading, finished: old)
        ])
        model.sort = .recentlyUpdated

        #expect(model.listed.map(\.seriesId) == [2, 1], "nil is not newer than a date")
    }

    @Test("The jump index only appears where it can point at something")
    func jumpIndexIsConditional() async throws {
        // The board draws one on a screen sorted by "Recently updated"; its own
        // caption says title-sorted and 200-plus. The caption wins: an A-Z rail
        // down a list ordered by date points at nothing.
        let many = (1...250).map { entry($0, .reading, title: "Series \($0)") }
        let model = await model(many)

        model.sort = .recentlyUpdated
        #expect(!model.showsJumpIndex)

        model.sort = .title
        #expect(model.showsJumpIndex)

        model.filter = .paused
        #expect(!model.showsJumpIndex, "nothing left to index")
    }

    @Test("Search covers only what has loaded, and says nothing it cannot")
    func searchIsLocal() async throws {
        let model = await model([
            entry(1, .reading, title: "Solo Leveling"),
            entry(2, .reading, title: "Omniscient Reader")
        ])
        model.searchText = "solo"

        #expect(model.listed.map(\.seriesId) == [1])
    }

    /// Gap 91: a search matching nothing used to render the list's header
    /// over a blank space with no message at all — the same look as the list
    /// still loading. `isFiltering` is what `LibraryList` uses to decide
    /// whether an empty `listed` means "nothing matches" rather than "nothing
    /// saved yet".
    /// Expected to fail before the fix with: no `isFiltering` property on
    /// `LibraryModel` at all.
    @Test("A search or filter matching nothing is reported as filtering")
    func isFilteringTracksSearchAndFilter() async throws {
        let model = await model([entry(1, .reading, title: "Solo Leveling")])
        #expect(!model.isFiltering)

        model.searchText = "berserk"
        #expect(model.isFiltering)
        #expect(model.listed.isEmpty)

        model.searchText = ""
        model.filter = .completed
        #expect(model.isFiltering)
    }

    // MARK: - Progress line

    /// L7: `Int(chapter)` truncated a half chapter to a whole one in this
    /// list, though not in the editor for the same entry
    /// (`LibraryEditSheet.chapterText`). Reused here instead.
    /// Expected to fail before the fix with: "Ch 12 / 179", not "Ch 12.5 / 179".
    @Test("A fractional chapter is not truncated in the row")
    func fractionalChapterSurvives() {
        let subject = entry(
            1, .reading, progressChapter: 12.5, totalChapters: 179
        )
        #expect(LibraryList.progressLine(subject) == "Ch 12.5 / 179")
    }

    @Test("A plan-to-read entry shows no progress line")
    func noProgressLineWhereNothingIsTracked() {
        let subject = entry(1, .planToRead, progressChapter: 12)
        #expect(LibraryList.progressLine(subject) == nil)
    }

    /// L9 (decision, docs/reviews/library-discovery-ui.md): volume progress
    /// used to hide chapter progress outright — a reader who once set "Vol 1"
    /// on the website and has tracked chapters since saw "Vol 1 / 30" instead
    /// of the more specific "Ch 112 / 179". Both are shown when both exist.
    /// Expected to fail before the fix with: "Vol 3 / 10" — the chapter
    /// number never appears at all.
    @Test("Volume and chapter progress are both shown when both exist")
    func bothVolumeAndChapterShow() {
        let subject = entry(
            1, .reading, progressChapter: 24, progressVolume: 3,
            totalChapters: 200, finalVolume: 10
        )
        #expect(LibraryList.progressLine(subject) == "Vol. 3 · Ch. 24")
    }

    @Test("Volume alone still shows its own total")
    func volumeAloneKeepsItsTotal() {
        let subject = entry(1, .reading, progressVolume: 3, finalVolume: 10)
        #expect(LibraryList.progressLine(subject) == "Vol 3 / 10")
    }

    // MARK: The 2026-09-13 accessibility audit, on this screen

    /// The count inside a selected filter pill, against the pill it sits on.
    ///
    /// Apple's audit reported "contrast nearly passed" for "516" on both the
    /// library and the library-search screens (2026-09-13, frame 52,235).
    /// Recomputed here from `Palette` and `LibraryFilterRow.countOpacity`
    /// themselves, so the constant cannot be lowered again without this
    /// failing. 4.5:1 is WCAG AA for text under 18pt; `typeChip` is well under.
    @Test("A selected pill's count clears 4.5:1 against the pill")
    func selectedPillCountIsLegible() {
        let ratio = Contrast.ratio(
            of: Palette.onAccent,
            atOpacity: LibraryFilterRow.countOpacity,
            over: Palette.accent
        )
        #expect(ratio >= 4.5, "measured \(ratio):1")
    }

    /// The control: the same maths on the pair the design spec already states
    /// a figure for. `onAccent` at full strength on `accent` is the pill's own
    /// title, and the spec's note on `onAccent` says white would fail there —
    /// so this must come out high, and white must come out low. Without this
    /// a broken ratio function would pass the test above by returning 21.
    @Test("Control: the contrast maths reproduces a known pair")
    func contrastControlHolds() {
        let onAccent = Contrast.ratio(of: Palette.onAccent, atOpacity: 1, over: Palette.accent)
        #expect(onAccent > 7, "onAccent on accent should be strong, measured \(onAccent):1")
        let white = Contrast.ratio(of: .white, atOpacity: 1, over: Palette.accent)
        #expect(white < 3, "white on accent is what the spec forbids, measured \(white):1")
    }

    /// One line is a trim at the ordinary sizes and a lost title at the
    /// accessibility ones, which is what the audit reported as "Text clipped"
    /// against the only library row not hidden behind the keyboard.
    @Test("A row title is allowed to wrap once Dynamic Type reaches AX sizes")
    func titleWrapsAtAccessibilitySizes() {
        #expect(LibraryList.titleLineLimit(isAccessibilitySize: false) == 1)
        #expect(LibraryList.titleLineLimit(isAccessibilitySize: true) > 1)
    }

    // MARK: What the list animates on

    /// `listedRevision` has to move on exactly the three things that reshape
    /// the list, or `LibraryList`'s settle animation stops firing.
    @Test("Every reshape of the list bumps listedRevision")
    func reshapeBumpsRevision() async throws {
        let model = await model([
            entry(1, .reading, title: "Akira"),
            entry(2, .paused, title: "Berserk")
        ])
        let afterLoad = model.listedRevision

        model.searchText = "aki"
        let afterSearch = model.listedRevision
        #expect(afterSearch > afterLoad, "a search reshapes the list")
        #expect(model.listed.count == 1, "control: the search really did filter")

        model.searchText = ""
        model.filter = .paused
        let afterFilter = model.listedRevision
        #expect(afterFilter > afterSearch, "a filter reshapes the list")

        model.sort = .title
        #expect(model.listedRevision > afterFilter, "a sort reshapes the list")
    }

    /// sRGB contrast, source-composited, to WCAG 2.1.
    ///
    /// Written out rather than taken from a framework because nothing in the
    /// SDK exposes it: `UIColor` will resolve a colour but will not tell you
    /// what two of them measure against each other.
    private enum Contrast {
        static func ratio(of colour: Color, atOpacity alpha: Double, over ground: Color) -> Double {
            let over = components(colour)
            let back = components(ground)
            let composited = (0..<3).map { alpha * over[$0] + (1 - alpha) * back[$0] }
            let front = luminance(composited)
            let behind = luminance(back)
            return (max(front, behind) + 0.05) / (min(front, behind) + 0.05)
        }

        private static func components(_ colour: Color) -> [Double] {
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            UIColor(colour)
                .resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))
                .getRed(&red, green: &green, blue: &blue, alpha: &alpha)
            return [Double(red), Double(green), Double(blue)]
        }

        private static func luminance(_ rgb: [Double]) -> Double {
            let linear = rgb.map { channel -> Double in
                channel <= 0.03928 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]
        }
    }

    private final class StubLibrary: LibraryProviding, @unchecked Sendable {
        let entries: [LibraryEntry]
        init(entries: [LibraryEntry]) { self.entries = entries }

        func library(page: Int, limit: Int) async -> [LibraryEntry] {
            page == 1 ? entries : []
        }
        func recommendationStatus() async throws(APIError) -> RecommendationStatus {
            throw APIError.offline
        }
        func recommendations(
            limit: Int, page: Int, excluding: [Int]
        ) async -> PersonalRecommendations { PersonalRecommendations() }
        func hiddenTagIDs() async -> Set<Int>? { [] }
        func topGenres() async -> [TopGenre]? { [] }
        func update(seriesId: Int, change: LibraryChange) async throws(APIError) {}
        func add(seriesId: Int, state: LibraryEntry.State) async throws(APIError) -> Bool { true }
        func remove(seriesId: Int) async throws(APIError) {}
    }
}
