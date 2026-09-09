import Foundation
@testable import MangaBaka

/// Builds a `Series` for tests with everything optional defaulted away.
///
/// Without this, every test that constructs a Series breaks whenever the model
/// gains a field — which has already happened three times. A factory means a
/// new field costs one default here rather than an edit in every suite.
enum SeriesFactory {
    static func make(
        id: Int = 1,
        state: String = "active",
        mergedWith: Int? = nil,
        title: String? = nil,
        titles: [SeriesTitle]? = nil,
        cover: Cover = .empty,
        description: String? = nil,
        authors: [String]? = nil,
        artists: [String]? = nil,
        status: String? = nil,
        rating: Double? = nil,
        type: String? = nil,
        contentRating: String? = nil,
        totalChapters: Double? = nil,
        finalVolume: Double? = nil,
        publishers: [Series.Publisher]? = nil,
        anime: Series.AnimeAdaptation? = nil,
        source: [String: Series.TrackerEntry]? = nil
    ) -> Series {
        let resolvedTitles = titles ?? title.map {
            [SeriesTitle(language: "en", traits: ["official"], title: $0, isPrimary: true)]
        }
        return Series(
            id: id, state: state, mergedWith: mergedWith, titles: resolvedTitles,
            cover: cover, description: description, authors: authors, artists: artists,
            status: status, rating: rating, type: type, contentRating: contentRating,
            totalChapters: totalChapters, finalVolume: finalVolume,
            publishers: publishers, anime: anime, source: source
        )
    }
}

extension Cover {
    /// A cover with no artwork, which the API does return.
    static let empty = Cover(
        raw: nil, x150: nil, x250: nil, x350: nil,
        blurhash: nil, width: nil, height: nil
    )

    /// A cover with dimensions, for tests that care about aspect ratio.
    static let sized = Cover(
        raw: nil, x150: nil, x250: nil, x350: nil,
        blurhash: nil, width: 200, height: 300
    )

    /// A real cover, not a tidy one: series 1291's artwork as the live API
    /// reports it (fetched from /v2/series/discover/rising, 2026-09-09). One
    /// twenty-item row came back with fourteen distinct ratios spanning 0.63
    /// to 0.88, which is what made a row of covers visibly ragged when each
    /// was framed at its own.
    static let realWide = Cover(
        raw: nil, x150: nil, x250: nil, x350: nil,
        blurhash: nil, width: 4800, height: 5450
    )
}

/// A repository stub that satisfies the whole protocol, so a new protocol
/// method costs one default here rather than a compile error in every suite.
class StubRepositoryBase: SeriesRepositoryProtocol, @unchecked Sendable {
    func feed(_ feed: FeedKind, forceRefresh: Bool) async -> FeedResult {
        FeedResult(series: [], origin: .network)
    }

    func search(_ query: SearchQuery) async -> FeedResult {
        FeedResult(series: [], origin: .network)
    }

    func feedPage(_ feed: FeedKind, page: Int) async -> FeedResult {
        FeedResult(series: [], origin: .network)
    }

    func mix(seeds: [Int], filters: SearchQuery) async -> [Recommendation] { [] }

    func extras(for seriesId: Int) async -> SeriesExtras { SeriesExtras() }

    func updateContentRatings(_ ratings: [String]) async {}

    func updateFormats(_ formats: [String]) async {}
}
