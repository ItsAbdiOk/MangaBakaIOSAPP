import Foundation

/// Which formats the reader wants to see.
///
/// MangaBaka indexes prose novels alongside comics, and the discovery
/// endpoints return them mixed together. Someone who came here for manga does
/// not want a light novel in a swipe stack, and the API takes a `type`
/// parameter on every surface this app uses — so this is a server-side filter
/// like the content rating, not a client-side sieve applied after the covers
/// have already been downloaded.
struct FormatPreferences: Sendable, Equatable {
    /// The API's six values for `type`, verbatim.
    enum Format: String, CaseIterable, Sendable {
        case manga
        case manhwa
        case manhua
        case novel
        case oel
        case other

        var title: String {
            switch self {
            case .manga: "Manga"
            case .manhwa: "Manhwa"
            case .manhua: "Manhua"
            case .novel: "Novels"
            case .oel: "OEL"
            case .other: "Other"
            }
        }

        var subtitle: String {
            switch self {
            // The reading direction is the part that actually changes the
            // experience, and it is the part a reader new to the categories
            // does not know. "Korean" alone teaches nobody anything.
            case .manga: "Japanese, right to left"
            case .manhwa: "Korean, usually vertical"
            case .manhua: "Chinese"
            case .novel: "Prose, including light novels"
            case .oel: "Originally in English"
            case .other: "Everything not covered above"
            }
        }
    }

    /// Everything, so a first run shows the catalogue as it is rather than a
    /// narrowed version of it the reader never asked for.
    static let `default` = FormatPreferences(allowed: Set(Format.allCases))

    var allowed: Set<Format>

    /// Empty when everything is allowed.
    ///
    /// Sending all six values means the same as sending none, and none is one
    /// fewer parameter to get wrong on an API that is inconsistent about how
    /// repeated keys are encoded.
    var queryValues: [String] {
        guard allowed.count < Format.allCases.count else { return [] }
        return Format.allCases.filter(allowed.contains).map(\.rawValue)
    }

    var isFiltering: Bool { !queryValues.isEmpty }

    /// The last format cannot be switched off. Turning everything off would
    /// produce an empty app with no visible cause, the same trap the content
    /// rating avoids by pinning "safe" on.
    mutating func setAllowed(_ format: Format, _ isAllowed: Bool) {
        if isAllowed {
            allowed.insert(format)
        } else if allowed.count > 1 {
            allowed.remove(format)
        }
    }

}

/// Persists the format choice and tells the cache owner when it changes.
///
/// The invalidation matters for the same reason it does for content ratings: a
/// cached feed was fetched under the old filter, so keeping it would keep
/// showing the formats the reader has just excluded.
@MainActor
@Observable
final class FormatPreferencesStore {
    private static let key = "content.allowedFormats"

    private(set) var preferences: FormatPreferences
    private let defaults: UserDefaults

    var onChange: (@Sendable ([String]) async -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let stored = defaults.array(forKey: Self.key) as? [String] {
            let formats = Set(stored.compactMap(FormatPreferences.Format.init(rawValue:)))
            // A stored value that maps to nothing (a renamed case, a
            // hand-edited plist) falls back to everything rather than to an
            // empty app.
            preferences = formats.isEmpty
                ? .default
                : FormatPreferences(allowed: formats)
        } else {
            preferences = .default
        }
    }

    func set(_ format: FormatPreferences.Format, allowed: Bool) async {
        var updated = preferences
        updated.setAllowed(format, allowed)
        guard updated != preferences else { return }

        preferences = updated
        // Stored as the full allowed set, not as queryValues: queryValues is
        // deliberately empty when everything is on, and persisting that would
        // be indistinguishable from "nothing is on".
        defaults.set(
            FormatPreferences.Format.allCases
                .filter(updated.allowed.contains)
                .map(\.rawValue),
            forKey: Self.key
        )
        await onChange?(updated.queryValues)
    }
}
