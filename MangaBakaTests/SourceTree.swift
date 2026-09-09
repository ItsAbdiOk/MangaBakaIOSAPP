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

    static func read(_ relativePath: String) throws -> String {
        try String(contentsOfFile: "\(root)/\(relativePath)", encoding: .utf8)
    }
}
