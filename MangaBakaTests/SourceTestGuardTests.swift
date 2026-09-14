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
    /// Any way of reaching the source tree, checked against a chunk of source
    /// text — a test's own body, or a helper's.
    private static func readsSourceDirectly(_ text: Substring) -> Bool {
        text.contains("SourceTree.read")
            || text.contains("SourceTree.root")
            || text.contains("SourceTree.swiftFiles")
            || text.contains("contentsOfFile:")
            || text.contains("#filePath")
    }

    /// Names of every function declared in the suite — `@Test` or not — whose
    /// own body reads the source tree.
    ///
    /// `SeriesPageSourceRuleTests` calls a local `detail(_:)` that wraps
    /// `SourceTree.read`, and `detail` is declared *before* the suite's first
    /// `@Test`. Splitting on `"\n    @Test"` alone drops everything before
    /// that first marker into the piece `dropFirst()` throws away, so the
    /// helper's own `SourceTree.read` was never seen by anything — a test
    /// that only calls `detail(...)` read no gate-worthy string in its own
    /// text. This walks every `func` declaration in the suite independently
    /// of where the `@Test` markers fall, so a helper declared anywhere —
    /// before the first test, between two tests, doesn't matter — is found.
    private static func sourceReadingHelperNames(in suite: Substring) -> [String] {
        // Deliberately not bare `"\n    func "`: that also matches every
        // `@Test` method's own declaration line, and every test's own chunk
        // trivially contains its own name followed by `(`, in its own
        // signature — self-matching itself as a "helper" it calls. Helpers in
        // this codebase are declared `private`/`fileprivate`/`static`; a
        // plain `@Test` method never is, so restricting to these qualifiers
        // is what keeps a test's own name out of its own helper list.
        let helperMarkers = [
            "\n    private func ", "\n    fileprivate func ",
            "\n    static func ", "\n    private static func ", "\n    nonisolated static func "
        ]
        // A helper's own chunk has to stop at the next declaration of *any*
        // kind, not just the next one using the same marker — otherwise a
        // suite with exactly one `private func` swallows every `@Test` method
        // (and any real source read in one of them) into that single helper's
        // "body", and that helper trivially reads source that isn't its own.
        // So every helper start and every `@Test` start are collected
        // together and sorted, and a helper's chunk runs only to whichever
        // boundary — helper or test — comes next.
        var helperStarts: [(index: String.Index, isTest: Bool)] = []
        for marker in helperMarkers {
            var searchStart = suite.startIndex
            while let range = suite.range(of: marker, range: searchStart..<suite.endIndex) {
                helperStarts.append((range.upperBound, false))
                searchStart = range.upperBound
            }
        }
        var searchStart = suite.startIndex
        while let range = suite.range(of: "\n    @Test", range: searchStart..<suite.endIndex) {
            helperStarts.append((range.upperBound, true))
            searchStart = range.upperBound
        }
        helperStarts.sort { $0.index < $1.index }

        var names: [String] = []
        for (offset, boundary) in helperStarts.enumerated() where !boundary.isTest {
            let end = offset + 1 < helperStarts.count ? helperStarts[offset + 1].index : suite.endIndex
            let chunk = suite[boundary.index..<end]
            guard let name = chunk.components(separatedBy: "(").first, !name.isEmpty else { continue }
            if readsSourceDirectly(chunk) { names.append(name) }
        }
        return names
    }

    /// Every `@Test` in `source` whose suite is not itself gated but whose
    /// body reads the source tree — directly, or by calling a helper that
    /// does. `file` only labels the result.
    private static func ungatedTests(in source: String, file: String) -> [String] {
        var ungated: [String] = []

        // Suites are split at a line start, not anywhere the attribute name
        // appears — prose in a comment mentioning it must not be read as a
        // declaration. This check failed on its own documentation the first
        // time it ran.
        for rawSuite in source.components(separatedBy: "\n@Suite").dropFirst() {
            // `components(separatedBy:)` only cuts at the *next* `@Suite`, so
            // a suite's raw chunk runs past its own closing brace and into
            // the doc comment sitting above the following suite's `@Suite`
            // line. `SeriesPageSourceRuleTests`'s own doc comment names
            // `SourceTree.read` and `detail(_:)` in prose to explain why it
            // is gated — and that comment, still inside the *previous*
            // suite's raw chunk, was read as part of that suite's last test,
            // flagging an unrelated, source-blind test as ungated. The struct
            // closing brace always sits at column 0, so truncating there
            // drops everything written about the next suite before it is
            // ever looked at.
            let bodyEnd = rawSuite.range(of: "\n}")?.lowerBound ?? rawSuite.endIndex
            let suite = rawSuite[..<bodyEnd]
            let declaration = suite.components(separatedBy: "{").first ?? ""
            let suiteIsGated = declaration.contains("SourceTree.isAvailable")
            let helperNames = sourceReadingHelperNames(in: suite[...])

            for test in suite.components(separatedBy: "\n    @Test").dropFirst() {
                let readsSource = readsSourceDirectly(test[...])
                    || helperNames.contains { test.contains("\($0)(") }
                guard readsSource, !suiteIsGated else { continue }

                // The gate must sit in the test's own attribute, which ends
                // at the closing paren before `func`.
                let attribute = test.components(separatedBy: "func").first ?? ""
                if !attribute.contains("SourceTree.isAvailable") {
                    let name = test
                        .components(separatedBy: "func ").dropFirst().first?
                        .components(separatedBy: "(").first ?? "unknown"
                    ungated.append("\(file): \(name)")
                }
            }
        }
        return ungated
    }

    @Test("Every test that reads the source declares it needs the source")
    func allSourceReadingTestsAreGated() throws {
        let directory = "\(SourceTree.root)/MangaBakaTests"
        let files = try FileManager.default
            .contentsOfDirectory(atPath: directory)
            .filter { $0.hasSuffix(".swift") }

        var ungated: [String] = []
        for file in files {
            let source = try String(contentsOfFile: "\(directory)/\(file)", encoding: .utf8)
            ungated += Self.ungatedTests(in: source, file: file)
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

    /// The hole this guard actually had: a helper declared before the
    /// suite's first `@Test`, so its `SourceTree.read` fell into the piece
    /// `dropFirst()` discards. Built from `SeriesPageSourceRuleTests`'s real
    /// shape — a private `detail(_:)` wrapping `SourceTree.read`, called from
    /// a test whose own text never mentions `SourceTree`. The old rule (test
    /// text alone) reports this suite clean; asserting that here would have
    /// caught the hole before a real ungated suite did.
    @Test("A test that only calls a source-reading helper is not missed")
    func indirectReadThroughAHelperIsCaught() {
        // The leading comment line matters: `ungatedTests` splits on
        // `"\n@Suite"`, the same line-start rule the real guard uses so a
        // comment mentioning "@Suite" in prose is not read as a declaration
        // — a fixture whose very first character is `@Suite`, with nothing
        // before it, would silently match nothing at all.
        let fixture = """
        // A fixture suite.
        @Suite("Fixture with an indirected read")
        struct FixtureSuite {
            private func detail(_ file: String) throws -> String {
                try SourceTree.read("MangaBaka/Features/Detail/\\(file)")
            }

            @Test("reads through the helper")
            func readsThroughTheHelper() throws {
                let text = try detail("SeriesDetailView.swift")
                #expect(!text.isEmpty)
            }
        }
        """
        let ungated = Self.ungatedTests(in: fixture, file: "Fixture.swift")
        #expect(
            ungated == ["Fixture.swift: readsThroughTheHelper"],
            "The helper-indirected read was not detected: \(ungated)"
        )
    }
}
