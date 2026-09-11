import Foundation
import Testing
@testable import MangaBaka

/// A guard on the tests themselves.
///
/// Several tests assert on the source code rather than on behaviour. They can
/// only run where the checkout is readable: tests execute inside the simulator,
/// which shares the filesystem on a developer's Mac and does not on a build
/// machine. An ungated one therefore PASSES locally and FAILS in the cloud —
/// the worst shape a test can have, because the local run cannot catch it and
/// the pre-push hook runs locally.
///
/// It has happened twice. The first time cost build 16; the second cost build
/// 21, after two source-reading tests were added without the gate.
///
/// This check reads source itself, so it is gated too. That is the point: it
/// runs on the machine where a push originates, which is the only place it
/// needs to run.
@Suite("Source-reading tests are gated", .enabled(if: SourceTree.isAvailable))
struct SourceTestGuardTests {
    @Test("Every test that reads the source declares it needs the source")
    func allSourceReadingTestsAreGated() throws {
        let directory = "\(SourceTree.root)/MangaBakaTests"
        let files = try FileManager.default
            .contentsOfDirectory(atPath: directory)
            .filter { $0.hasSuffix(".swift") }

        var ungated: [String] = []

        for file in files {
            let source = try String(contentsOfFile: "\(directory)/\(file)", encoding: .utf8)

            // Suites are split at a line start, not anywhere the attribute
            // name appears — prose in a comment mentioning it must not be read
            // as a declaration. This check failed on its own documentation the
            // first time it ran.
            for suite in source.components(separatedBy: "\n@Suite").dropFirst() {
                let declaration = suite.components(separatedBy: "{").first ?? ""
                let suiteIsGated = declaration.contains("SourceTree.isAvailable")

                for test in suite.components(separatedBy: "\n    @Test").dropFirst() {
                    // Any way of reaching the source tree counts, not only the
                    // helper: two suites read files through #filePath directly
                    // and the guard could not see them.
                    let readsSource = test.contains("SourceTree.read")
                        || test.contains("SourceTree.root")
                        || test.contains("SourceTree.swiftFiles")
                        || test.contains("contentsOfFile:")
                        || test.contains("#filePath")
                    guard readsSource, !suiteIsGated else { continue }

                    // The gate must sit in the test's own attribute, which
                    // ends at the closing paren before `func`.
                    let attribute = test.components(separatedBy: "func").first ?? ""
                    if !attribute.contains("SourceTree.isAvailable") {
                        let name = test
                            .components(separatedBy: "func ").dropFirst().first?
                            .components(separatedBy: "(").first ?? "unknown"
                        ungated.append("\(file): \(name)")
                    }
                }
            }
        }

        #expect(
            ungated.isEmpty,
            """
            These read the source without `.enabled(if: SourceTree.isAvailable)`. \
            They pass here and fail on a build machine, where the checkout is not \
            reachable from inside the simulator: \(ungated.joined(separator: ", "))
            """
        )
    }

    /// The guard is worthless if the thing it looks for gets renamed.
    @Test("The guard is looking for the accessor that actually exists")
    func guardMatchesTheAccessor() throws {
        let source = try SourceTree.read("MangaBakaTests/SourceTree.swift")
        #expect(source.contains("static func read("))
        #expect(source.contains("static var isAvailable"))
    }
}
