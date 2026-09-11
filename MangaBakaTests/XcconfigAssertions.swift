import Testing
import Foundation

/// Reading a build configuration the way the build system does.
///
/// **This exists because the same assertion was written twice and fixed once.**
/// Both `SecurityTests` and `LibraryTests` guarded the Release token, both did
/// it with `release.contains("MB_PAT =")`, and both comments claimed the value
/// was empty. Neither checked. One was fixed on 2026-09-11 and the duplicate
/// was missed, which is this project's characteristic defect — a correct rule
/// applied n−1 times out of n — reproduced inside the fix for it.
///
/// A third copy cannot drift from these two, because there is nothing to copy.
enum Xcconfig {
    static func read(_ name: String) throws -> String {
        try SourceTree.read("Configs/\(name)")
    }

    /// Every assignment of a key, as written.
    ///
    /// A list rather than one value: a config can assign the same key twice —
    /// conditionally, or by accident — and the last one wins. Checking only
    /// the first would pass a file whose second line reinstates a token.
    static func assignments(of key: String, in config: String) -> [String] {
        config
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix(key) }
    }

    /// The value side of an assignment, trimmed.
    static func value(of assignment: String) -> String {
        assignment.drop { $0 != "=" }.dropFirst().trimmingCharacters(in: .whitespaces)
    }

    /// Asserts a key is assigned, and assigned nothing.
    ///
    /// Both halves matter. Absent, a stale value could be inherited from the
    /// base config; present with a value, a credential ships.
    static func expectEmpty(_ key: String, in config: String, file: String) {
        let assignments = assignments(of: key, in: config)
        #expect(!assignments.isEmpty, "\(file) must set \(key), so no value can be inherited")
        for assignment in assignments {
            #expect(value(of: assignment).isEmpty, "\(file) assigns \(key) a value: \(assignment)")
        }
    }

    /// Whether a config pulls in the gitignored file that holds a real token.
    static func includesSecrets(_ config: String) -> Bool {
        config
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .contains { $0.hasPrefix("#include") && $0.contains("Secrets") }
    }
}
