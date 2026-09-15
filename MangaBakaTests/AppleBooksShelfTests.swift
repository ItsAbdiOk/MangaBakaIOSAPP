import Foundation
import Testing
@testable import MangaBaka

/// Gated per test, not per suite (2026-09-14): the gate on the suite also
/// skipped the tests below that assert on a value and never touch the
/// checkout, so they did not run on Xcode Cloud at all — and nothing
/// reports the difference between a local run and a cloud one.
@Suite("Apple volumes on the page")
struct AppleVolumesRowTests {
    /// One spine on the shelf, built the way the page builds it.
    @MainActor
    private func row(_ volume: AppleBooksVolume, expected: Int?) -> AppleVolumesRow {
        AppleVolumesRow(
            volumes: VolumeShelf.merge(apple: [volume], google: []), expected: expected
        )
    }

    @Test("The count admits when the store is behind the series")
    @MainActor
    func countLine() {
        let volume = AppleBooksVolume(
            id: 1, number: 1, title: "x", artworkURL: nil, storeURL: nil,
            price: nil, formattedPrice: nil, releaseDate: nil
        )
        #expect(row(volume, expected: 27).countLine == "1 of 27 on Apple Books")
        #expect(row(volume, expected: 1).countLine == "1")
        #expect(row(volume, expected: nil).countLine == "1")
    }

    /// S12: `countLine` used to compare a count with a number
    /// (`expected > volumes.count`), so a 15-volume shelf numbered 1-14 and
    /// 30 — missing volume 15 itself — read as complete because the *count*
    /// already matched `expected`. Before the fix this line would have
    /// read: `#expect(built.countLine == "15")`.
    @Test("The count admits a gap even when the total already matches")
    @MainActor
    func countLineChecksCoverage() {
        let numbers = Array(1...14) + [30]
        let volumes = numbers.map {
            AppleBooksVolume(
                id: $0, number: $0, title: "x", artworkURL: nil, storeURL: nil,
                price: nil, formattedPrice: nil, releaseDate: nil
            )
        }
        let built = AppleVolumesRow(volumes: VolumeShelf.merge(apple: volumes, google: []), expected: 15)
        #expect(
            built.countLine == "15 of 15 on Apple Books",
            "15 numbered volumes, but volume 15 itself is missing"
        )
    }

    /// The phone showed MangaBaka's seven One Piece editions with no hint
    /// of the store, and it was not possible to tell a failed request from
    /// a build without the feature. Now a failure says so.
    /// A series the reader's store does not sell falls back to the Japanese
    /// store's edition — covers and a count, no price, and it says so.
    @Test("Nothing at home, so the Japanese edition, labelled", .enabled(if: SourceTree.isAvailable))
    func japaneseFallback() throws {
        let source = try SourceTree.read("MangaBaka/Features/Detail/SeriesDetailView+Store.swift")
        // `(try? answer.get())?.isEmpty`, not `answer?.isEmpty`, since item
        // 60 made `volumes` return a `Result` — the rule is unchanged: an
        // empty home store, never a failed one, is what falls back.
        #expect(
            source.contains("if (try? answer.get())?.isEmpty == true, country.lowercased() != \"jp\"")
        )
        #expect(source.contains("answer = await appleBooks.japaneseVolumes(for: shown)"))
        let row = try SourceTree.read("MangaBaka/Features/Detail/AppleVolumesRow.swift")
        #expect(row.contains("if edition == nil, let price = volume.formattedPrice"))
    }

    /// Item 60 replaced the `Bool` this used to pin. `appleUnreachable` said
    /// only "something went wrong" and `VolumesSection` rendered it as one
    /// bare sentence with no retry; `appleFailure: APIError?` carries the
    /// reason, and the section renders the same `InlineFailure` every other
    /// section on the page has had since gap 10.
    @Test(
        "A store that could not be reached says which failure, and offers a retry",
        .enabled(if: SourceTree.isAvailable)
    )
    func failureIsSaid() throws {
        let source = try SourceTree.read("MangaBaka/Features/Detail/SeriesDetailView+Store.swift")
        #expect(source.contains("case let .failure(error):"))
        #expect(source.contains("appleFailure = error"))
        #expect(source.contains("failure: appleFailure,"))
        #expect(source.contains("retry: { await loadAppleVolumes() },"))
    }

    @Test(
        "The store's shelf replaces MangaBaka's editions, never joins them",
        .enabled(if: SourceTree.isAvailable)
    )
    func replaces() throws {
        let source = try SourceTree.read("MangaBaka/Features/Detail/SeriesDetailView+Store.swift")
        // `shelf`, not `appleVolumes`: the shelf is now Apple's volumes plus
        // any number only Google has (VolumeShelf.merge). The rule this pins
        // is unchanged — one shelf or the other, never both at once.
        let either = "if shelf.isEmpty {\n            VolumesSection(\n"
        #expect(source.contains(either))
        #expect(source.contains("volumes: extras.volumes,"))
    }
}

/// Which shelf spines are worth asking `OpenLibraryCovers` about at all —
/// the ones neither Apple nor Google sent artwork for.
@Suite("Open Library gap detection on the shelf")
struct VolumeShelfOpenLibraryTests {
    private func volume(
        _ number: Int, artwork: URL?, source: ShelfVolume.Source = .appleBooks
    ) -> ShelfVolume {
        let cover = Cover(
            raw: artwork, x150: nil, x250: nil, x350: nil, blurhash: nil, width: nil, height: nil
        )
        return ShelfVolume(number: number, cover: cover, link: nil, formattedPrice: nil, source: source)
    }

    @Test("Only the numbers with no artwork of their own are flagged")
    func onlyBareNumbersFlagged() {
        let art = URL(string: "https://example.com/1.jpg")
        let volumes = [volume(1, artwork: art), volume(2, artwork: nil)]
        #expect(VolumeShelf.numbersNeedingCovers(volumes) == [2])
    }

    @Test("Attribution names Open Library only when it was actually used")
    func attributionNamesOpenLibraryOnlyWhenUsed() {
        let volumes = [volume(1, artwork: nil)]
        #expect(VolumeShelf.attribution(for: volumes) == "Apple Books")
        #expect(
            VolumeShelf.attribution(for: volumes, openLibraryUsed: true) == "Apple Books & Open Library"
        )
        let both = volumes + [volume(2, artwork: nil, source: .googleBooks)]
        #expect(
            VolumeShelf.attribution(for: both, openLibraryUsed: true) == "Apple & Google Books & Open Library"
        )
    }
}

/// S2: `SeriesWork.date` parses a release date as UTC midnight on purpose —
/// reading it back through the device's own calendar rolls a 1 January
/// release onto 31 December of the previous year for every reader west of
/// UTC. Before the fix, `VolumesSection` read the year with
/// `Calendar.current.component(.year, from:)`, so on a device set to
/// America/Los_Angeles this control would have read 2020, not 2021.
@Suite("Volume spine year")
struct VolumesSectionSpineYearTests {
    @Test("The spine year is read in UTC, not the device's own zone")
    func spineYearIsUTC() {
        let utcMidnight = Date(timeIntervalSince1970: 1_609_459_200) // 2021-01-01T00:00:00Z
        #expect(VolumesSection.spineYear(for: utcMidnight) == 2021)

        // Control: this is the failure the fix guards against — the same
        // instant read through a negative-offset zone, which is what
        // `Calendar.current` would do on a US West Coast phone.
        var losAngeles = Calendar(identifier: .gregorian)
        losAngeles.timeZone = TimeZone(identifier: "America/Los_Angeles") ?? .current
        #expect(losAngeles.component(.year, from: utcMidnight) == 2020)
    }
}
