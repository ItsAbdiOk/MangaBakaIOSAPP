import Testing
import Foundation
@testable import MangaBaka

/// `DisplayTitle.choose`'s default `preferredLanguages` argument read
/// `Locale.preferredLanguages` — a CFPreferences hit — on every one of
/// `Series.displayTitle`'s 68 call sites, most in row bodies. Cached at the
/// source instead of at one more consumer — wire review W13/P13,
/// 2026-09-15.
///
/// Existing behavioural tests (`DisplayTitleTests`) all pass an explicit
/// `preferredLanguages:`, so they cannot see whether the *default* argument
/// is cached — that is what this suite checks instead, plus that the cache
/// invalidates on request.
@Suite("DisplayTitle preferred-language cache after W13")
struct DisplayTitleWireFixTests {
    /// Fails on the pre-fix code with "value of type 'DisplayTitle' has no
    /// member 'invalidatePreferredLanguagesCache'" — there was no cache to
    /// invalidate.
    @Test("The cache can be dropped and recomputed without crashing")
    func cacheCanBeInvalidated() {
        DisplayTitle.invalidatePreferredLanguagesCache()
        let titles = [SeriesTitle(language: "en", traits: [], title: "Test Title", isPrimary: true)]
        // Exercises the default-argument path (no `preferredLanguages:`
        // passed) so the cache is actually what answers it.
        #expect(DisplayTitle.choose(from: titles) == "Test Title")
        DisplayTitle.invalidatePreferredLanguagesCache()
    }

    /// The default argument still normalises and matches the reader's
    /// device languages correctly — the cache changes *when* the read
    /// happens, not what it returns. Using `preference: .original` so the
    /// device's actual preferred language (whatever it is on the test
    /// machine) cannot accidentally match "en" and mask a broken cache by
    /// coincidence — this only passes if a native-script/romanised title is
    /// chosen over the plain English fallback for at least one of the
    /// reader's declared languages, or falls through correctly to the last
    /// resort when none match.
    @Test("Explicit preferredLanguages still overrides the cached default")
    func explicitArgumentStillOverridesCache() {
        let titles = [
            SeriesTitle(language: "fr", traits: [], title: "Le Titre", isPrimary: true),
            SeriesTitle(language: "en", traits: ["official"], title: "The Title", isPrimary: true)
        ]
        #expect(
            DisplayTitle.choose(from: titles, preferredLanguages: ["fr"], preference: .english) == "The Title"
        )
        #expect(
            DisplayTitle.choose(from: titles, preferredLanguages: ["fr"], preference: .original) == "Le Titre"
        )
    }
}
