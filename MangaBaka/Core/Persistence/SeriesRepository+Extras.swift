import Foundation

/// The series page's five-leg fetch, in its own file for the lint's ceiling
/// on `SeriesRepository.swift`. `extras(for:hero:)` is the entry point.
extension SeriesRepository {
    func fetchExtras(
        for seriesId: Int, hero: @escaping @Sendable (SeriesExtras) async -> Void
    ) async -> SeriesExtras {
        // Two phases (review perf DT1, 2026-09-15). Phase one is what the
        // top of the page draws — the full record (tags, year, synopsis,
        // links) and the first works page — both `.userInitiated`, both
        // concurrent, and handed to `hero` the moment they return. Phase two
        // is everything below the fold — news, relationships, collections,
        // the works last page — all `.background`, which *waits* at the gate
        // where `.userInitiated` throws (`RateLimitGate`). Before this the
        // five legs were awaited together, so from 120 requests held the
        // synopsis stalled on the three background legs the reader had not
        // scrolled to yet.
        //
        // Counted 2026-09-14 (`docs/reviews/detail-page-budget.md`): a cold
        // open was nine MangaBaka requests, all foreground, floor 6.6 opens a
        // minute under Discover prefetch. Now eight, three foreground
        // (`full`, works page one, `images`): floor 20 a minute.
        //
        // No `/links` leg since 2026-09-15: the full record carries the same
        // links inline (`Series.linksV2`).
        async let full: Result<Series, APIError> = Self.attempt {
            () async throws(APIError) -> Series in
            try await client.get("/v1/series/\(seriesId)")
        }
        async let firstWorks: Result<WorksFirstPage, APIError> = Self.attempt {
            () async throws(APIError) -> WorksFirstPage in
            try await fetchWorksFirstPage(for: seriesId)
        }
        let heroResults = await (full, firstWorks)
        let detail = Self.value(heroResults.0)
        let firstPage = Self.value(heroResults.1)
        var extras = SeriesExtras(
            links: detail?.linksV2 ?? [],
            tags: detail?.tags ?? [],
            richTags: detail?.richTags ?? [],
            volumes: SeriesWork.volumes(from: firstPage?.works ?? []),
            worksTotal: firstPage?.total,
            year: detail?.year,
            full: detail,
            failure: Self.combinedFailure([Self.failure(heroResults.0), Self.failure(heroResults.1)]),
            missingLegs: Self.failure(heroResults.1) == nil ? [] : [.worksFirstPage]
        )
        await hero(extras)

        async let news: Result<[NewsItem], APIError> = Self.attempt {
            () async throws(APIError) -> [NewsItem] in
            try await client.getLossy(
                "/v1/series/\(seriesId)/news",
                query: [URLQueryItem(name: "limit", value: "6")],
                priority: .background
            )
        }
        async let related: Result<[SeriesRelationship], APIError> = Self.attempt {
            () async throws(APIError) -> [SeriesRelationship] in
            try await client.getLossy("/v1/series/\(seriesId)/relationships", priority: .background)
        }
        async let editions: Result<[SeriesEdition], APIError> = Self.attempt {
            () async throws(APIError) -> [SeriesEdition] in
            try await client.getLossy("/v1/series/\(seriesId)/collections", priority: .background)
        }
        let lastPage = firstPage?.lastPage
        async let lastWorks: Result<[SeriesWork], APIError> = Self.attempt {
            () async throws(APIError) -> [SeriesWork] in
            guard let lastPage else { return [] }
            return try await fetchWorksLastPage(for: seriesId, page: lastPage)
        }
        let tail = TailResults(
            news: await news, related: await related, editions: await editions, lastWorks: await lastWorks
        )
        Self.mergeTail(into: &extras, firstWorks: firstPage?.works ?? [], tail: tail)
        return extras
    }

    struct TailResults: Sendable {
        let news: Result<[NewsItem], APIError>
        let related: Result<[SeriesRelationship], APIError>
        let editions: Result<[SeriesEdition], APIError>
        let lastWorks: Result<[SeriesWork], APIError>
    }

    /// Folds the four tail legs into `extras`, naming the ones that failed.
    nonisolated static func mergeTail(
        into extras: inout SeriesExtras, firstWorks: [SeriesWork], tail: TailResults
    ) {
        if let news = value(tail.news) { extras.news = news } else { extras.missingLegs.insert(.news) }
        if let related = value(tail.related) {
            extras.relationships = related.filter(\.series.isDiscoverable)
        } else {
            extras.missingLegs.insert(.relationships)
        }
        if let editions = value(tail.editions) {
            extras.editions = editions.presentable
        } else {
            extras.missingLegs.insert(.editions)
        }
        if let last = value(tail.lastWorks) {
            if !last.isEmpty { extras.volumes = SeriesWork.volumes(from: joined(firstWorks, last)) }
        } else {
            extras.missingLegs.insert(.worksLastPage)
        }
        extras.failure = combinedFailure([
            extras.failure, failure(tail.news), failure(tail.related), failure(tail.editions),
            failure(tail.lastWorks)
        ])
        // Answered legs are no longer missing, whatever an earlier row said.
        for leg in [SeriesExtras.Leg.news, .relationships, .editions, .worksLastPage]
        where !failedLegs(tail).contains(leg) {
            extras.missingLegs.remove(leg)
        }
    }

    nonisolated private static func failedLegs(_ tail: TailResults) -> Set<SeriesExtras.Leg> {
        var legs: Set<SeriesExtras.Leg> = []
        if failure(tail.news) != nil { legs.insert(.news) }
        if failure(tail.related) != nil { legs.insert(.relationships) }
        if failure(tail.editions) != nil { legs.insert(.editions) }
        if failure(tail.lastWorks) != nil { legs.insert(.worksLastPage) }
        return legs
    }

    /// Re-asks only the legs a cached partial row lacks, `.background`, and
    /// rewrites the row when they land. A leg that fails again stays
    /// missing; the page keeps what it had.
    func refetchMissingLegs(of cached: SeriesExtras, for seriesId: Int) async -> SeriesExtras {
        let missing = cached.missingLegs
        let firstWorks = cached.volumes.flatMap(\.editions)
        async let news: Result<[NewsItem], APIError> = missing.contains(.news)
            ? Self.attempt { () async throws(APIError) -> [NewsItem] in
                try await client.getLossy(
                    "/v1/series/\(seriesId)/news", query: [URLQueryItem(name: "limit", value: "6")],
                    priority: .background
                )
            }
            : .success(cached.news)
        async let related: Result<[SeriesRelationship], APIError> = missing.contains(.relationships)
            ? Self.attempt { () async throws(APIError) -> [SeriesRelationship] in
                try await client.getLossy("/v1/series/\(seriesId)/relationships", priority: .background)
            }
            : .success(cached.relationships)
        async let editions: Result<[SeriesEdition], APIError> = missing.contains(.editions)
            ? Self.attempt { () async throws(APIError) -> [SeriesEdition] in
                try await client.getLossy("/v1/series/\(seriesId)/collections", priority: .background)
            }
            : .success(cached.editions)
        async let lastWorks: Result<[SeriesWork], APIError> = missing.contains(.worksLastPage)
            ? Self.attempt { () async throws(APIError) -> [SeriesWork] in
                let first = try await fetchWorksFirstPage(for: seriesId)
                guard let page = first.lastPage else { return [] }
                return try await fetchWorksLastPage(for: seriesId, page: page)
            }
            : .success([])
        var merged = cached
        merged.failure = nil
        let tail = TailResults(
            news: await news, related: await related, editions: await editions, lastWorks: await lastWorks
        )
        Self.mergeTail(into: &merged, firstWorks: firstWorks, tail: tail)
        if merged.missingLegs != cached.missingLegs {
            do {
                try writeDetailCache(merged, for: seriesId)
            } catch {
                let reason = String(describing: error)
                Self.cacheLogger.error(
                    "partial detail rewrite failed \(seriesId, privacy: .public): \(reason, privacy: .public)"
                )
            }
        }
        return merged
    }

}
