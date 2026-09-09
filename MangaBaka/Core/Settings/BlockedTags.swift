import Foundation

/// Tags the reader never wants to see, whatever a series is rated.
///
/// The content-rating filter works at the level of a whole series. This works
/// at the level of a theme, which is the only way to say "not that specifically"
/// — and it is the control that would have kept a particular tag out of a
/// recommendation's explanation without hiding whole series.
///
/// Sent to the API as `blocked_tag`, verified against the live endpoint on
/// 2026-09-09: blocking the strongest strand of a blend changed 12 of 20
/// results and removed the tag from the returned DNA.
struct BlockedTags: Equatable, Sendable {
    /// Tag ids, with the names kept alongside so a list of blocks can be shown
    /// and undone without another request.
    private(set) var tags: [Blocked]

    struct Blocked: Identifiable, Equatable, Sendable, Codable {
        let id: Int
        let name: String
    }

    static let none = BlockedTags(tags: [])

    var isEmpty: Bool { tags.isEmpty }
    var ids: [Int] { tags.map(\.id) }

    func contains(_ id: Int) -> Bool { tags.contains { $0.id == id } }

    mutating func toggle(id: Int, name: String) {
        if contains(id) {
            tags.removeAll { $0.id == id }
        } else {
            tags.append(Blocked(id: id, name: name))
        }
    }

    /// "Nothing blocked", or the names, so the reader can see what they have
    /// hidden from themselves. A count alone would leave them unable to work
    /// out why something is missing.
    var summary: String {
        guard !tags.isEmpty else { return "Nothing blocked" }
        return tags.map(\.name).joined(separator: ", ")
    }
}

/// Persists the blocked list and tells the cache owner when it changes.
@MainActor
@Observable
final class BlockedTagsStore {
    private static let key = "content.blockedTags"

    private(set) var blocked: BlockedTags
    private let defaults: UserDefaults

    /// Called with the ids whenever the list changes. Cached feeds were fetched
    /// without the block, so keeping them would keep showing what the reader
    /// has just hidden.
    var onChange: (@Sendable ([Int]) async -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key),
           let stored = try? JSONDecoder().decode([BlockedTags.Blocked].self, from: data) {
            blocked = BlockedTags(tags: stored)
        } else {
            blocked = .none
        }
    }

    func toggle(id: Int, name: String) async {
        var updated = blocked
        updated.toggle(id: id, name: name)
        guard updated != blocked else { return }

        blocked = updated
        if let data = try? JSONEncoder().encode(updated.tags) {
            defaults.set(data, forKey: Self.key)
        }
        await onChange?(updated.ids)
    }
}
