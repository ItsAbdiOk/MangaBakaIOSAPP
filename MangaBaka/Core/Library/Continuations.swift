import Foundation

/// "More of what you finished": sequels, spin-offs and side stories of series
/// the reader has completed, that are not already in their library.
///
/// Ported from a sibling project's `continuations()`.
enum Continuations {
    /// One finished series' relationship, paired with the entry it came from —
    /// `pick` needs both to say what a continuation is "because of". A struct
    /// rather than a tuple: SwiftLint's `large_tuple` flags a bare
    /// `(from: LibraryEntry, relation: SeriesRelationship)`.
    struct RelationSource {
        let from: LibraryEntry
        let relation: SeriesRelationship
    }

    /// Relationship types worth surfacing as a continuation.
    ///
    /// "prequel" and "source" are excluded on purpose: a finished series'
    /// prequel is the part the reader almost certainly read first (you finish
    /// a series at its end, not its start), and "source" is usually the novel
    /// the manga adapted, which is rarely what "more of this" means.
    static let continuationTypes: Set<String> = [
        "sequel", "spin_off", "side_story", "alternative", "adaptation"
    ]

    /// Completed entries with a series, most recently finished first.
    /// `libraryIDs` is accepted for symmetry with `pick` but unused here —
    /// every completed entry is, by definition, already in the library.
    static func candidates(
        finished: [LibraryEntry],
        libraryIDs: Set<Int>,
        limit: Int = 8
    ) -> [LibraryEntry] {
        Array(
            finished
                .filter { $0.state == .completed && $0.series != nil }
                .sorted { lhs, rhs in
                    switch (lhs.finishDate, rhs.finishDate) {
                    case let (.some(left), .some(right)): left > right
                    case (.some, nil): true
                    case (nil, .some): false
                    case (nil, nil): false
                    }
                }
                .prefix(limit)
        )
    }

    /// Keeps only continuation-type relations, drops anything already in the
    /// library, dedupes by series id keeping the first occurrence, and keeps
    /// the order the relations arrived in.
    static func pick(
        _ relations: [RelationSource],
        libraryIDs: Set<Int>
    ) -> [Continuation] {
        var seen = Set<Int>()
        var result: [Continuation] = []
        for source in relations {
            guard let type = source.relation.relationType,
                  continuationTypes.contains(type)
            else { continue }
            let series = source.relation.series
            guard !libraryIDs.contains(series.id), !seen.contains(series.id) else { continue }
            seen.insert(series.id)
            result.append(Continuation(
                series: series,
                because: source.from.series?.displayTitle ?? "Untitled series",
                label: source.relation.label
            ))
        }
        return result
    }
}

/// One suggested continuation: a series, and why it was suggested.
struct Continuation: Identifiable {
    let series: Series
    /// The finished series' title.
    let because: String
    let label: String

    var id: Int { series.id }
}

/// Builds "More of what you finished" for the library screen: up to eight
/// recently completed series, their relationships fetched one request at a
/// time, turned into a deduped, capped row.
@MainActor
@Observable
final class ContinuationsModel {
    private let repository: any SeriesRepositoryProtocol
    private(set) var items: [Continuation] = []
    private(set) var isLoading = false
    /// The finished entries' own ids `items` was last built from. A second
    /// `load` with the same set is a no-op — the library screen re-appears
    /// far more often than the reader finishes a new series.
    private var loadedFor: Set<Int>?

    init(repository: any SeriesRepositoryProtocol) {
        self.repository = repository
    }

    /// Fetches relationships for up to eight recently completed series,
    /// sequentially — this is at most eight requests, not worth the
    /// concurrency — and stops as soon as 12 continuations have turned up.
    func load(entries: [LibraryEntry]) async {
        let libraryIDs = Set(entries.compactMap(\.series?.id))
        let finished = Continuations.candidates(finished: entries, libraryIDs: libraryIDs)
        let finishedIDs = Set(finished.map(\.id))
        guard loadedFor != finishedIDs else { return }

        isLoading = true
        defer { isLoading = false }

        var relations: [Continuations.RelationSource] = []
        for entry in finished {
            guard let seriesId = entry.series?.id,
                  let fetched = await repository.relationships(for: seriesId)
            else { continue }
            relations.append(contentsOf: fetched.map {
                Continuations.RelationSource(from: entry, relation: $0)
            })
            if Continuations.pick(relations, libraryIDs: libraryIDs).count >= 12 { break }
        }

        items = Continuations.pick(relations, libraryIDs: libraryIDs)
        loadedFor = finishedIDs
    }
}
