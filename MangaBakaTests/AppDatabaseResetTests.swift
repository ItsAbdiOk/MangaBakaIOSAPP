import Foundation
import Testing
@testable import MangaBaka

/// Gap 3: a corrupt on-disk cache used to fall through, silently, to an
/// in-memory database that remembers nothing between launches — "the app
/// forgets my stack every day" with no explanation and no way to notice why.
/// `AppDatabase.onDiskResettingIfCorrupt` renames the bad file aside and
/// opens a fresh one instead, so the reader gets a working, persistent
/// database and a one-shot toast rather than an amnesiac app every launch.
@Suite("Database open recovers from a corrupt file", .serialized)
struct AppDatabaseResetTests {
    /// A name unique per run, so a test failure never leaves a stray file
    /// that the next run's control case could accidentally open.
    private func testName() -> String { "resettest-\(UUID().uuidString).sqlite" }

    private func applicationSupportURL(for name: String) throws -> URL {
        try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ).appendingPathComponent(name)
    }

    private func cleanUp(_ name: String) throws {
        let url = try applicationSupportURL(for: name)
        let directory = url.deletingLastPathComponent()
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            return
        }
        for entry in contents where entry.hasPrefix(name) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(entry))
        }
    }

    /// Expected to fail before the fix with: `onDiskResettingIfCorrupt` did
    /// not exist — the only entry point was `onDisk`, which throws and
    /// leaves the caller to fall back to an in-memory database with the bad
    /// file left exactly where it was, forever failing the same way on every
    /// subsequent launch.
    @Test("Garbage at the path produces a working database and a renamed file")
    func recoversFromCorruptFile() throws {
        let name = testName()
        defer { try? cleanUp(name) }

        let url = try applicationSupportURL(for: name)
        // Not valid SQLite by construction — a real corruption is bytes a
        // previous, working file was truncated or overwritten into, but any
        // non-SQLite content exercises the same "cannot be opened" path.
        try Data("this is not a sqlite file".utf8).write(to: url)

        let result = try #require(AppDatabase.onDiskResettingIfCorrupt(named: name))
        #expect(result.wasReset)

        // The fresh database actually works — a write followed by a read,
        // proving this is not merely "did not throw".
        try result.database.writer.write { db in
            try db.execute(sql: "CREATE TABLE IF NOT EXISTS probe(id INTEGER)")
            try db.execute(sql: "INSERT INTO probe(id) VALUES (1)")
        }
        let count = try result.database.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM probe")
        }
        #expect(count == 1)

        // The bad file was renamed aside, not deleted outright.
        let directory = url.deletingLastPathComponent()
        let contents = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        let renamed = contents.filter { $0.hasPrefix("\(name).corrupt-") }
        #expect(renamed.count == 1, "expected exactly one renamed-aside copy, found \(renamed)")
    }

    /// Control: a file that opens cleanly must not be touched or reported as
    /// reset. Without this, a test that only checked the corrupt path could
    /// pass by coincidence — say, if `wasReset` were hardcoded `true`.
    @Test("A good file opens without being renamed")
    func goodFileIsNotReset() throws {
        let name = testName()
        defer { try? cleanUp(name) }

        // Opened once for real, through the ordinary path, so the file on
        // disk is a genuine, migrated database rather than a hand-rolled
        // approximation of one.
        _ = try AppDatabase.onDisk(named: name)

        let result = try #require(AppDatabase.onDiskResettingIfCorrupt(named: name))
        #expect(!result.wasReset)

        let directory = try applicationSupportURL(for: name).deletingLastPathComponent()
        let contents = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(!contents.contains { $0.hasPrefix("\(name).corrupt-") })
    }
}
