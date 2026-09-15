import Foundation

/// Defaults a stub or a lesser repository inherits — each one the cheapest
/// honest answer, never a network fetch. Its own file for the lint's ceiling
/// on `SeriesRepository.swift`.
extension SeriesRepositoryProtocol {
    /// A repository that does not distinguish tag ids blends without them.
    func mix(
        seeds: [Int],
        filters: SearchQuery,
        excludedTags: [Int],
        tagIDs: [Int]
    ) async -> MixResult {
        await mix(seeds: seeds, filters: filters, excludedTags: excludedTags)
    }

    /// Stubs and any repository without a cheaper path fall back to the
    /// full record `extras` fetches.
    func series(id: Int) async -> Series? { await extras(for: id).full }

    /// Nil by default: a stub has nothing cached, and a repository with no
    /// cheaper path than `extras(for:)` should not be made to pay for a
    /// network fetch just to answer "is anything cached".
    func cachedExtras(for seriesId: Int) async -> SeriesExtras? { nil }

    /// One `cachedExtras` per id, for any repository without the batched read.
    /// The real one overrides this with a single query; a stub answering nil
    /// costs nothing either way.
    func cachedExtrasLinks(for ids: [Int]) async -> [Int: [SeriesLink]] {
        var links: [Int: [SeriesLink]] = [:]
        for id in ids {
            if let cached = await cachedExtras(for: id) { links[id] = cached.links }
        }
        return links
    }

    func cachedExtrasVolumes(for ids: [Int]) async -> [Int: [SeriesWork.Volume]] {
        var volumes: [Int: [SeriesWork.Volume]] = [:]
        for id in ids {
            if let cached = await cachedExtras(for: id) { volumes[id] = cached.volumes }
        }
        return volumes
    }

    // The four `RequestPriority` default overloads live in
    // SeriesRepository+Priority.swift — this file was already at the lint's
    // 400-line ceiling before they existed, the same reason `+Cache`,
    // `+Paging` and `+Count` are split out. Not a widening of who touches
    // this protocol.
}
