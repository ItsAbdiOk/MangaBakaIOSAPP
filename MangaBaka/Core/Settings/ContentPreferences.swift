import Foundation

/// What the reader is willing to see.
///
/// The product decision is safe and suggestive by default, with erotica behind
/// a deliberate opt-in. Filtering happens server-side on every request, so
/// excluded covers are never downloaded, never cached, and never briefly
/// visible while a client-side filter catches up.
///
/// The API's `pornographic` rating is deliberately not offered. App Review
/// guideline 1.1.4 bans overtly sexual material, and a default-off switch is no
/// defence — a reviewer who can turn it on is a reviewer who sees it, and the
/// penalty there is removal rather than a resubmittable rejection. Erotica —
/// "sex, not explicit" — is the line Apple actually draws, and the app is rated
/// for adults on that basis. Abdi's call, 2026-09-12. See `apiRatings` for why
/// the value still has to be named somewhere.
struct ContentPreferences: Sendable, Equatable {
    /// What the reader can choose between, in increasing explicitness.
    enum Rating: String, CaseIterable, Sendable {
        case safe
        case suggestive
        case erotica

        var title: String {
            switch self {
            case .safe: "Safe"
            case .suggestive: "Suggestive"
            case .erotica: "Erotica"
            }
        }

        /// What the rating actually covers, in the reader's terms rather than
        /// the API's. "Suggestive" alone means nothing to someone deciding
        /// whether to switch it on.
        var caption: String {
            switch self {
            case .safe: "The baseline everyone sees"
            case .suggestive: "Fan service, innuendo"
            case .erotica: "Sex, not explicit"
            }
        }

        /// Whether turning this on is a deliberate act rather than a preference.
        var requiresOptIn: Bool {
            switch self {
            case .safe, .suggestive: false
            case .erotica: true
            }
        }
    }

    /// Every value the API's `content_rating` can take, including the one this
    /// app does not offer.
    ///
    /// Requests are built from `Rating`, which is an allowlist — so dropping
    /// `pornographic` from the enum already keeps those series out. This exists
    /// for the inverse question, "what has the reader *not* opted into", which
    /// `LibraryService.hiddenTagIDs` asks to keep explicit tag names out of the
    /// recommender's captions. Derived from `Rating` it would silently stop
    /// counting pornographic tags the moment the case was removed, and those
    /// names would reappear in captions with nothing to show they had.
    static let apiRatings = ["safe", "suggestive", "erotica", "pornographic"]

    /// Defaults chosen once, in the spec: the website's ordinary range, without
    /// making a first run explicit.
    static let `default` = ContentPreferences(allowed: [.safe, .suggestive])

    var allowed: Set<Rating>

    /// Sent as repeated query keys. A comma-joined value is rejected by the API
    /// with HTTP 400, which once broke every feed in the app.
    var queryValues: [String] {
        Rating.allCases.filter(allowed.contains).map(\.rawValue)
    }

    /// Safe can never be switched off. A reader who turned everything off would
    /// see an empty app and no explanation for it.
    mutating func setAllowed(_ rating: Rating, _ isAllowed: Bool) {
        if isAllowed {
            allowed.insert(rating)
        } else if rating != .safe {
            allowed.remove(rating)
        }
    }

    var includesAdultContent: Bool {
        allowed.contains { $0.requiresOptIn }
    }
}

/// Persists the reader's choice, and tells anyone who cares that it changed.
///
/// The change notification is the part that is easy to miss: a cached feed was
/// fetched under the previous filter, so leaving it in place would keep showing
/// content the reader has just excluded.
@MainActor
@Observable
final class ContentPreferencesStore {
    private static let key = "content.allowedRatings"

    private(set) var preferences: ContentPreferences
    private let defaults: UserDefaults

    /// Called with the new query values whenever the choice changes. Set by
    /// whoever owns the cache; the store itself knows nothing about caching.
    var onChange: (@Sendable ([String]) async -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let stored = defaults.array(forKey: Self.key) as? [String] {
            // A stored "pornographic" from before that option was removed
            // decodes to nil and is dropped here, which is the migration: the
            // reader silently returns to whatever else they had allowed.
            let ratings = stored.compactMap(ContentPreferences.Rating.init(rawValue:))
            // Safe is always present, even if a corrupt or hand-edited value
            // omitted it.
            preferences = ContentPreferences(allowed: Set(ratings).union([.safe]))
        } else {
            preferences = .default
        }
    }

    func set(_ rating: ContentPreferences.Rating, allowed: Bool) async {
        var updated = preferences
        updated.setAllowed(rating, allowed)
        guard updated != preferences else { return }

        preferences = updated
        defaults.set(updated.queryValues, forKey: Self.key)
        await onChange?(updated.queryValues)
    }
}
