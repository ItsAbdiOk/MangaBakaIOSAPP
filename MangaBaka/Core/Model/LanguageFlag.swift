import Foundation

/// A flag for a language tag, as the app labels titles and links.
///
/// Languages are not countries, so every entry here is a judgement: the flag
/// most readers associate with the language, not a claim about where it is
/// spoken. A region in the tag wins when it names one ("pt-br" → 🇧🇷,
/// "zh-hk" → 🇭🇰); a script suffix ("ko-latn") is ignored; a region that is
/// not a country ("es-la", Latin America) falls back to the language's flag.
/// Unknown tags get no flag rather than a wrong one.
enum LanguageFlag {
    /// "Korean", "Korean (Latin)", "Portuguese (Brazil)" — the language's
    /// name in the reader's own language, from the system, which knows every
    /// tag this app will ever see. Falls back to the code upper-cased for a
    /// tag the system does not recognise, so nothing is ever blank.
    static func name(for tag: String) -> String {
        let parts = tag.lowercased().split(separator: "-").map(String.init)
        guard let language = parts.first,
              let base = Locale.current.localizedString(forLanguageCode: language)
        else { return tag.uppercased() }
        guard parts.count > 1 else { return base }
        let qualifier = parts[1].count == 2
            ? Locale.current.localizedString(forRegionCode: parts[1])
            : Locale.current.localizedString(forScriptCode: parts[1])
        guard let qualifier else { return base }
        return "\(base) (\(qualifier))"
    }

    static func emoji(for tag: String) -> String? {
        let parts = tag.lowercased().split(separator: "-").map(String.init)
        guard let language = parts.first else { return nil }
        if parts.count > 1, parts[1].count == 2, let region = flag(forRegion: parts[1]) {
            return region
        }
        return byLanguage[language]
    }

    private static func flag(forRegion code: String) -> String? {
        // A two-letter region becomes its regional-indicator pair. Only
        // regions this app has seen in the data are allowed through, so a
        // script or an invented code cannot produce a flag for nowhere.
        guard knownRegions.contains(code) else { return nil }
        let scalars = code.unicodeScalars.compactMap { UnicodeScalar(0x1F1E6 + $0.value - 97) }
        return String(String.UnicodeScalarView(scalars))
    }

    /// Regions seen on MangaBaka titles and links, 2026-09-11.
    private static let knownRegions: Set<String> = [
        "br", "pt", "hk", "tw", "cn", "us", "gb", "mx", "ar", "ca", "au", "in", "id", "my", "sg"
    ]

    private static let byLanguage: [String: String] = [
        "en": "🇬🇧", "ja": "🇯🇵", "ko": "🇰🇷", "zh": "🇨🇳", "fr": "🇫🇷", "de": "🇩🇪",
        "es": "🇪🇸", "pt": "🇵🇹", "it": "🇮🇹", "ru": "🇷🇺", "pl": "🇵🇱", "vi": "🇻🇳",
        "th": "🇹🇭", "id": "🇮🇩", "tr": "🇹🇷", "ar": "🇸🇦", "nl": "🇳🇱", "sv": "🇸🇪",
        "no": "🇳🇴", "da": "🇩🇰", "fi": "🇫🇮", "cs": "🇨🇿", "hu": "🇭🇺", "ro": "🇷🇴",
        "uk": "🇺🇦", "el": "🇬🇷", "he": "🇮🇱", "hi": "🇮🇳", "ms": "🇲🇾", "tl": "🇵🇭",
        "bg": "🇧🇬", "hr": "🇭🇷", "sk": "🇸🇰", "sl": "🇸🇮", "lt": "🇱🇹", "lv": "🇱🇻",
        "et": "🇪🇪", "fa": "🇮🇷", "bn": "🇧🇩", "ca": "🇪🇸", "sr": "🇷🇸", "mn": "🇲🇳",
        // Seen on ONE PIECE's titles on the simulator: Kazakh and Belarusian
        // had codes and no flags.
        "kk": "🇰🇿", "be": "🇧🇾", "az": "🇦🇿", "ka": "🇬🇪", "uz": "🇺🇿", "ur": "🇵🇰",
        "ta": "🇮🇳", "te": "🇮🇳", "ml": "🇮🇳", "ne": "🇳🇵", "si": "🇱🇰", "my": "🇲🇲",
        "km": "🇰🇭", "lo": "🇱🇦", "is": "🇮🇸", "ga": "🇮🇪", "af": "🇿🇦", "sw": "🇰🇪",
        "mk": "🇲🇰", "sq": "🇦🇱", "bs": "🇧🇦", "eu": "🇪🇸", "gl": "🇪🇸"
    ]
}
