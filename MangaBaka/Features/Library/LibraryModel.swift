import Foundation

/// The reader's own library, grouped into shelves.
@MainActor
@Observable
final class LibraryModel {
    /// One state's worth of the library.
    struct Shelf: Identifiable, Equatable, Hashable {
        let state: LibraryEntry.State
        let entries: [LibraryEntry]
        /// A line saying what this shelf actually is, built from its contents.
        let note: String

        var id: String { state.rawValue }

        static func == (lhs: Shelf, rhs: Shelf) -> Bool { lhs.id == rhs.id }
        func hash(into hasher: inout Hasher) { hasher.combine(id) }
        var label: String { state.title }
        var count: Int { entries.count }
        /// The first few covers, for the card's strip.
        var covers: [Series] { entries.prefix(5).compactMap(\.series) }
    }

    private(set) var entries: [LibraryEntry] = []
    private(set) var shelves: [Shelf] = []
    /// Filters every shelf. Local: the whole library is already in memory, and
    /// a request per keystroke against a shared rate limit would be absurd for
    /// something already on the device.
    var searchText = ""
    private(set) var isLoading = false
    private(set) var hasAccount = true

    private let library: any LibraryProviding

    init(library: any LibraryProviding) {
        self.library = library
    }

    var total: Int { entries.count }

    /// "937 series across six shelves."
    var subtitle: String {
        guard total > 0 else { return "Nothing here yet" }
        let shelfCount = shelves.count
        return "\(total.formatted()) series across \(shelfCount) \(shelfCount == 1 ? "shelf" : "shelves")"
    }

    /// Mid-way through something, and still on it.
    ///
    /// Reading and rereading only. `tracksProgress` also covers paused, which
    /// put 226 series in "pick back up" on a real library — paused is a
    /// deliberate act of setting something down, not a thing to be nudged
    /// about.
    var inProgress: [LibraryEntry] {
        entries
            .filter {
                ($0.state == .reading || $0.state == .rereading)
                    && ($0.progressChapter ?? 0) > 0
            }
            .sorted { ($0.priority ?? 0) > ($1.priority ?? 0) }
    }

    /// The closing line. States the shape of the library rather than flattering
    /// it: on the reference account only 71 of 937 are actually being read.
    var shapeLine: String? {
        guard total > 0 else { return nil }
        let reading = entries.filter { $0.state == .reading }.count
        return """
        Reading is \(reading) of \(total.formatted()). The shelves are in size \
        order rather than reading order, so the library reads as the shape it \
        actually has.
        """
    }

    /// Re-reads after a write, so the screen reflects the server rather than
    /// what was typed into a sheet.
    func reload() async {
        entries = []
        await load()
    }

    func load() async {
        guard entries.isEmpty else { return }
        isLoading = true
        defer { isLoading = false }

        var all: [LibraryEntry] = []
        for page in 1...10 {
            let batch = await library.library(page: page, limit: 100)
            if batch.isEmpty { break }
            all.append(contentsOf: batch)
            if batch.count < 100 { break }
        }
        entries = all
        hasAccount = !all.isEmpty
        shelves = Self.shelves(from: all)
    }

    /// Shelves narrowed by the search box, empty ones dropped.
    var visibleShelves: [Shelf] {
        let needle = searchText.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return shelves }
        return shelves.compactMap { shelf in
            let matches = shelf.entries.filter { entry in
                entry.series?.matches(needle) == true
            }
            guard !matches.isEmpty else { return nil }
            return Shelf(state: shelf.state, entries: matches, note: shelf.note)
        }
    }

    /// How many series the search matched, across every shelf.
    var matchCount: Int { visibleShelves.reduce(0) { $0 + $1.count } }

    var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Grouped by state and sorted by size, largest first.
    ///
    /// Size order rather than the reading-order most apps use, because the
    /// reading-order arrangement puts a 71-item shelf above a 429-item one and
    /// misrepresents the library. The measurement that settled this: 46%
    /// dropped, 8% reading.
    static func shelves(from entries: [LibraryEntry]) -> [Shelf] {
        Dictionary(grouping: entries, by: \.state)
            .map { state, entries in
                Shelf(state: state, entries: entries, note: note(for: state, entries: entries))
            }
            .sorted { $0.count > $1.count }
    }

    /// Says something true about the shelf rather than repeating its name.
    private static func note(for state: LibraryEntry.State, entries: [LibraryEntry]) -> String {
        switch state {
        case .dropped:
            let withNote = entries.filter { !($0.note ?? "").isEmpty }.count
            return withNote > 0
                ? "\(withNote) carry a note about why you stopped."
                : "What you gave up on. The strongest signal you have."
        case .reading, .rereading:
            let withProgress = entries.filter { ($0.progressChapter ?? 0) > 0 }.count
            return "\(withProgress) have chapter progress recorded."
        case .completed:
            let rated = entries.filter { $0.rating != nil }.count
            return "\(rated) of these you rated."
        case .paused:
            return "Set down rather than abandoned."
        case .planToRead:
            return "Queued, not started."
        case .considering:
            return "Maybes. The stack's pile, on the server."
        }
    }
}
