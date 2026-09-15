import Foundation
import Testing
@testable import MangaBaka

/// `EditionShelf` and `VolumeEditionAnswer`'s own pure members — coverage
/// measured 2026-09-15 at 54.5% of 44 executable lines in `EditionShelf.swift`.
/// `VolumeEditionMergeTests`, `VolumeEditionShelfTests` and `ANNVolumesTests`
/// already exercise most of this file, but only ever by driving
/// `VolumeEditions.merge` and reading the shelves it produces — never by
/// constructing an `EditionShelf` or `VolumeEditionAnswer` directly and
/// reading its own members. These are characterisation tests of already-
/// shipped, already-correct code, so each states the plausible regression it
/// would catch rather than a pre-change compile failure.
@Suite("EditionShelf and VolumeEditionAnswer")
struct EditionShelfTests {
    private var edition: VolumeEdition {
        VolumeEdition(
            catalogue: .nationalDietLibrary, language: "ja", languageRole: .original,
            editionTitle: "スクウェア・エニックス"
        )
    }

    private func volume(_ number: Int, _ date: String?, format: VolumeFormat = .print) -> EditionVolume {
        EditionVolume(
            number: number, title: "薬屋のひとりごと. \(number)",
            releaseDate: date.flatMap(PartialDate.parse), isbn13: "978000000000\(number)",
            format: format, edition: edition, sourceLink: nil
        )
    }

    // MARK: - EditionShelf.id

    /// A regression here is `id` dropping `format` from its composition — two
    /// shelves of one edition (a print run and its eBook) would then share
    /// one `id`, and SwiftUI's `ForEach` silently drops the second view for a
    /// duplicate id rather than crashing, so the eBook shelf would just not
    /// render. `VolumeEditionShelfTests.printAndDigitalAreSeparateShelves`
    /// already asserts `print.id != digital.id`; this pins what the id
    /// actually is, not merely that two of them differ.
    @Test("The shelf id is the edition's id plus the format")
    func idIncludesFormat() {
        let print = EditionShelf(edition: edition, format: .print, volumes: [volume(1, "2020-01-01")])
        let digital = EditionShelf(edition: edition, format: .digital, volumes: [volume(1, "2020-01-01")])
        #expect(print.id == "\(edition.id)-print")
        #expect(digital.id == "\(edition.id)-digital")
        #expect(print.id != digital.id)
    }

    // MARK: - EditionShelf.init defaults

    /// A regression here is the default `format`/`isPartial` silently
    /// changing — every client but NDL builds a shelf through this shorter
    /// initializer, on the assumption that leaving `format` and `isPartial`
    /// unstated means "a complete, printed shelf".
    @Test("The short initializer defaults to a complete print shelf")
    func shortInitDefaultsToCompletePrint() {
        let shelf = EditionShelf(edition: edition, volumes: [volume(1, "2020-01-01")])
        #expect(shelf.format == .print)
        #expect(!shelf.isPartial)
    }

    /// A regression here is `isPartial` being dropped on the way in — a
    /// shelf built from NDL's first page would then read as complete, which
    /// is the exact Serious 2 bug `NDLEditionTests.partialPage` and
    /// `VolumeEditionShelfTests.partialLegMarksItsShelf` both exist to catch,
    /// pinned here at the point closest to the property itself.
    @Test("isPartial threads through the full initializer unchanged")
    func isPartialThreadsThroughInit() {
        let partial = EditionShelf(edition: edition, volumes: [volume(1, "2020-01-01")], isPartial: true)
        let complete = EditionShelf(edition: edition, volumes: [volume(1, "2020-01-01")], isPartial: false)
        #expect(partial.isPartial)
        #expect(!complete.isPartial)
    }

    // MARK: - VolumeEditionAnswer.empty / isEmpty

    /// A regression here is `.empty` gaining a non-nil `unaskedReason` other
    /// than `.notAsked`, or a non-empty `credits`/`failures` — any of which
    /// would make a screen that has not asked yet render as though it had
    /// asked and failed, or worse, show a credit for a source that
    /// contributed nothing (the exact rule `credits`' own doc comment states).
    @Test("The empty answer is empty on every field, and says not-asked")
    func emptyAnswerIsFullyEmpty() {
        let answer = VolumeEditionAnswer.empty
        #expect(answer.isEmpty)
        #expect(answer.shelves.isEmpty)
        #expect(answer.credits.isEmpty)
        #expect(answer.failures.isEmpty)
        #expect(answer.unaskedReason == .notAsked)
    }

    /// The control for the test above: a non-empty `shelves` must flip
    /// `isEmpty` to false, so the property is reading `shelves` and not
    /// returning a constant.
    @Test("isEmpty is false once there is a shelf to show")
    func isEmptyReflectsShelves() {
        let answer = VolumeEditionAnswer(
            shelves: [EditionShelf(edition: edition, volumes: [volume(1, "2020-01-01")])],
            credits: [.nationalDietLibrary], failures: [:], unaskedReason: nil
        )
        #expect(!answer.isEmpty)
    }

    // MARK: - VolumeEditionAnswer.forthcoming(asOf:)

    /// A regression here is picking the soonest volume *within whichever
    /// shelf happens to be first* rather than across every shelf — the
    /// symptom would be a series with two editions (NDL and ANN, say) always
    /// reporting the first edition's next volume even when the other
    /// edition's is sooner.
    @Test("The soonest announced volume wins across shelves, not just within one")
    func forthcomingIsSoonestAcrossShelves() throws {
        let now = try #require(PartialDate.parse("2026-09-14")?.date)
        let nearEdition = VolumeEdition(
            catalogue: .animeNewsNetwork, language: "en", languageRole: .english, editionTitle: nil
        )
        let near = EditionShelf(edition: nearEdition, volumes: [volume(2, "2026-09-20", format: .print)])
        let far = EditionShelf(edition: edition, volumes: [volume(14, "2026-12-01", format: .print)])
        let answer = VolumeEditionAnswer(
            shelves: [far, near], credits: [.nationalDietLibrary, .animeNewsNetwork], failures: [:],
            unaskedReason: nil
        )
        guard case let .announced(soonest) = answer.forthcoming(asOf: now) else {
            Issue.record("Expected .announced, got \(answer.forthcoming(asOf: now))")
            return
        }
        #expect(soonest.number == 2, "The near edition's volume is the sooner of the two")
    }

    /// A regression here is `unaskedReason` being ignored once any shelf
    /// exists — this must win outright, because a caller sets it precisely
    /// to say "don't trust `shelves` yet" (`unaskedReason`'s own doc comment).
    @Test("An unaskedReason overrides whatever the shelves would otherwise say")
    func unaskedReasonWinsOverShelves() throws {
        let now = try #require(PartialDate.parse("2026-09-14")?.date)
        let shelf = EditionShelf(edition: edition, volumes: [volume(2, "2026-09-20")])
        let answer = VolumeEditionAnswer(
            shelves: [shelf], credits: [.nationalDietLibrary], failures: [:], unaskedReason: .notAsked
        )
        #expect(answer.forthcoming(asOf: now) == .unknown(.notAsked))
    }

    // MARK: - EditionShelvesSection.heading(for:) — the digital case

    /// `VolumeEditionShelfTests.boxSetIsItsOwnShelf` already pins the box-set
    /// suffix; the digital one was untested. A regression here is the
    /// `.digital` branch losing its suffix, which would show a print and an
    /// eBook shelf under the identical heading with no way to tell them
    /// apart.
    @Test("The digital shelf's heading appends eBook")
    func headingAppendsEBookForDigitalShelf() {
        let shelf = EditionShelf(
            edition: VolumeEdition(
                catalogue: .animeNewsNetwork, language: "en", languageRole: .english,
                editionTitle: "VIZ Media"
            ),
            format: .digital, volumes: [volume(1, "2020-01-01", format: .digital)]
        )
        #expect(EditionShelvesSection.heading(for: shelf) == "English · VIZ Media · eBook")
    }
}
