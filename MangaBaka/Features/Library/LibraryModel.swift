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

    /// Which state the list is narrowed to, or nil for all of them.
    var filter: LibraryEntry.State?

    /// How the list is ordered.
    var sort: LibrarySort = .recentlyUpdated
    private(set) var isLoading = false
    private(set) var hasAccount = true
    /// Whether every page arrived. False means the counts on screen are a floor,
    /// not a total, and nothing may be stated as absent on the strength of them.
    private(set) var isComplete = true
    private(set) var failure: APIError?

    private let library: any LibraryProviding
    private let snapshot: LibrarySnapshot

    init(library: any LibraryProviding, snapshot: LibrarySnapshot? = nil) {
        self.library = library
        self.snapshot = snapshot ?? LibrarySnapshot(library: library)
    }

    var total: Int { entries.count }

    /// Every state that has anything in it, in reading order.
    ///
    /// Dropped is last on purpose — it is the one state a reader wants counted
    /// but not offered first.
    var shape: [(state: LibraryEntry.State, count: Int)] {
        let order: [LibraryEntry.State] = [
            .reading, .rereading, .paused, .completed, .planToRead, .considering, .dropped
        ]
        return order.compactMap { state in
            let count = entries.count { $0.state == state }
            return count > 0 ? (state, count) : nil
        }
    }

    /// The list, after the filter, the search box and the sort.
    ///
    /// **Dropped is absent unless it is what you asked for.** It is a real part
    /// of the library and it is counted everywhere — the shape bar, the
    /// filter — but a list of everything you read that opens with the things
    /// you gave up on is a worse answer than one that does not.
    var listed: [LibraryEntry] {
        var rows = entries
        if let filter {
            rows = rows.filter { $0.state == filter }
        } else {
            rows = rows.filter { $0.state != .dropped }
        }

        let trimmed = searchText.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            rows = rows.filter { entry in
                guard let series = entry.series else { return false }
                return series.matches(trimmed)
            }
        }
        return rows.sorted(by: sort.comparator)
    }

    /// Whether a jump index is worth the space.
    ///
    /// The design board draws one on a screen sorted by "Recently updated",
    /// and its own caption says the index only appears when sorted by title and
    /// above about two hundred entries. The caption wins: an A-Z rail down a
    /// list ordered by date points at nothing.
    var showsJumpIndex: Bool {
        sort == .title && listed.count >= 200
    }

    /// The letters actually present, in order, each paired with the first entry
    /// filed under it — which is what the rail scrolls to.
    ///
    /// The letters present, not A to Z: a rail offering Q and X to a library
    /// with neither is a rail that lies about where it can take you.
    var jumpTargets: [(letter: String, id: Int)] {
        var seen: [(letter: String, id: Int)] = []
        for entry in listed where seen.last?.letter != entry.indexLetter {
            seen.append((entry.indexLetter, entry.seriesId))
        }
        return seen
    }

    /// "1,204 series · 512 rated".
    ///
    /// Rated rather than shelved. The shape bar below says how the library is
    /// divided far better than a count of shelves ever did, and how much of it
    /// you have actually formed an opinion on is a thing nothing else answers.
    var subtitle: String {
        guard total > 0 else { return "Nothing here yet" }
        let rated = entries.count { ($0.rating ?? 0) > 0 }
        return "\(total.formatted()) series · \(rated.formatted()) rated"
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
        // The shared snapshot has to be told, or a reload re-reads the copy
        // that was already wrong. Caught by three existing tests the moment the
        // snapshot was introduced: a write landed, the screen refetched, and
        // the cache handed back the library as it had been before the write.
        await snapshot.invalidate()
        entries = []
        await load()
    }

    /// Entries per request. 100 is what the endpoint has been exercised at.
    ///
    /// The design board assumes 500 and says "500 of 1,204 loaded". That may
    /// well be right, but it is untested against the live endpoint and the
    /// failure mode of guessing high is silent: if the server capped a
    /// 500-request at 100, the short-page check below would read that as the
    /// end of the library and stop after one page. Raise it only with a real
    /// response to look at.
    private static let pageSize = 100

    /// How many pages to walk before giving up.
    ///
    /// Was ten, which is a thousand entries — and Abdi's own library is 937.
    /// Sixty-four more series and the rest would have disappeared with no
    /// error, which is the same class of bug as the one that offered "Add to
    /// library" for a series already in it. Thirty is far past any real library
    /// and still bounded, because an unbounded loop against a paginated API is
    /// how you hammer a shared rate limit when the server misbehaves.
    private static let pageCap = 30

    func load() async {
        await Signposts.measure("Library load") { await fetchAll() }
    }

    private func fetchAll() async {
        guard entries.isEmpty else { return }
        isLoading = true
        defer { isLoading = false }

        // One walk per session, shared with the taste ledger and the release
        // reminders. Measured on a real account: 939 entries is 24.7 MB, and
        // three separate walks was 74 MB to draw one screen.
        let result = await snapshot.load()
        entries = result.entries
        isComplete = result.isComplete
        failure = result.failure
        hasAccount = !result.entries.isEmpty || !result.isComplete
        shelves = Self.shelves(from: result.entries)
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
                ? "\(withNote) \(withNote == 1 ? "carries" : "carry") a note about why you stopped."
                : "What you gave up on. The strongest signal you have."
        case .reading, .rereading:
            let withProgress = entries.filter { ($0.progressChapter ?? 0) > 0 }.count
            // "1 have chapter progress recorded" and "0 of these you rated" are
            // both reachable on a real shelf, and this string is the screen's
            // subtitle, so they read as the headline description of it.
            return withProgress > 0
                ? "\(withProgress) \(withProgress == 1 ? "has" : "have") chapter progress recorded."
                : "Where you are partway through."
        case .completed:
            let rated = entries.filter { $0.rating != nil }.count
            return rated > 0
                ? "\(rated) of these you rated."
                : "Finished. None of them rated yet."
        case .paused:
            return "Set down rather than abandoned."
        case .planToRead:
            return "Queued, not started."
        case .considering:
            return "Maybes. The stack's pile, on the server."
        }
    }
}
