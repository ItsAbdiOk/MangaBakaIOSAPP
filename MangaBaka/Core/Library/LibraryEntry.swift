import Foundation

/// One series in the reader's own library.
///
/// The seven states are richer than the usual five. `considering` is the one
/// that matters most here: the swipe stack's "maybe" pile has a real home on
/// the server rather than being a local invention.
struct LibraryEntry: Decodable, Identifiable, Sendable, Equatable {
    enum State: String, Codable, CaseIterable, Sendable {
        case considering
        case planToRead = "plan_to_read"
        case reading
        case rereading
        case paused
        case completed
        case dropped

        var title: String {
            switch self {
            case .considering: "Considering"
            case .planToRead: "Plan to read"
            case .reading: "Reading"
            case .rereading: "Rereading"
            case .paused: "Paused"
            case .completed: "Completed"
            case .dropped: "Dropped"
            }
        }

        /// Whether progress through the series is meaningful for this state.
        /// Showing "chapter 0 of 200" against a plan-to-read entry is noise.
        var tracksProgress: Bool {
            switch self {
            case .reading, .rereading, .paused: true
            case .considering, .planToRead, .completed, .dropped: false
            }
        }
    }

    let id: Int
    let seriesId: Int
    let state: State
    let progressChapter: Double?
    let progressVolume: Double?
    /// 0-100, as the API expresses ratings throughout.
    let rating: Double?
    let note: String?
    let startDate: Date?
    let finishDate: Date?
    let numberOfRereads: Int?
    /// Higher means more wanted. The reader's own ordering within a state.
    let priority: Int?
    let isPrivate: Bool?
    let readLink: String?
    /// The series itself, capitalised in the response — unusual, and the
    /// reason this uses explicit coding keys rather than the automatic
    /// snake_case conversion.
    let series: Series?

    // The decoder applies convertFromSnakeCase before matching, so every
    // snake_case key is already camelCase by the time it gets here and needs no
    // mapping. "Series" is the exception: with no underscore and a leading
    // capital it survives the conversion untouched, so it alone is spelled out.
    // Writing the others in snake_case here silently matched nothing and
    // decoded every field as absent.
    enum CodingKeys: String, CodingKey {
        case id
        case seriesId
        case state
        case progressChapter
        case progressVolume
        case rating
        case note
        case startDate
        case finishDate
        case numberOfRereads
        case priority
        case isPrivate
        case readLink
        case series = "Series"
    }
}

/// Whether personalised recommendations are worth asking for yet.
struct RecommendationStatus: Decodable, Sendable, Equatable {
    /// The library is too small to personalise from.
    let coldStart: Bool?
    /// The profile is being rebuilt; results are usable but behind.
    let profileStale: Bool?
    let libraryCount: Int?

    var canPersonalise: Bool { coldStart != true }
}

/// A recommendation from the reader's own profile.
///
/// A lighter shape than `Series`: the API returns `cover_image` rather than a
/// full cover object, and no description or authors. Modelled separately rather
/// than forced into `Series`, because pretending they are the same type would
/// mean inventing the missing halves.
struct PersonalRecommendation: Decodable, Identifiable, Sendable, Equatable {
    let id: Int
    let titles: [SeriesTitle]?
    /// A full cover object in the v1 shape, not a URL string.
    ///
    /// It was modelled as `String?` on the strength of the field's name, and
    /// the endpoint has therefore never decoded: the mismatch threw, the `try?`
    /// in `LibraryService` swallowed it, and personalised recommendations came
    /// back as an empty list every time. Verified against the live endpoint on
    /// 2026-09-09 — the third instance of the same v1/v2 shape split this week,
    /// which is why there is now a contract test per shape.
    let coverImage: Cover?
    let mediaType: String?
    let publishedYear: Int?
    /// Why this was suggested. An object, not a string — it names the kind of
    /// match and the tags behind it, which makes an honest, specific
    /// explanation possible instead of "recommended for you".
    let reason: Reason?
    let score: Double?

    struct Reason: Decodable, Sendable, Equatable {
        /// "similar_to" is the only value observed so far.
        let reasonType: String?
        let topTags: [WeightedTag]?

        struct WeightedTag: Decodable, Sendable, Equatable, Hashable {
            let id: Int
            let name: String
            /// How central the tag is to the series: core, defining,
            /// recurrent, incidental, unweighted. Absent on some tags.
            let weight: String?
        }

        /// A short phrase for the UI, built only from what the API gave.
        /// Returns nil rather than inventing a reason.
        var summary: String? { summary(hiding: []) }

        /// The same phrase with named tags withheld.
        ///
        /// The tags come from the reader's own library, not from the
        /// recommended series, so a series well inside the reader's content
        /// setting can still be explained by a tag well outside it — an app
        /// set to safe and suggestive was captioning cards "Because you read
        /// BDSM and Cunnilingus" (observed on device, 2026-09-09). That is
        /// someone's reading history printed on a phone screen in public.
        ///
        /// Withheld tags are dropped rather than replaced, and a reason left
        /// with nothing to say returns nil. Half a reason is still a reason.
        func summary(hiding hiddenTagIDs: Set<Int>) -> String? {
            let names = (topTags ?? [])
                .filter { !hiddenTagIDs.contains($0.id) }
                .prefix(2)
                .map(\.name)
            guard !names.isEmpty else { return nil }
            return "Because you read \(names.joined(separator: " and "))"
        }
    }

    var displayTitle: String? { DisplayTitle.choose(from: titles) }

    /// The recommendation as a `Series`, so it can go through the same card,
    /// detail screen and shelf as everything else.
    ///
    /// The absent fields are absent from the endpoint, not dropped here: it
    /// returns no description, authors, artists, status, rating, publishers or
    /// tracker scores. `state` is "active" because the endpoint only recommends
    /// series that can be read — an assumption, and the only one made here.
    var asSeries: Series {
        Series(
            id: id,
            state: "active",
            mergedWith: nil,
            titles: titles,
            cover: coverImage ?? Cover(
                raw: nil, x150: nil, x250: nil, x350: nil,
                blurhash: nil, width: nil, height: nil
            ),
            description: nil,
            authors: nil,
            artists: nil,
            status: nil,
            rating: nil,
            type: mediaType,
            contentRating: nil,
            totalChapters: nil,
            finalVolume: nil,
            publishers: nil,
            anime: nil,
            source: nil,
            year: publishedYear
        )
    }
}

/// A tag the reader gravitates towards, with how strongly.
///
/// This is the closest thing the API offers to a taste profile: real affinity
/// scores over the reader's own library, not a guess.
struct TopGenre: Decodable, Identifiable, Sendable, Equatable {
    let tagId: Int
    let tagName: String
    /// Roughly 0-100. Comparable between tags for one reader; not between
    /// readers, so it is shown as a ranking rather than a number.
    let affinityScore: Double?

    var id: Int { tagId }
}
