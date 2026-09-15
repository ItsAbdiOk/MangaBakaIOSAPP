import Testing
@testable import MangaBaka

/// One assertion per fix from the 2026-09-15 accessibility audit triage
/// (`docs/reviews/night/accessibility.md`), each pinned to the failure it
/// would have produced before the fix landed.
///
/// Source-text checks, gated on `SourceTree.isAvailable`, because none of
/// these three fixes is behind a pure function: they are a colour token, a
/// modifier call, and a frame change on a view body Swift Testing cannot
/// drive without ViewInspector.
@Suite("Accessibility audit fixes, 2026-09-15")
struct AccessibilityFixesTests {
    @Test(
        "Stack's empty-saved-strip caption reads at Palette.textMuted, not textTertiary",
        .enabled(if: SourceTree.isAvailable)
    )
    func stackEmptyCaptionUsesTextMuted() throws {
        let source = try SourceTree.read("MangaBaka/Features/Stack/StackSections.swift")
        // Before the fix this string was `.foregroundStyle(Palette.textTertiary)`,
        // which measures 3.96:1 on `Palette.ground` — below the 4.5:1 AA floor
        // for running text (`Palette.swift`'s own comment on `textTertiary`:
        // "Marks and inactive controls, not running text"). The audit's
        // "Contrast failed" on this sentence was correct.
        #expect(SourceTree.containsRun(
            source,
            """
            Text("Nothing saved yet. Skips are remembered too, and stay recoverable in the shelf.")
                .typeInstruction()
                .foregroundStyle(Palette.textMuted)
            """
        ), "the empty-stack caption should use textMuted (4.66:1), not textTertiary (3.96:1)")
    }

    @Test(
        "Stack's \"Open the shelf\" link carries a real tap target",
        .enabled(if: SourceTree.isAvailable)
    )
    func shelfLinkHasTapTarget() throws {
        let source = try SourceTree.read("MangaBaka/Features/Stack/StackSections.swift")
        // Before the fix, "Shelf ›" was a bare Text in a Button with no frame
        // or tapTarget() of its own — Apple's audit measured its hit region
        // at 40x15, well under the 44x44 minimum (`Metrics.tapTarget`).
        #expect(SourceTree.containsRun(
            source,
            #"Text("Shelf ›")"#
        ), "expected the shelf link's own Text to still be there")
        #expect(source.contains(".tapTarget()"),
            "the shelf link should call .tapTarget() so its hit region reaches 44pt")
    }

    @Test(
        "The library search field's TextField stretches to the row's height",
        .enabled(if: SourceTree.isAvailable)
    )
    func inlineSearchFieldTextFieldFillsRow() throws {
        let source = try SourceTree.read("MangaBaka/Features/Shared/InlineSearchField.swift")
        // Before the fix the TextField had no height modifier of its own, so
        // inside the row's HStack it claimed only its intrinsic text height
        // (19-22pt per the audit's frames) rather than the row's 44pt —
        // reported as both "Hit area is too small" and, at larger Dynamic
        // Type sizes where glyphs exceed that unstretched frame, "Text
        // clipped". `.frame(maxHeight: .infinity)` makes the field's own
        // frame match the row instead of sitting centred inside it.
        #expect(SourceTree.containsRun(
            source,
            #"TextField(prompt, text: $text)"#
        ), "expected the row's own TextField declaration")
        #expect(source.contains(".frame(maxHeight: .infinity)"),
            "the TextField should stretch to fill the row height, not just its intrinsic text height")
    }
}
