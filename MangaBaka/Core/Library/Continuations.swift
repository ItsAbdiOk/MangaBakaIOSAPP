import Foundation
import os

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
    /// True when at least one of the last walk's asks failed rather than
    /// genuinely finding nothing. The row shows `InlineFailure` under its
    /// header instead of vanishing when this is set and `items` is empty —
    /// see `ContinuationsRow`.
    private(set) var hasFailure = false
    /// The last leg's error, so the row can count down a throttle (L2).
    private(set) var failure: APIError?
    /// The finished entries' own ids `items` was last built from. A second
    /// `load` with the same set is a no-op — the library screen re-appears
    /// far more often than the reader finishes a new series.
    private var loadedFor: Set<Int>?

    private static let logger = Logger(
        subsystem: "dev.abdirahmanmohamed.mangabaka", category: "library"
    )

    init(repository: any SeriesRepositoryProtocol) {
        self.repository = repository
    }

    /// Fetches relationships for up to eight recently completed series,
    /// sequentially — this is at most eight requests, not worth the
    /// concurrency — and stops as soon as 12 continuations have turned up.
    ///
    /// Gap 92 (d): three bugs in how a failure was handled. The loop had no
    /// cancellation check, so leaving the library screen mid-walk let it run
    /// eight requests nobody was waiting on. Every failed
    /// `relationships(for:)` call was silently indistinguishable from "no
    /// relationships" — `nil` and `[]` both just skipped the entry — so a
    /// reader offline saw an empty row with no way to tell it apart from one
    /// that genuinely has no continuations to show. And `loadedFor` was set
    /// unconditionally, so a session that started offline never retried once
    /// the connection came back — the empty answer was cached as final by
    /// the one guard whose job is to avoid redundant *successful* fetches.
    func load(entries: [LibraryEntry]) async {
        let libraryIDs = Set(entries.compactMap(\.series?.id))
        let finished = Continuations.candidates(finished: entries, libraryIDs: libraryIDs)
        let finishedIDs = Set(finished.map(\.id))
        guard loadedFor != finishedIDs else { return }

        isLoading = true
        defer { isLoading = false }

        var relations: [Continuations.RelationSource] = []
        var anyFailed = false
        failure = nil
        for entry in finished {
            guard !Task.isCancelled else { return }
            guard let seriesId = entry.series?.id else { continue }
            // R11/P11: the series page already caches this same endpoint to
            // disk for 6 hours as one of `extras`' six legs — `cachedExtras`
            // reads that cache and nothing else, so a series whose page was
            // opened recently costs this row zero requests instead of one.
            // Only a cache miss falls through to `relationships(for:)`,
            // which still asks the network (and, undocumented here: it has
            // no `priority:` parameter to pass `.background` to — see the
            // fix report).
            let fetched: [SeriesRelationship]
            if let cached = await repository.cachedExtras(for: seriesId) {
                fetched = cached.relationships
            } else {
                // `.background`: a row on the Library tab, not the thing the
                // reader tapped; it waits at the gate rather than throwing.
                switch await repository.relationships(for: seriesId, priority: .background) {
                case let .success(rows):
                    fetched = rows
                case let .failure(error):
                    anyFailed = true
                    failure = error
                    let reason = String(describing: error)
                    Self.logger.error(
                        "Continuations: \(seriesId, privacy: .public) failed: \(reason, privacy: .public)"
                    )
                    continue
                }
            }
            relations.append(contentsOf: fetched.map {
                Continuations.RelationSource(from: entry, relation: $0)
            })
            if Continuations.pick(relations, libraryIDs: libraryIDs).count >= 12 { break }
        }
        guard !Task.isCancelled else { return }

        items = Continuations.pick(relations, libraryIDs: libraryIDs)
        hasFailure = anyFailed
        // Only remembered as "seen" when every ask actually answered — a
        // session that saw nothing because it was offline gets to try again
        // next time this loads, rather than being told the same silence
        // forever.
        if !anyFailed { loadedFor = finishedIDs }
    }

    /// Forces the next `load` to run again, ignoring `loadedFor` — for the
    /// row's own Retry, which should not have to wait for the finished-ids
    /// set to change.
    func retry(entries: [LibraryEntry]) async {
        loadedFor = nil
        await load(entries: entries)
    }
}
