import Foundation

/// Which of a series' titles to show.
///
/// A series carries a dozen or more — official English, several fan
/// translations, a romanisation, the original script. There is no right answer
/// for everyone, so this is a choice, and English is the default because it is
/// the language the app is written in.
enum TitlePreference: String, CaseIterable, Sendable {
    /// The official English title where there is one.
    case english
    /// The romanised original: "Baekjakgaui Mangnaniga Doeeotda".
    case romanised
    /// The original script: "백작가의 망나니가 되었다".
    case original

    var title: String {
        switch self {
        case .english: "English"
        case .romanised: "Romanised"
        case .original: "Original language"
        }
    }

    var caption: String {
        switch self {
        case .english: "Lout of Count's Family"
        case .romanised: "Baekjakgaui Mangnaniga Doeeotda"
        case .original: "백작가의 망나니가 되었다"
        }
    }
}

/// Where the choice lives.
///
/// Read from hundreds of places — every row, every card, every sort — and
/// changed roughly never, so it is held here rather than threaded through every
/// call site. `Series.displayTitle` reads it.
///
/// Not an actor and not main-isolated, because titles are read while sorting a
/// thousand library entries off the main thread. A lock around a single enum is
/// the cheapest correct thing.
enum TitleSettings {
    private static let key = "titles.preference"
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: TitlePreference?
    /// Where the choice is written. Injectable for one reason: a test that
    /// called `set` wrote into the app's own defaults, and the simulator then
    /// launched showing the original script as the default. A test must not be
    /// able to change what the app does on the next launch.
    nonisolated(unsafe) private static var store: UserDefaults = .standard

    static var preference: TitlePreference {
        lock.lock(); defer { lock.unlock() }
        if let cached { return cached }
        let stored = store.string(forKey: key)
            .flatMap(TitlePreference.init(rawValue:)) ?? .english
        cached = stored
        return stored
    }

    static func set(_ preference: TitlePreference) {
        lock.lock()
        cached = preference
        lock.unlock()
        store.set(preference.rawValue, forKey: key)
    }

    /// For tests, which must not inherit whatever the last one set — nor
    /// leave anything behind for the app to inherit.
    static func resetForTesting(_ preference: TitlePreference? = nil, store: UserDefaults = .standard) {
        lock.lock()
        cached = preference
        Self.store = store
        lock.unlock()
        if store !== UserDefaults.standard { store.removeObject(forKey: key) }
    }
}
