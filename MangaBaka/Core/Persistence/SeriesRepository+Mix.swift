import Foundation

/// The blend half of `SeriesRepository`.
///
/// Split out for the lint's body-length ceiling, which the repository reached
/// when `mix` learned that the endpoint takes tag ids and ignores tag names.
/// The seam is the same one `+Cache`, `+Paging` and `+Count` use: everything
/// here belongs to one endpoint, `/v1/series/mix`.
extension SeriesRepository {
    func mix(seeds: [Int], filters: SearchQuery, excludedTags: [Int] = []) async -> MixResult {
        await mix(seeds: seeds, filters: filters, excludedTags: excludedTags, tagIDs: [])
    }

    func mix(
        seeds: [Int],
        filters: SearchQuery,
        excludedTags: [Int],
        tagIDs: [Int]
    ) async -> MixResult {
        guard !seeds.isEmpty else { return .empty }
        // `random_seed` only means something beside `sort_by=random`, which is
        // dropped here too; mix would otherwise receive a seed for nothing.
        var items = filters.queryItems.filter { !["q", "sort_by", "random_seed"].contains($0.name) }
        items = Self.mixTagQuery(replacingTagsIn: items, with: tagIDs)
        // Repeated keys; the comma form is rejected with HTTP 400. See
        // FeedKind.extraQuery for the verification.
        items.append(contentsOf: seeds.map { URLQueryItem(name: "series", value: String($0)) })
        items.append(URLQueryItem(name: "strict", value: "false"))
        items.append(contentsOf: blendExclusionQuery)
        // `blocked_tag`, not `tag_not` — see `filterQuery`'s doc comment.
        items.append(contentsOf: filterQuery(overridingTypes: filters.types, blockedTagParam: "blocked_tag"))
        // Excluded strands. Proven live: excluding the top tag drops it out of
        // the DNA, promotes everything below it, and changes most of the
        // results — so the DNA doubles as feedback for the edit just made.
        items.append(contentsOf: excludedTags.map {
            URLQueryItem(name: "tag_not", value: String($0))
        })

        do {
            let envelope: MixEnvelope = try await client.getRoot("/v1/series/mix", query: items)
            return MixResult(
                recommendations: (envelope.data ?? [])
                    .filter { $0.series.isDiscoverable && allowsFormat($0.series) },
                dna: BlendDNA(
                    strands: envelope.dna ?? [],
                    seedCount: envelope.seedCount ?? seeds.count
                )
            )
        } catch {
            // The request itself failed — a rate limit, an outage — which is
            // not the same thing as "nothing matched". `.empty` used to stand
            // for both, and the screen told a throttled reader "Nothing
            // matched. Try loosening the filters." (gap 11).
            return MixResult(failure: error)
        }
    }

    /// Mix takes tag *ids* and silently ignores a tag *name*.
    ///
    /// Measured 2026-09-14 against `/v1/series/mix`: `tag=Isekai` returns the
    /// unfiltered blend, `tag=94` filters it. `SearchQuery.wireTagIDs` sends
    /// the name itself when the bundled taxonomy cannot resolve it — a
    /// deliberate "filters somewhat" fallback on search, where a name does
    /// something — and the bundle holds 2,686 of the API's 7,146 tags, so on
    /// mix that fallback is a chip that lights up and changes nothing.
    ///
    /// Names are therefore dropped here rather than sent, the ids the caller
    /// resolved for itself (a DNA strand carries its own `tagId`, whether or
    /// not the bundle knows the name) are added, and `tag_mode` is rebuilt
    /// for what actually survived.
    nonisolated static func mixTagQuery(
        replacingTagsIn items: [URLQueryItem],
        with tagIDs: [Int]
    ) -> [URLQueryItem] {
        var values: [String] = []
        var kept = items.filter { $0.name != "tag" && $0.name != "tag_mode" }
        for item in items where item.name == "tag" {
            if let value = item.value, Int(value) != nil, !values.contains(value) {
                values.append(value)
            }
        }
        for id in tagIDs where !values.contains(String(id)) { values.append(String(id)) }
        kept.append(contentsOf: values.map { URLQueryItem(name: "tag", value: $0) })
        if values.count > 1 { kept.append(URLQueryItem(name: "tag_mode", value: "and")) }
        return kept
    }

    /// `mix` answers with `data` alongside `dna` and `seed_count` at the top
    /// level, so it needs its own envelope rather than the shared one.
    fileprivate struct MixEnvelope: Decodable {
        let data: [Recommendation]?
        let dna: [BlendDNA.Strand]?
        let seedCount: Int?
    }
}
