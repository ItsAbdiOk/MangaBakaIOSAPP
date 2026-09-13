import Foundation
import Testing
@testable import MangaBaka

/// Gaps 65/66 (`FAILURES-SUMMARY.md` §6, batch 2): a spine with no link
/// looked exactly like one that opens the store, and "15 of 27" never said
/// which store the count was short against.
@Suite("Apple volumes row")
@MainActor
struct AppleVolumesRowStateTests {
    private func volume(
        number: Int, source: ShelfVolume.Source = .appleBooks, link: URL? = nil
    ) -> ShelfVolume {
        ShelfVolume(number: number, cover: .empty, link: link, formattedPrice: nil, source: source)
    }

    // MARK: - Gap 66: which store the count is short against

    @Test("A short count on the reader's own shelf names Apple Books")
    func shortCountNamesAppleBooks() {
        let row = AppleVolumesRow(volumes: [volume(number: 1)], expected: 27)
        #expect(row.countLine == "1 of 27 on Apple Books")
    }

    @Test("A short count on the Japanese fallback names the Japanese store")
    func shortCountNamesJapaneseStore() {
        let row = AppleVolumesRow(volumes: [volume(number: 1)], expected: 27, edition: .japanese)
        #expect(row.countLine == "1 of 27 on the Japanese Apple Books")
    }

    @Test("A complete shelf states the count alone")
    func completeShelfHasNoStoreName() {
        let row = AppleVolumesRow(volumes: [volume(number: 1)], expected: 1)
        #expect(row.countLine == "1")
    }

    @Test("No expected total: the count alone, whatever it is")
    func noExpectedIsJustTheCount() {
        let row = AppleVolumesRow(volumes: [volume(number: 1), volume(number: 2)], expected: nil)
        #expect(row.countLine == "2")
    }
}

/// Gap 65: a spine with `link == nil` used to look exactly like every other
/// spine — same colour, same accessibility button trait, same hint — despite
/// `disabled(volume.link == nil)` making the tap itself do nothing.
@Suite("A dead spine looks dead", .enabled(if: SourceTree.isAvailable))
struct AppleVolumesRowDeadSpineTests {
    @Test("A spine with no link is dimmed and drops its button trait")
    func noLinkLooksDisabled() throws {
        let source = try SourceTree.read("MangaBaka/Features/Detail/AppleVolumesRow.swift")
        #expect(source.contains(".opacity(volume.link == nil ? 0.6 : 1)"))
        #expect(source.contains(".accessibilityAddTraits(volume.link == nil ? [] : .isButton)"))
    }
}
