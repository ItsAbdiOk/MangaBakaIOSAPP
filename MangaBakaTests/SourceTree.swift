import Foundation

/// Locates the project's source for tests that assert on the code itself.
///
/// These checks encode real regressions — a screen forgetting to reserve room
/// for the tab bar, a view reaching past the safe-URL accessor — but they read
/// files from the repository, and tests run inside the simulator. On a
/// developer's Mac the simulator shares the host filesystem so the files are
/// reachable; on a build machine they are not, and every such test failed with
/// "no such file".
///
/// So they run where they are useful and skip where they cannot work, rather
/// than failing a build for a reason that has nothing to do with the code.
enum SourceTree {
    static let root: String = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .path

    /// Whether the checkout is readable from wherever these tests are running.
    static var isAvailable: Bool {
        FileManager.default.fileExists(atPath: "\(root)/MangaBaka/App/MangaBakaApp.swift")
    }

    static func exists(_ relativePath: String) -> Bool {
        FileManager.default.fileExists(atPath: "\(root)/\(relativePath)")
    }

    static func read(_ relativePath: String) throws -> String {
        try String(contentsOfFile: "\(root)/\(relativePath)", encoding: .utf8)
    }

    /// `contains`, but with every run of whitespace treated as equal.
    ///
    /// Five assertions pinned two adjacent statements as one literal including
    /// their exact indentation — `"selection = .library\n        shelfPath ="`.
    /// Those die on a re-indent, on a line moving inside an `if`, on anything
    /// Xcode's formatter does, and they fail saying "the wiring is gone" when
    /// the wiring is fine. Splitting them into two independent `contains` would
    /// lose what they are actually for, which is that the two statements are
    /// next to each other in that order; normalising the whitespace keeps that
    /// and drops only the part that was never the claim. Added 2026-09-14.
    static func containsRun(_ haystack: String, _ needle: String) -> Bool {
        squashed(haystack).contains(squashed(needle))
    }

    private static func squashed(_ text: String) -> String {
        text.replacingOccurrences(
            of: "[ \t\n\r]+", with: " ", options: .regularExpression
        )
    }

    /// Every Swift file under a directory, as repository-relative paths.
    ///
    /// For checks that have to look at the whole app rather than one file —
    /// "is this token used anywhere at all" cannot be answered from one.
    static func swiftFiles(under directory: String) throws -> [String] {
        try files(under: directory).filter { $0.hasSuffix(".swift") }
    }

    /// Every file under a directory, whatever its extension.
    ///
    /// Not only Swift: some rules are about what is *in* the app rather than
    /// what it does — shipping borrowed artwork, for one.
    static func files(under directory: String) throws -> [String] {
        let base = "\(root)/\(directory)"
        guard let walker = FileManager.default.enumerator(atPath: base) else { return [] }
        return walker
            .compactMap { $0 as? String }
            .map { "\(directory)/\($0)" }
    }
}
