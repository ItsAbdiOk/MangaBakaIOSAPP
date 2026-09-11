import Foundation
import Testing
@testable import MangaBaka

/// Statements the app could make that were false or absurd for some real input.
/// Each of these was on screen; none of them was a wrong number, they were
/// wrong sentences built from right numbers.
@Suite("The app does not say absurd things")
@MainActor
struct NonsenseGuardTests {
    // MARK: Anime adaptation

    /// The API answers with `{"exists": false}`, and the code only checked
    /// whether the object was there. Verified against the live endpoint on
    /// 2026-09-10: The Greatest Estate Developer returns exists=false, and the
    /// page printed "Yes".
    @Test("A series the API says has no anime does not claim one")
    func animeExistsFalse() throws {
        let series = try Fixture.decoder().decode(Series.self, from: Data("""
        {"id": 1, "state": "active", "cover": {},
         "anime": {"exists": false, "start": null, "end": null}}
        """.utf8))
        let row = DetailCredits(series: series).rows.first { $0.id == "Anime adaptation" }
        #expect(row?.value == "None listed")
    }

    @Test("A series with an anime says so")
    func animeExistsTrue() throws {
        let series = try Fixture.decoder().decode(Series.self, from: Data("""
        {"id": 1, "state": "active", "cover": {}, "anime": {"exists": true}}
        """.utf8))
        #expect(
            DetailCredits(series: series).rows
                .first { $0.id == "Anime adaptation" }?.value == "Yes"
        )
    }

    /// Every library entry's embedded series carries no `anime` field at all,
    /// so every series opened from the Library tab was asserting "None listed"
    /// about a field that had never been fetched.
    @Test("A payload with no anime field claims nothing")
    func animeAbsentIsSilent() {
        let series = SeriesFactory.make(id: 1, anime: nil)
        #expect(!DetailCredits(series: series).rows.contains { $0.id == "Anime adaptation" })
    }

    // MARK: Ratings

    /// Every other stat in the strip guards `> 0`; rating alone did not, and
    /// the ratings-count segment beside it drops at zero — so "0.0 RATING"
    /// stood alone with nothing to expose it as an absence.
    @Test("A rating of zero is not a score")
    func zeroRatingIsNotAStat() {
        let series = SeriesFactory.make(id: 1, rating: 0, ratingCount: 0)
        #expect(!DetailStatsStrip(series: series).stats.contains { $0.label == "Rating" })
    }

    @Test("A real rating still shows")
    func realRatingShows() {
        let series = SeriesFactory.make(id: 1, rating: 86)
        #expect(DetailStatsStrip(series: series).stats.contains { $0.value == "8.6" })
    }

    // MARK: Status

    /// The raw values are identifiers and are also what the schedule matches
    /// on, so they cannot be prettified at the source.
    @Test("Statuses read as words", arguments: [
        ("on_hiatus", "On hiatus"), ("hiatus", "On hiatus"),
        ("releasing", "Releasing"), ("completed", "Completed"),
        ("cancelled", "Cancelled")
    ])
    func statusLabels(_ raw: String, _ expected: String) {
        #expect(SeriesStatus.label(for: raw) == expected)
    }

    /// A status the API adds later should read oddly, not vanish.
    @Test("An unrecognised status is tidied, not dropped")
    func unknownStatusSurvives() {
        #expect(SeriesStatus.label(for: "some_new_state") == "Some New State")
    }

    @Test("No status is no label, not a placeholder")
    func absentStatus() {
        #expect(SeriesStatus.label(for: nil) == nil)
        #expect(SeriesStatus.label(for: "") == nil)
    }

    // MARK: Token checking

    /// The check collapsed offline, rate-limited, 500 and rejected into one
    /// nil. Settings reported all four as "That token was not accepted by
    /// MangaBaka" — and then cleared the Keychain, deleting a working token
    /// because the network was down.
    @Test("Only a rejection is a rejection")
    func onlyAuthErrorsAreRejections() {
        #expect(TokenCheck.rejected.isRejection)
        #expect(!TokenCheck.accepted("Abdi").isRejection)
        #expect(!TokenCheck.unknown("You're offline.").isRejection)
    }

    /// Which errors mean "the token is bad" is decided by `needsAccount`, and
    /// nothing else may.
    @Test("Only 401 and 403 say the credential is wrong", arguments: [
        (401, true), (403, true), (500, false), (429, false), (404, false)
    ])
    func rejectionStatuses(_ status: Int, _ isRejection: Bool) {
        #expect(APIError.server(status: status, message: "x").needsAccount == isRejection)
    }

    @Test("Offline is never a rejection")
    func offlineIsNotRejection() {
        #expect(!APIError.offline.needsAccount)
        #expect(!APIError.rateLimited(retryAfter: 30).needsAccount)
        #expect(!APIError.decoding(underlying: "x").needsAccount)
    }

    /// An account with no display name is still signed in.
    @Test("A nameless account is accepted")
    func namelessAccount() {
        #expect(!TokenCheck.accepted(nil).isRejection)
    }
}

/// A count that is a floor must not be stated as a total, and a failure to
/// fetch must not read as an absence.
@Suite("Partial data is not reported as fact")
@MainActor
struct PartialDataTests {
    private final class FailingLibrary: LibraryProviding, @unchecked Sendable {
        let entries: [LibraryEntry]
        let failOnPage: Int

        init(entries: [LibraryEntry], failOnPage: Int) {
            self.entries = entries
            self.failOnPage = failOnPage
        }

        func recommendationStatus() async -> RecommendationStatus? { nil }
        func recommendations(
            limit: Int, page: Int, excluding: [Int]
        ) async -> [PersonalRecommendation] { [] }
        func hiddenTagIDs() async -> Set<Int>? { [] }
        func topGenres() async -> [TopGenre]? { [] }
        func add(seriesId: Int, state: LibraryEntry.State) async throws(APIError) -> Bool { true }
        func remove(seriesId: Int) async throws(APIError) {}
        func update(seriesId: Int, change: LibraryChange) async throws(APIError) {}
        func library(page: Int, limit: Int) async -> [LibraryEntry] {
            (try? await libraryPage(page: page, limit: limit)) ?? []
        }

        func libraryPage(page: Int, limit: Int) async throws(APIError) -> [LibraryEntry] {
            if page == failOnPage { throw APIError.offline }
            return entries
        }
    }

    /// The reported bug: an empty result meant "no account", so a reader with a
    /// working token on a bad connection was told to add a token.
    @Test("A failed fetch is not an empty library")
    func failureIsNotEmptiness() async {
        let model = LibraryModel(library: FailingLibrary(entries: [], failOnPage: 1))
        await model.load()

        #expect(model.entries.isEmpty)
        #expect(model.hasAccount, "an unreachable library is not an absent account")
        #expect(!model.isComplete)
        #expect(model.failure != nil)
        // The failure was stored and read by no view: a reader offline with 937
        // series saw "Nothing saved yet". The screen picks its state here.
        guard case .failed = model.screenState else {
            Issue.record("A walk that failed with nothing shown must render as a failure, not emptiness")
            return
        }
    }

    @Test("An empty library with no failure is the empty state")
    func emptyRendersAsEmpty() async {
        let model = LibraryModel(library: FailingLibrary(entries: [], failOnPage: 99))
        await model.load()
        #expect(model.screenState == .noAccount)
    }

    /// A genuinely empty library still reads as one.
    @Test("An empty library is still empty")
    func genuinelyEmpty() async {
        let model = LibraryModel(library: FailingLibrary(entries: [], failOnPage: 99))
        await model.load()

        #expect(!model.hasAccount)
        #expect(model.isComplete)
        #expect(model.failure == nil)
    }
}

/// The way back out of a run of swipes.
///
/// The stack blends what comes next from what has been saved, so a handful of
/// swipes in a direction the reader did not mean sends every card after them
/// the same way — and there is no unswipe.
@Suite("Starting the stack over", .enabled(if: SourceTree.isAvailable))
struct StackResetTests {
    @Test("The stack can be emptied and re-dealt")
    func resetExists() throws {
        let model = try SourceTree.read("MangaBaka/Features/Stack/StackModel.swift")
        #expect(model.contains("func resetStack()"))
        // Every piece of state that decides what comes next has to go, or the
        // reset deals the same cards again.
        for cleared in ["reacted = []", "saved = []", "queue = []", "seedPool = []"] {
            #expect(model.contains(cleared), "resetStack leaves \(cleared) behind")
        }
        #expect(model.contains("try? await shelf.clear()"))
    }

    /// Deleting rows from someone's real account to undo a swipe is a much
    /// larger action than the one being asked for.
    @Test("The reset does not touch the reader's MangaBaka library")
    func resetIsLocal() throws {
        let shelf = try SourceTree.read("MangaBaka/Features/Shelf/ShelfStore.swift")
        #expect(shelf.contains("func clear()"))
        #expect(shelf.contains("ShelfEntry.deleteAll(db)"))

        let model = try SourceTree.read("MangaBaka/Features/Stack/StackModel.swift")
        // The one thing it must not do.
        #expect(!model.contains("library.remove("))
    }

    /// It throws away every save and skip on the device, so it asks first — and
    /// says what it will and will not touch.
    @Test("It is confirmed, and the confirmation is honest")
    func resetIsConfirmed() throws {
        let menu = try SourceTree.read("MangaBaka/Features/Stack/StackResetMenu.swift")
        #expect(menu.contains("confirmationDialog"))
        #expect(menu.contains("MangaBaka library stays there"))

        let view = try SourceTree.read("MangaBaka/Features/Stack/StackView.swift")
        #expect(view.contains("resetStack()"))
    }
}

/// MangaBaka's own homepage carries four rails; this app had three.
@Suite("Discover rows")
struct DiscoverRowTests {
    /// Their "New releases". `sort_by=latest` is what backs it — checked
    /// against the live search endpoint, which returns rows for it.
    @Test("New releases asks for the latest, and can page")
    func newReleasesFeed() {
        #expect(FeedKind.newReleases.path == "/v2/series/search")
        #expect(
            FeedKind.newReleases.extraQuery
                .contains { $0.name == "sort_by" && $0.value == "latest" }
        )
        #expect(FeedKind.newReleases.supportsPaging)
    }

    /// Its own cache key, or it would share one with another search-backed row
    /// and serve that row's results.
    @Test("Every feed caches under its own key")
    func distinctCacheKeys() {
        let keys = [
            FeedKind.rising, .hiddenGems, .trending, .newReleases, .surprise
        ].map(\.cacheKey)
        #expect(Set(keys).count == keys.count)
    }

    /// The row is only worth having if it is fresher than the rest; a day-long
    /// cache would make "new releases" a day old.
    @Test("New releases is cached for less than a day")
    func freshness() {
        #expect(FeedKind.newReleases.freshness < FeedKind.rising.freshness)
    }
}
