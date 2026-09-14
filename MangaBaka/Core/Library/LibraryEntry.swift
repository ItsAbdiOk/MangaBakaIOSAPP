import Foundation

/// One series in the reader's own library.
///
/// The seven states are richer than the usual five. `considering` is the one
/// that matters most here: the swipe stack's "maybe" pile has a real home on
/// the server rather than being a local invention.
///
/// `Codable` rather than `Decodable` so the library can be cached on disk. The
/// encode side exists only for that cache: 939 entries is 24.7 MB over the wire
/// and the same answer every launch.
struct LibraryEntry: Codable, Identifiable, Sendable, Equatable {
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

        /// Gap 4: a raw value this app does not recognise — a new state added
        /// on the website before this build knew its name — used to throw out
        /// of the synthesized `Decodable` conformance. That failure propagated
        /// past this one row all the way to the array decode of a whole
        /// `/v1/my/library` page, which is why one odd entry stopped the
        /// entire library walk with a spinner nothing ever cleared.
        ///
        /// Falls back to `.considering` rather than adding an `.other(String)`
        /// case: this enum is `CaseIterable` and switched on exhaustively in
        /// `TasteLedger.swift` and `LibraryShape.swift`, both outside this
        /// batch, and an associated-value case would have needed a matching
        /// edit in each of them to keep compiling. `.considering` is the
        /// state closest to "unclassified" the app already has — it tracks no
        /// progress and counts as neither read nor abandoned in
        /// `ReadingInsights` — so an unrecognised row degrades to the
        /// vaguest bucket instead of aborting the page it arrived on.
        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = State(rawValue: raw) ?? .considering
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
    /// The `state` string exactly as it arrived, before the enum coerced an
    /// unrecognised value to `.considering`.
    ///
    /// Work-list 90: `State.init(from:)` deliberately degrades an unknown
    /// state rather than failing the row (see its comment), which is right for
    /// the screen and wrong for a backup — `LibraryExport` wrote the coerced
    /// value, so a file exported from a build that did not yet know a state
    /// said `considering`, and restoring it into an empty account wrote
    /// `considering`. Round-tripping into the *same* account was safe only
    /// because `changeSet` compares two equally-coerced values.
    ///
    /// Defaulted to the enum's own raw value, so every construction site that
    /// does not care — tests, `asSeries`, `applying` — reads as it did before.
    var rawState: String = ""

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
        /// Written to the disk cache only; the wire has no such key and
        /// `init(from:)` falls back to `state` for it.
        case rawState
    }
}

extension LibraryEntry {
    /// Hand-written for one field: `rawState` has to come from the *same*
    /// JSON value `state` does, which no synthesized conformance can express.
    /// In an extension, and delegating to the memberwise initialiser, so that
    /// initialiser is still synthesized — this type is built field by field in
    /// a great many places.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(Int.self, forKey: .id),
            seriesId: try container.decode(Int.self, forKey: .seriesId),
            state: try container.decode(State.self, forKey: .state),
            progressChapter: try container.decodeIfPresent(Double.self, forKey: .progressChapter),
            progressVolume: try container.decodeIfPresent(Double.self, forKey: .progressVolume),
            rating: try container.decodeIfPresent(Double.self, forKey: .rating),
            note: try container.decodeIfPresent(String.self, forKey: .note),
            startDate: try container.decodeIfPresent(Date.self, forKey: .startDate),
            finishDate: try container.decodeIfPresent(Date.self, forKey: .finishDate),
            numberOfRereads: try container.decodeIfPresent(Int.self, forKey: .numberOfRereads),
            priority: try container.decodeIfPresent(Int.self, forKey: .priority),
            isPrivate: try container.decodeIfPresent(Bool.self, forKey: .isPrivate),
            readLink: try container.decodeIfPresent(String.self, forKey: .readLink),
            series: try container.decodeIfPresent(Series.self, forKey: .series),
            // The disk cache round-trips its own key; the wire has only
            // `state`, whose string is exactly what this is for.
            rawState: try container.decodeIfPresent(String.self, forKey: .rawState)
                ?? container.decode(String.self, forKey: .state)
        )
    }

    /// The raw state if one was recorded, and the enum's own spelling
    /// otherwise — which is what every entry this app builds itself has.
    var exportedState: String { rawState.isEmpty ? state.rawValue : rawState }
}

extension LibraryEntry {
    /// This entry, with a write's change set applied — mirroring what the
    /// PATCH the change came from does on the server.
    ///
    /// Gap 88/j: a rating used to cost a full re-walk of the library (13
    /// requests, 24.7 MB on a real account) just to reflect one changed row.
    /// `LibrarySnapshot.apply(seriesId:change:)` uses this to patch the
    /// cached copy in place instead.
    ///
    /// The double-optional fields (`progressChapter`, `note`, …) carry
    /// `LibraryChange`'s own distinction straight through: `nil` means the
    /// reader never touched the field, so the existing value wins; `.some(x)`
    /// — including `.some(nil)` for an explicit clear — replaces it.
    func applying(_ change: LibraryChange) -> LibraryEntry {
        LibraryEntry(
            id: id,
            seriesId: seriesId,
            state: change.state ?? state,
            progressChapter: change.progressChapter ?? progressChapter,
            progressVolume: change.progressVolume ?? progressVolume,
            rating: change.rating ?? rating,
            note: change.note ?? note,
            startDate: startDate,
            finishDate: finishDate,
            numberOfRereads: numberOfRereads,
            priority: priority,
            isPrivate: change.isPrivate ?? isPrivate,
            readLink: readLink,
            series: series,
            // A change usually carries an enum, so a patched row's raw state
            // is that enum's spelling; only an untouched row keeps the
            // server's. `change.rawState` is the import's exception
            // (work-list 90) — a state this build cannot name, written back
            // verbatim, so the cached row matches what the server now holds
            // rather than the `.considering` the enum had to coerce it to.
            rawState: change.state == nil
                ? rawState
                : (change.rawState ?? change.state?.rawValue ?? rawState)
        )
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
