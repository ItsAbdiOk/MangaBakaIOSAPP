import Foundation
import Testing
@testable import MangaBaka

/// Asserts the download offer stays where the crash fix requires it: never
/// inside `CharacterProfileView`'s sheet, always from `TranslationSection` in
/// Settings, and both screens naming the same language pair.
///
/// Gated on `SourceTree.isAvailable` — these read the repository's own
/// source, which only exists on a developer's Mac (see `SourceTree`).
@Suite("Where the translation download is offered", .enabled(if: SourceTree.isAvailable))
struct TranslationOfferTests {
    private static let profilePath = "MangaBaka/Features/Detail/CharacterProfileView.swift"
    private static let sectionPath = "MangaBaka/Features/Settings/TranslationSection.swift"
    private static let settingsPath = "MangaBaka/Features/Settings/SettingsView.swift"

    /// The crash: `prepareTranslation()` (directly or via `.translationTask`
    /// running it) raises the system's download prompt, and this view is
    /// itself presented in a `.sheet`. Removing this test's fix from
    /// `CharacterProfileView` would let this line pass again while
    /// reintroducing TestFlight build 64's crash.
    @Test("The character profile never asks for a translation download")
    func profileNeverPreparesTranslation() throws {
        let source = try SourceTree.read(Self.profilePath)
        #expect(!source.contains("prepareTranslation"))
        // `.translationTask` itself stays: it is how the profile translates at
        // all. What must not come back is the gate letting `.supported`
        // through — that is the state whose session raises the download UI.
        #expect(source.contains("TranslationGate.allows("))
    }

    /// The fix's other half: somewhere safe has to actually offer the
    /// download, or a reader without the pack is stuck forever. If
    /// `TranslationSection` is removed (or gutted) this fails, because
    /// nothing else in the app calls `prepareTranslation()`.
    @Test("TranslationSection offers the download")
    func sectionPreparesTranslation() throws {
        let source = try SourceTree.read(Self.sectionPath)
        #expect(source.contains("prepareTranslation"))
    }

    /// The two screens translate the same pair only because they read it
    /// from `TranslationGate`. A private `Locale.Language(identifier: "ru")`
    /// literal reintroduced in either file is exactly how they would drift.
    @Test("Both screens use the shared language pair, not their own literal")
    func sharedLanguageConstants() throws {
        for path in [Self.profilePath, Self.sectionPath] {
            let source = try SourceTree.read(path)
            #expect(source.contains("TranslationGate.sourceLanguage"))
            #expect(source.contains("TranslationGate.targetLanguage"))
            #expect(!source.contains(#"Locale.Language(identifier: "ru")"#))
            #expect(!source.contains(#"Locale.Language(languageCode: "ru")"#))
        }
    }

    /// If `TranslationSection()` is removed from `SettingsView`, this is the
    /// assertion that fails: the section would compile fine on its own but
    /// never appear anywhere a reader can reach it.
    @Test("SettingsView wires TranslationSection in")
    func settingsWiresSection() throws {
        let source = try SourceTree.read(Self.settingsPath)
        #expect(source.contains("TranslationSection("))
    }
}

/// Pure mapping tested without touching the Translation framework's own
/// async status call.
@Suite("Translation status labels")
struct TranslationSectionLabelTests {
    @Test("Installed reads as installed, with the pair named")
    func installed() {
        #expect(TranslationSection.label(for: .installed) == "Russian → English: installed")
    }

    @Test("Supported reads as an offer to download")
    func supported() {
        #expect(TranslationSection.label(for: .supported) == "Download Russian → English")
    }

    @Test("Unsupported says the device cannot do this")
    func unsupported() {
        #expect(TranslationSection.label(for: .unsupported) == "Not available on this device")
    }
}
