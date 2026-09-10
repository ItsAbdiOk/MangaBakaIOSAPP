import Foundation
import Testing
@testable import MangaBaka

/// The cast row, built from Shikimori.
///
/// AniList was asked for and was the obvious source. Its GraphQL API answers
/// every request with HTTP 403 and its own message — "The AniList API has been
/// temporarily disabled due to severe stability issues" — checked repeatedly on
/// 2026-09-10, so not a blip. Shikimori is already one of MangaBaka's upstream
/// sources and its id arrives in every series' `source` block.
@Suite("Characters")
struct CharacterTests {
    private static let base = URL(string: "https://shikimori.one")!

    /// Built as JSON so the decoder is exercised too — Shikimori's shape is
    /// the thing most likely to change under us.
    private func role(id: Int, name: String, roles: [String], image: String?) -> ShikimoriRole {
        let roleList = roles.map { "\"\($0)\"" }.joined(separator: ",")
        let imageValue = image.map { "\"\($0)\"" } ?? "null"
        return decode("""
        {"roles": [\(roleList)],
         "character": {"id": \(id), "name": "\(name)",
                       "image": {"x96": \(imageValue), "preview": null}}}
        """)
    }

    /// A staff row: the author and the artist arrive in the same list with a
    /// null character.
    private func staffRole(_ job: String) -> ShikimoriRole {
        decode("{\"roles\": [\"\(job)\"], \"character\": null}")
    }

    private func decode(_ json: String) -> ShikimoriRole {
        guard let row = try? JSONDecoder().decode(ShikimoriRole.self, from: Data(json.utf8)) else {
            fatalError("Shikimori fixture no longer decodes: \(json)")
        }
        return row
    }

    /// The author and the artist arrive in the same list as the cast, with a
    /// null character. They are already in the credits table.
    @Test("Staff rows are not characters")
    func staffDropped() {
        let rows = [
            staffRole("Story"),
            role(id: 1, name: "Jin-woo Sung", roles: ["Main"], image: "/system/characters/x96/1.jpg")
        ]
        let cast = ShikimoriCast.cast(from: rows, baseURL: Self.base, limit: 20)
        #expect(cast.map(\.name) == ["Jin-woo Sung"])
    }

    /// Shikimori returns a placeholder image rather than null. Of Solo
    /// Leveling's 95 characters most carry one, and a row of identical grey
    /// circles says nothing and reads as broken.
    @Test("A placeholder portrait is not a portrait")
    func placeholdersDropped() {
        let rows = [
            role(id: 1, name: "Has a face", roles: ["Main"], image: "/system/characters/x96/1.jpg"),
            role(id: 2, name: "No face", roles: ["Supporting"], image: "/assets/globals/missing_x96.jpg")
        ]
        let cast = ShikimoriCast.cast(from: rows, baseURL: Self.base, limit: 20)
        #expect(cast.map(\.name) == ["Has a face"])
    }

    @Test("The placeholder is recognised by its path", arguments: [
        ("/assets/globals/missing_x96.jpg", true),
        ("/assets/globals/missing_original.jpg", true),
        ("/system/characters/x96/174185.jpg?1711055777", false)
    ])
    func placeholderDetection(_ path: String, _ expected: Bool) {
        #expect(ShikimoriCast.isMissingPortrait(path) == expected)
    }

    /// Shikimori orders the supporting cast alphabetically, so without this the
    /// row opens on whoever's name begins with A rather than on the lead.
    @Test("Main characters lead")
    func mainFirst() {
        let rows = [
            role(id: 2, name: "Ahn", roles: ["Supporting"], image: "/system/characters/x96/2.jpg"),
            role(id: 1, name: "Jin-woo", roles: ["Main"], image: "/system/characters/x96/1.jpg"),
            role(id: 3, name: "Baek", roles: ["Supporting"], image: "/system/characters/x96/3.jpg")
        ]
        let cast = ShikimoriCast.cast(from: rows, baseURL: Self.base, limit: 20)
        #expect(cast.map(\.name) == ["Jin-woo", "Ahn", "Baek"])
        #expect(cast[0].isMain)
    }

    /// Alphabetical order within the supporting cast has to survive the sort,
    /// or the row reshuffles for no reason a reader can see.
    @Test("Order within a group is preserved")
    func stableWithinGroup() {
        let rows = (1...5).map { index in
            role(
                id: index,
                name: "Name \(index)",
                roles: ["Supporting"],
                image: "/system/characters/x96/\(index).jpg"
            )
        }
        let cast = ShikimoriCast.cast(from: rows, baseURL: Self.base, limit: 20)
        #expect(cast.map(\.name) == ["Name 1", "Name 2", "Name 3", "Name 4", "Name 5"])
    }

    /// Solo Leveling returns 95. A row of 95 portraits is a scroll, not a
    /// summary.
    @Test("The cast is capped")
    func capped() {
        let rows = (1...95).map { index in
            role(
                id: index,
                name: "N\(index)",
                roles: ["Supporting"],
                image: "/system/characters/x96/\(index).jpg"
            )
        }
        #expect(ShikimoriCast.cast(from: rows, baseURL: Self.base, limit: 20).count == 20)
    }

    /// Shikimori's paths are host-relative; rendered as-is they are broken
    /// images with no error.
    @Test("Portrait paths are resolved against the host")
    func absoluteURLs() {
        let rows = [role(id: 1, name: "A", roles: ["Main"], image: "/system/characters/x96/1.jpg")]
        let cast = ShikimoriCast.cast(from: rows, baseURL: Self.base, limit: 20)
        #expect(cast.first?.imageURL?.absoluteString == "https://shikimori.one/system/characters/x96/1.jpg")
    }

    /// Their terms refuse an unidentified client.
    @Test("The client identifies itself")
    func userAgent() {
        #expect(ShikimoriClient.userAgent.contains("MangaBaka"))
        #expect(ShikimoriClient.userAgent.contains("github.com"))
        // Their published limit is five a second; this must stay under it.
        #expect(ShikimoriClient.minimumInterval >= 0.2)
    }
}

/// A completed series will never release again, so an estimate for one is not a
/// weak answer — it is a wrong one. The page showed "Completed · 3 years
/// overdue" for Solo Leveling, which is what a median gap says about a series
/// that stopped.
@Suite("Only unfinished series get a release estimate")
struct ScheduleScopeTests {
    @Test("A finished series can never release", arguments: [
        ("completed", false), ("cancelled", false), ("unknown", false),
        ("releasing", true), ("hiatus", true), ("on_hiatus", true)
    ])
    func canRelease(_ status: String, _ expected: Bool) {
        #expect(ReleaseScheduleService.canRelease(status: status) == expected)
    }

    /// A hiatus is a stop with no announced end, so the past rhythm says
    /// nothing about the next chapter. Omniscient Reader read "LIKELY · 93 days
    /// overdue · about every 7 days, very evenly", which describes a schedule
    /// the series is no longer on.
    @Test("A series on hiatus is not predicted", arguments: [
        ("releasing", true), ("hiatus", false), ("on_hiatus", false),
        ("completed", false), ("cancelled", false)
    ])
    func canPredict(_ status: String, _ expected: Bool) {
        #expect(ReleaseScheduleService.canPredict(status: status) == expected)
    }

    /// A hiatus series still belongs on the calendar — the reader is partway
    /// through it and wants to see it there. It just gets no number.
    @Test("A hiatus series stays on the calendar without an estimate")
    func hiatusStaysInScope() {
        #expect(ReleaseScheduleService.isInScope(state: .reading, status: "hiatus"))
        #expect(!ReleaseScheduleService.canPredict(status: "hiatus"))
    }

    @Test("Predicting is never broader than releasing", arguments: [
        "releasing", "hiatus", "on_hiatus", "completed", "cancelled", "unknown"
    ])
    func predictImpliesRelease(_ status: String) {
        if ReleaseScheduleService.canPredict(status: status) {
            #expect(ReleaseScheduleService.canRelease(status: status))
        }
    }

    @Test("A missing status is not treated as releasing")
    func missingStatus() {
        #expect(!ReleaseScheduleService.canRelease(status: nil))
    }

    /// The calendar is for what the reader is partway through. Completed and
    /// dropped are finished with whatever the series is still doing, and
    /// plan-to-read has not started.
    @Test("Only reading, rereading and paused are scheduled", arguments: LibraryEntry.State.allCases)
    func statesInScope(_ state: LibraryEntry.State) {
        let expected: Bool = switch state {
        case .reading, .rereading, .paused: true
        case .completed, .dropped, .planToRead, .considering: false
        }
        #expect(ReleaseScheduleService.isInScope(state: state, status: "releasing") == expected)
    }

    /// Both conditions are required. A paused entry on a completed series is
    /// still nothing to wait for.
    @Test("A paused entry on a finished series is out of scope")
    func bothConditionsRequired() {
        #expect(!ReleaseScheduleService.isInScope(state: .paused, status: "completed"))
        #expect(ReleaseScheduleService.isInScope(state: .paused, status: "releasing"))
    }
}
