import Foundation

/// What the reader's library says about them.
///
/// Three sources, all real: MangaBaka's own affinity scores, the shape of the
/// library by shelf, and the distribution of ratings the reader gave. Nothing
/// here is inferred by the app beyond counting.
@MainActor
@Observable
final class TasteModel {
    private(set) var affinities: [TopGenre] = []
    private(set) var entries: [LibraryEntry] = []
    private(set) var isLoading = false

    private let library: any LibraryProviding

    init(library: any LibraryProviding) {
        self.library = library
    }

    var hasAnything: Bool { !affinities.isEmpty || !entries.isEmpty }

    /// How many ratings sit at each of the five steps, lowest first.
    ///
    /// `rating` is a 0-100 field whose real values land on 20/40/60/80/100, so
    /// this buckets to five rather than pretending to a hundred.
    var ratingHistogram: [Int] {
        var buckets = [Int](repeating: 0, count: 5)
        for entry in entries {
            guard let rating = entry.rating else { continue }
            let step = max(1, min(5, Int((rating / 20).rounded())))
            buckets[step - 1] += 1
        }
        return buckets
    }

    var ratedCount: Int { ratingHistogram.reduce(0, +) }

    /// The step the reader uses most. On a real library this was the LOWEST
    /// one, which is the interesting part.
    var commonestRating: Int? {
        let histogram = ratingHistogram
        guard let peak = histogram.max(), peak > 0 else { return nil }
        return (histogram.firstIndex(of: peak) ?? 0) + 1
    }

    /// A sentence about the ratings that is true of this library rather than
    /// flattering. Nil when there is not enough to say anything.
    var ratingLine: String? {
        guard ratedCount > 0, let commonest = commonestRating else { return nil }
        let share = Int((Double(ratingHistogram[commonest - 1]) / Double(ratedCount) * 100).rounded())
        let stars = commonest == 1 ? "one star" : "\(commonest) stars"
        return "You rated \(ratedCount.formatted()) of them. \(stars) is your commonest, at \(share)%."
    }

    /// Shelf counts, largest first.
    var shelfCounts: [(state: LibraryEntry.State, count: Int)] {
        Dictionary(grouping: entries, by: \.state)
            .map { (state: $0.key, count: $0.value.count) }
            .sorted { $0.count > $1.count }
    }

    /// The largest shelf, as a share. On a real library this is "dropped".
    var shapeLine: String? {
        guard let biggest = shelfCounts.first, !entries.isEmpty else { return nil }
        let share = Int((Double(biggest.count) / Double(entries.count) * 100).rounded())
        return "\(biggest.state.title) is your biggest shelf at \(share)% of \(entries.count.formatted())."
    }

    func load(entries: [LibraryEntry]) async {
        isLoading = true
        defer { isLoading = false }
        self.entries = entries
        affinities = await library.topGenres()
    }
}
