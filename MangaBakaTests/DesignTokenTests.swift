import Foundation
import Testing
@testable import MangaBaka

/// A design token defined and never used means a piece of the mockup was
/// measured and then not built. That is how the whole Liquid Glass layer once
/// sat in the source applied to nothing, and how a density "setting" stayed on
/// the backlog for weeks before turning out to be a knob in the mockup's own
/// editor panel rather than a feature.
///
/// This is the audit from `design/briefs/fidelity-checklist.md`, run as a test
/// so the count cannot drift upward unnoticed.
@Suite("Design tokens are used or deliberately not", .enabled(if: SourceTree.isAvailable))
struct DesignTokenTests {
    /// The three that survive, each for a stated reason. Anything else unused
    /// is either unbuilt mockup or dead code, and both want finding.
    private static let deliberatelyUnused: Set<String> = [
        // The mockup draws a fake iOS status bar. The real one is drawn by iOS.
        "Metrics.gutterStatus",
        // The mockup has a custom 38pt circular back button. The system
        // navigation bar's own control is used instead: it handles the
        // edge-swipe gesture and VoiceOver for free.
        "Metrics.backButton"
    ]

    private func tokens(in file: String) throws -> [String] {
        let source = try SourceTree.read("MangaBaka/DesignSystem/\(file).swift")
        return source
            .split(separator: "\n")
            .compactMap { line -> String? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                for prefix in ["static let ", "static func "] where trimmed.hasPrefix(prefix) {
                    let rest = trimmed.dropFirst(prefix.count)
                    let name = rest.prefix { $0.isLetter || $0.isNumber }
                    return name.isEmpty ? nil : String(name)
                }
                return nil
            }
    }

    @Test("Every token is used somewhere, or listed here with its reason",
          arguments: ["Metrics", "Palette"])
    func noOrphans(_ file: String) throws {
        let sources = try SourceTree.swiftFiles(under: "MangaBaka")
            .map { try SourceTree.read($0) }
            .joined(separator: "\n")

        let tokens = try tokens(in: file)
        #expect(!tokens.isEmpty, "No tokens parsed from \(file): the loop below would pass on nothing")
        for token in tokens {
            let qualified = "\(file).\(token)"
            guard !Self.deliberatelyUnused.contains(qualified) else { continue }
            #expect(
                sources.contains(qualified),
                """
                \(qualified) is defined and never used. Build it, delete it, \
                or add it to deliberatelyUnused with the reason.
                """
            )
        }
    }
}
