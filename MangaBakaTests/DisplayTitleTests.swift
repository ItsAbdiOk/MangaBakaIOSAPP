import Foundation
import Testing
@testable import MangaBaka

/// Which of a series' titles gets shown.
///
/// Series 638 is the case that motivated all of this: it carries TWO titles
/// tagged `en`, one of them a romanisation that was mis-tagged, and the API
/// returns them alphabetically so the wrong one came first. Verified live on
/// 2026-09-10.
@Suite(.serialized)
struct DisplayTitleTests {
    private static func title(_ text: String, _ language: String, _ traits: [String] = []) -> SeriesTitle {
        SeriesTitle(language: language, traits: traits, title: text, isPrimary: true)
    }

    /// The real payload, in the order the API sends it.
    private static let series638 = [
        title("Baekjakga-ui Mangnani-ga Doeeotda", "en"),
        title("Lout of Count's Family", "en", ["official"]),
        title("백작가의 망나니가 되었다", "ko", ["native"]),
        title("Baekjakgaui Mangnaniga Doeeotda", "ko-Latn")
    ]

    @Test("An official English title beats a romanisation mis-tagged as English")
    func officialWinsWithinALanguage() {
        // Fails without the official-first sort: returns the romanisation,
        // because it sorts first alphabetically and arrives first.
        #expect(
            DisplayTitle.choose(from: Self.series638, preferredLanguages: ["en"], preference: .english)
                == "Lout of Count's Family"
        )
    }

    @Test("Each preference picks its own form")
    func eachPreference() {
        #expect(
            DisplayTitle.choose(from: Self.series638, preferredLanguages: ["en"], preference: .romanised)
                == "Baekjakgaui Mangnaniga Doeeotda"
        )
        #expect(
            DisplayTitle.choose(from: Self.series638, preferredLanguages: ["en"], preference: .original)
                == "백작가의 망나니가 되었다"
        )
    }

    @Test("An English preference is not overridden by the device's language")
    func choiceBeatsLocale() {
        let titles = [
            Self.title("Le Vaurien", "fr"),
            Self.title("Lout of Count's Family", "en", ["official"])
        ]
        #expect(
            DisplayTitle.choose(from: titles, preferredLanguages: ["fr"], preference: .english)
                == "Lout of Count's Family"
        )
    }

    @Test("An untagged native-script title still satisfies the original preference")
    func originalFindsUntaggedNativeScript() {
        // Most series carry no "native" trait at all: the origin-language
        // title is simply tagged `ja` or `ko` with no traits. Requiring the
        // trait meant the app quietly answered an "original language" request
        // with English — the reader's setting silently doing nothing.
        let titles = [
            Self.title("Frieren: Beyond Journey's End", "en", ["official"]),
            Self.title("Sousou no Frieren", "ja-Latn"),
            Self.title("葬送のフリーレン", "ja")
        ]
        #expect(
            DisplayTitle.choose(from: titles, preferredLanguages: ["en"], preference: .original)
                == "葬送のフリーレン"
        )
    }

    @Test("A romanisation is not mistaken for the original")
    func originalIgnoresRomanisations() {
        // "-Latn" is a reading of the original, not the original. A series
        // with only a romanisation and an English title cannot satisfy the
        // preference, and should fall through rather than pick the Latin one.
        let titles = [
            Self.title("Frieren: Beyond Journey's End", "en", ["official"]),
            Self.title("Sousou no Frieren", "ja-Latn")
        ]
        #expect(
            DisplayTitle.choose(from: titles, preferredLanguages: ["en"], preference: .original)
                == "Frieren: Beyond Journey's End"
        )
    }

    @Test("A preference the series cannot satisfy falls through rather than showing nothing")
    func fallsThrough() {
        let englishOnly = [Self.title("Lout of Count's Family", "en", ["official"])]
        for preference in TitlePreference.allCases {
            #expect(
                DisplayTitle.choose(
                    from: englishOnly, preferredLanguages: ["en"], preference: preference
                ) != nil
            )
        }
    }

    @Test("No titles at all is nil, not a crash")
    func noTitles() {
        #expect(DisplayTitle.choose(from: nil) == nil)
        #expect(DisplayTitle.choose(from: []) == nil)
    }

    @Test("The stored preference round-trips, and defaults to English")
    func settingsRoundTrip() throws {
        // A throwaway suite, not the app's own defaults: the first version of
        // this test wrote .original into the real store, and the simulator
        // then launched with the Korean title selected.
        let scratch = try #require(UserDefaults(suiteName: "titles.tests"))
        // What the app itself holds, which this test must leave exactly as it
        // found it — the reader may well have chosen something.
        let appValue = UserDefaults.standard.string(forKey: "titles.preference")
        TitleSettings.resetForTesting(store: scratch)
        defer { TitleSettings.resetForTesting() }

        #expect(TitleSettings.preference == .english)
        TitleSettings.set(.original)
        #expect(TitleSettings.preference == .original)
        #expect(UserDefaults.standard.string(forKey: "titles.preference") == appValue)
    }
}
