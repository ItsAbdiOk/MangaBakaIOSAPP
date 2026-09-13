import Testing
@testable import MangaBaka

/// The 2026-09-13 sweep of fixed sizes left outside Search, Library and the
/// files other lanes owned that day. Same shape as `DynamicTypeLeftoversTests`:
/// assert the form of the fix in source, since a fixed-point font cannot be
/// caught by rendering at one text size.
///
/// On HEAD `bed996d` the font check fails on 28 of these 29 files, 37 lines in
/// all (`MixView` is here for its button height alone), and the height check
/// on 10 files, 15 lines.
@Suite("Dynamic Type residuals", .enabled(if: SourceTree.isAvailable))
struct DynamicTypeResidualTests {
    private static let sweptFiles = [
        "MangaBaka/Features/Browse/BrowseView.swift",
        "MangaBaka/Features/Detail/AlternativeTitles.swift",
        "MangaBaka/Features/Detail/CharacterProfileView.swift",
        "MangaBaka/Features/Detail/CoverGallery.swift",
        "MangaBaka/Features/Detail/DetailScheduleBlock.swift",
        "MangaBaka/Features/Detail/DetailTagSections.swift",
        "MangaBaka/Features/Detail/LibraryControl.swift",
        "MangaBaka/Features/Detail/LinksSection.swift",
        "MangaBaka/Features/Detail/PublisherView.swift",
        "MangaBaka/Features/Detail/ReadRow.swift",
        "MangaBaka/Features/Mix/BlendDNAView.swift",
        "MangaBaka/Features/Mix/MixFilterStrip.swift",
        "MangaBaka/Features/Mix/MixView.swift",
        "MangaBaka/Features/Mix/SeedPickerSheet.swift",
        "MangaBaka/Features/Onboarding/OnboardingView.swift",
        "MangaBaka/Features/Schedule/AnnouncedSection.swift",
        "MangaBaka/Features/Schedule/ScheduleView.swift",
        "MangaBaka/Features/Settings/AccountCard.swift",
        "MangaBaka/Features/Settings/AttributionSection.swift",
        "MangaBaka/Features/Settings/BlockedTagsSection.swift",
        "MangaBaka/Features/Settings/HistorySection.swift",
        "MangaBaka/Features/Settings/SettingsRow.swift",
        "MangaBaka/Features/Settings/TitleSection.swift",
        "MangaBaka/Features/Shared/InlineFailure.swift",
        "MangaBaka/Features/Shared/SearchClearButton.swift",
        "MangaBaka/Features/Shared/StateAction.swift",
        "MangaBaka/Features/Stack/StackResetMenu.swift",
        "MangaBaka/Features/Stack/StackSections.swift",
        "MangaBaka/Features/Stack/StackView.swift"
    ]

    /// The named heights the swept files put around a line of text. A
    /// hairline's `frame(height: 0.5)` or a dot's `8x8` is not text and is
    /// left alone; these are the button, field and pill heights that were
    /// clipping their labels past the default text size.
    private static let textHeights = [
        "Metrics.ctaPrimary", "Metrics.ctaSecondary", "Metrics.headerPill",
        "Metrics.field", "Metrics.actionDetails", "max(Metrics.field, Metrics.tapTarget)"
    ]

    /// Every glyph beside a scaled label, and the two real `Text`s in
    /// `LibraryControl`, go through `Typography` so they grow with the label.
    @Test("No fixed-point fonts remain in the swept files")
    func noFixedPointFonts() throws {
        for path in Self.sweptFiles {
            let text = try SourceTree.read(path)
            #expect(
                !text.contains(".font(.system(size:"),
                "\(path) has a fixed-point font that will not scale"
            )
        }
    }

    /// `minHeight`, never `height`, around text: the box is the same size at
    /// the default text size and grows past it instead of clipping.
    @Test("No fixed heights around text remain in the swept files")
    func noFixedTextHeights() throws {
        for path in Self.sweptFiles {
            let text = try SourceTree.read(path)
            for height in Self.textHeights {
                #expect(
                    !text.contains(".frame(height: \(height))"),
                    "\(path) fixes a text container at \(height); use minHeight"
                )
            }
        }
    }
}
