import Foundation
import Testing
@testable import MangaBaka

/// Split from `LibraryCacheMoveTests` for the lint's type-body ceiling; same
/// on-disk database, same `TwoEntries` double.
@Suite("The library cache and storage rounding")
struct LibraryCacheRoundingTests {
    private func testName() -> String { "cacheround-\(UUID().uuidString).sqlite" }

    private func cleanUp(_ name: String) {
        guard let directory = try? AppDatabase.applicationSupportDirectory() else { return }
        let stem = (name as NSString).deletingPathExtension
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for entry in contents where entry.hasPrefix(stem) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(entry))
        }
    }

    /// The flake behind the hook failure of 2026-09-15: GRDB rounds a stored
    /// `Date` to the nearest millisecond, so a `cachedAt` written at
    /// `…0.0009996` reads back as `…0.001` — 0.4 µs after "now" — and a read
    /// that treats any negative age as a clock change re-walks the library.
    /// A clock frozen at exactly that instant makes the flake deterministic:
    /// fails on the old code with `provider.calls == 1`.
    @Test("A cachedAt that storage rounded forward still reads as fresh")
    func roundedForwardIsStillFresh() async throws {
        let name = testName()
        defer { cleanUp(name) }
        let clock = TestClock(now: Date(timeIntervalSince1970: 1_700_000_000.0009996))
        let database = try AppDatabase.onDisk(named: name)
        let first = LibrarySnapshot(
            library: LibraryCacheMoveTests.TwoEntries(), database: database, clock: clock
        )
        _ = await first.load()

        let provider = LibraryCacheMoveTests.TwoEntries()
        let again = LibrarySnapshot(library: provider, database: database, clock: clock)
        #expect(await again.load().entries.count == 2)
        #expect(provider.calls == 0, "read from disk; the half-millisecond is rounding, not a clock change")

        // The control: a clock genuinely behind the write is still stale.
        let behind = TestClock(now: clock.now.addingTimeInterval(-LibrarySnapshot.clockSlack - 1))
        let stale = LibraryCacheMoveTests.TwoEntries()
        _ = await LibrarySnapshot(library: stale, database: database, clock: behind).load()
        #expect(stale.calls == 1)
    }

}
