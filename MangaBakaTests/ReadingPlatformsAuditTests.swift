import Foundation
import Testing
@testable import MangaBaka

/// The 2026-09-14 guideline 5.2.3 audit of `ReadingPlatforms.allowed`, pinned.
///
/// The audit's own finding was a negative one — no aggregator in the list —
/// and the one removal it made is the only part of it a test can hold. See
/// `ReadingPlatforms`'s doc comment for what was checked live and what was
/// taken on recognition.
@Suite("Reading platforms — 5.2.3 audit")
struct ReadingPlatformsAuditTests {
    /// `ono.live` is the one entry nobody could identify: a live request
    /// answers 202 with an empty body, and there is no publisher or platform
    /// behind the name. An allowlist whose value is that it fails closed
    /// cannot carry an entry that means "we do not know".
    @Test("An entry nobody could identify is no longer offered as somewhere to read")
    func unidentifiedHostIsRefused() {
        #expect(ReadingPlatforms.allows(URL(string: "https://ono.live/title/1234")) == false)
        #expect(ReadingPlatforms.allows(URL(string: "https://www.ono.live/en/reader/9")) == false)
        #expect(ReadingPlatforms.allowed.contains("ono.live") == false)
    }

    /// The control. Without this, the assertion above would pass just as well
    /// against an `allows` that had been broken into refusing everything —
    /// which is exactly the "a moving number is not proof" failure, applied to
    /// a boolean.
    @Test("A host the audit kept is still offered")
    func identifiedHostIsStillAllowed() {
        // Hakusensha's マンガPark, confirmed by its own page title on
        // 2026-09-14 — the entry the audit most expected to have to remove,
        // since MangaPark the scanlation site has a near-identical name.
        #expect(ReadingPlatforms.allows(URL(string: "https://manga-park.com/title/123")))
        #expect(ReadingPlatforms.allows(URL(string: "https://www.webtoons.com/en/fantasy/x/list?title_no=1")))
    }
}
