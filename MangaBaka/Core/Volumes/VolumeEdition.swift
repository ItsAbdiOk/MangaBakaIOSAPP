import Foundation

/// Which catalogue a volume's facts came from.
///
/// Separate from `ShelfVolume.Source`, which names the two *stores* a spine
/// can be bought in. A catalogue carries a date and an ISBN and sells
/// nothing, and the credit it is owed is a different obligation from Apple's
/// and Google's branding terms.
///
/// **The Grand Comics Database was going to be the second case here, and it
/// was measured out on 2026-09-14.** Three reasons, in the order they
/// arrived:
///
/// 1. Its one advantage was non-English print editions — German, Brazilian,
///    Swedish and Hungarian Solo Leveling, re-measured that day as 9 series
///    records across `de/pt/sv/hu/en`. Abdi scoped the app to English plus
///    the series' original language the same day, which removes every one of
///    those. Nothing in that sample was `ja` or `ko`.
/// 2. Inside English it is thinner than what we already have. GCD's
///    Delicious in Dungeon vol. 1 is `key_date: "2017-05-00"`, `isbn: ""`,
///    `on_sale_date: ""`; ANN has the same volume at 2017-05-23 with
///    ean 9780316471855, and MangaBaka's `/works` has it too.
/// 3. The access model rules out a per-series lookup anyway. **Three
///    `/api/series/name/` requests about four seconds apart got this IP
///    throttled for 33 minutes** — `429`,
///    `{"detail":"Request was throttled. Expected available in 1997
///    seconds."}` — and some responses during that window came back as
///    **HTTP 200 carrying an HTML "GCD :: Banned IP Notice" page**, not an
///    error status. A client written to treat 401/403 as "this source is
///    gone" would never have fired; it would have handed a decoder an HTML
///    page with a 200 beside it. `/api/issue/<id>/` kept answering through
///    the same window, so the throttle is on the search endpoint — the one a
///    per-series lookup cannot avoid.
///
/// Its licence is also still unread (`docs/sources/datasets.md` §4: every
/// comics.org page but `/api/` is Cloudflare-gated), which was the original
/// reason to ship it switched off. Any of the three above is on its own
/// enough. If it is ever revisited, the entry cost is a licence answer from
/// gcd-tech *and* a rate-limit number, and the shape below already has room
/// for a second case.
enum VolumeCatalogue: String, Codable, Sendable, CaseIterable {
    case animeNewsNetwork
    /// Open Library's editions API. Its rows arrive as `BookEdition` and are
    /// mapped in at the boundary by `BookEditionShelf` — `BookEdition` stays
    /// `OpenLibraryEditions`' own return type, because an edition list is a
    /// bibliographic record before it is a shelf row.
    case openLibrary
    /// The National Diet Library's SRU catalogue — the Japanese half, and the
    /// only source in the app that carries a volume before it is published.
    case nationalDietLibrary

    var displayName: String {
        switch self {
        case .animeNewsNetwork: "Anime News Network"
        case .openLibrary: "Open Library"
        case .nationalDietLibrary: "国立国会図書館サーチ"
        }
    }

    /// The `BookEdition.Source` this catalogue is, for the two that are one.
    ///
    /// Exists so `credit` below can *read* the obligation rather than restate
    /// it. Copying "Edition data from Open Library" into a second file is the
    /// duplication this project rejects outright: the terms are recorded on
    /// `BookEdition.Source.credit` and in `docs/licences.md`, and a view that
    /// showed a stale copy of a licence string would be showing the wrong
    /// credit, not merely an out-of-date one.
    var bookSource: BookEdition.Source? {
        switch self {
        case .animeNewsNetwork: nil
        case .openLibrary: .openLibrary
        case .nationalDietLibrary: .nationalDietLibrary
        }
    }

    /// The words a section showing this source's rows must carry.
    ///
    /// For ANN this is *not* sufficient on its own — see
    /// `requiresPerEntryLink`, which is an additional per-row obligation, not
    /// an alternative to this one.
    var credit: String {
        bookSource?.credit ?? "Volume data from \(displayName)"
    }

    /// Whether this source's terms require a link to **its own entry on every
    /// row**, not just its name somewhere on the page.
    ///
    /// ANN's API documentation, quoted in `docs/sources/publishers.md`
    /// (2026-09-14): list Anime News Network as the source of the data, and
    /// include a link to the relevant Encyclopedia entry on any page that
    /// displays their details.
    ///
    /// **What the view must show, exactly:** for every `EditionVolume` whose
    /// `edition.catalogue` is `.animeNewsNetwork`, the row renders
    /// `sourceLink` as a tappable link, and the section carries the words
    /// "Anime News Network" (`displayName`) as the source of the data. A
    /// footer credit alone does not satisfy it, and neither does one link per
    /// section. A row whose `sourceLink` is nil must not be drawn —
    /// `ANNEncyclopedia.volumes(in:)` drops those before they reach here, so
    /// it never happens, but the rule is the row's, not the parser's.
    var requiresPerEntryLink: Bool {
        switch self {
        case .animeNewsNetwork: true
        // Open Library and NDL both require credit and neither requires a
        // per-row backlink — `BookEdition.Source.credit` is what they oblige,
        // and the section carries it. Recorded as `false` rather than left to
        // a `default:` so a new case has to state its own answer.
        case .openLibrary, .nationalDietLibrary: false
        }
    }
}

/// What an edition's language is to *this* reader.
///
/// The view filters to English plus the original (Abdi, 2026-09-14), which is
/// the same rule `Series.coverLanguages` already applies to the cover fan —
/// and it is read from there rather than restated, so there is one place that
/// decides what "English plus the original" means. This says which of the two
/// a shelf is, because "English edition" and "Japanese edition" are different
/// headings and the view cannot tell them apart from a bare language code
/// without knowing the series.
enum EditionLanguageRole: String, Sendable, Equatable, Codable {
    case english
    case original
    /// Neither — reached only when the series states no language of its own,
    /// which is when `Series.coverLanguages` is nil and nothing is filtered.
    case other
}

// A `VolumeDate` was written here on 2026-09-14 and deleted the same day,
// unused: `PartialDate` in `Core/Editions` is the same type, arrived in the
// same round, and is the better one — it is `Comparable`, it reads Open
// Library's `Apr 07, 2021` long form as well as ISO, and it pins UTC for the
// reason a release date off a catalogue is not an instant in the reader's
// timezone. Two date-precision types in one app is the duplication this
// project does not allow, so this lane uses that one.

/// Print, digital, or a box set — the three things a catalogue row can be.
///
/// ANN writes this into the release title as a marker: `(GN 12)` is the print
/// graphic novel, `(eBook 12)` the digital edition of the same volume, and a
/// box set collects a range. Showing all three on one shelf reads as thirty
/// volumes where there are fifteen.
enum VolumeFormat: String, Sendable, Equatable, Codable {
    case print
    case digital
    case boxSet
    /// An artbook, a guidebook, a light novel beside the comic — carried
    /// rather than dropped so a caller can choose, but never a volume of the
    /// series itself.
    case other
}

/// One edition of a series: a source, a language, and the source's own name
/// for it.
///
/// A shelf groups by this rather than merging everything by volume number,
/// because two editions are different books with different ISBNs and
/// different dates, not two records of one book.
struct VolumeEdition: Hashable, Sendable, Codable, Identifiable {
    let catalogue: VolumeCatalogue
    /// Lowercased ISO 639-1 as the source states it.
    let language: String
    let languageRole: EditionLanguageRole
    /// The source's own name for this edition — ANN's `<manga name=…>`. Nil
    /// when the source has none.
    let editionTitle: String?

    var id: String { "\(catalogue.rawValue)-\(language)-\(editionTitle ?? "")" }
}

/// One volume, as one catalogue states it.
struct EditionVolume: Sendable, Equatable, Codable, Identifiable {
    /// Nil for a box set, which collects a range rather than being one
    /// number, and for the odd release a source numbers with a word.
    let number: Int?
    /// The source's own title for this release, e.g. "Delicious in Dungeon
    /// (GN 1)". Shown as-is or not at all; never re-derived.
    let title: String
    let releaseDate: PartialDate?
    /// ISBN-13, digits only. **A nil here means "the source did not state
    /// one", never "this book has no ISBN."**
    let isbn13: String?
    let format: VolumeFormat
    let edition: VolumeEdition
    /// The source's own entry for this row.
    ///
    /// **Non-nil for every `.animeNewsNetwork` volume, and the view must
    /// render it** — see `VolumeCatalogue.requiresPerEntryLink`.
    let sourceLink: URL?

    /// The *other* catalogues that described this same book, when more than one
    /// did. Empty for a row only one source stated.
    ///
    /// This is what makes the dedupe honest. `VolumeEditions.merge` collapses
    /// two sources' rows for one ISBN-13 into one row — otherwise a reader sees
    /// the same book twice — and the source that lost the collapse still said
    /// it, and is still owed its credit. Dropping the loser's name would be
    /// taking its data and crediting someone else.
    let alsoFrom: [VolumeCatalogue]

    /// Which catalogue's date `releaseDate` came from, when it was not this
    /// row's own.
    ///
    /// Merge prefers a full date over a partial one regardless of which source
    /// won the row (`docs/sources/bibliographic.md`, 2026-09-14: Open Library
    /// answers `2021-03-02`, `Apr 07, 2021` and a bare `2012` in one response,
    /// so "which source" and "how precise" are independent questions). Nil
    /// means the date is this row's catalogue's own.
    let dateFrom: VolumeCatalogue?

    /// Every catalogue that stands behind this row, the owner first. What a
    /// section's credit list is built from.
    var contributors: [VolumeCatalogue] { [edition.catalogue] + alsoFrom }

    var id: String { "\(edition.id)-\(isbn13 ?? title)" }

    /// `alsoFrom` and `dateFrom` default to "only one source said this", which
    /// is what every client produces before merge runs — written out because a
    /// `let` with a default value is left out of the synthesised memberwise
    /// init entirely.
    init(
        number: Int?,
        title: String,
        releaseDate: PartialDate?,
        isbn13: String?,
        format: VolumeFormat,
        edition: VolumeEdition,
        sourceLink: URL?,
        alsoFrom: [VolumeCatalogue] = [],
        dateFrom: VolumeCatalogue? = nil
    ) {
        self.number = number
        self.title = title
        self.releaseDate = releaseDate
        self.isbn13 = isbn13
        self.format = format
        self.edition = edition
        self.sourceLink = sourceLink
        self.alsoFrom = alsoFrom
        self.dateFrom = dateFrom
    }

    /// Written out rather than synthesised: the synthesis of `CodingKeys`
    /// depends on the compiler still deriving *one* of the two conformances,
    /// and a hand-written `init(from:)` beside a synthesised `encode(to:)` is
    /// a thing to state plainly rather than lean on.
    private enum CodingKeys: String, CodingKey {
        case number, title, releaseDate, isbn13, format, edition, sourceLink, alsoFrom, dateFrom
    }

    /// Decoded tolerantly for the two fields merge adds, so a cache written by
    /// a build before they existed is still readable. `ANNClient`'s key is
    /// bumped to `v2` as well — belt and braces, because the cost of getting
    /// this wrong is a week of a client answering nothing at all.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        number = try container.decodeIfPresent(Int.self, forKey: .number)
        title = try container.decode(String.self, forKey: .title)
        releaseDate = try container.decodeIfPresent(PartialDate.self, forKey: .releaseDate)
        isbn13 = try container.decodeIfPresent(String.self, forKey: .isbn13)
        format = try container.decode(VolumeFormat.self, forKey: .format)
        edition = try container.decode(VolumeEdition.self, forKey: .edition)
        sourceLink = try container.decodeIfPresent(URL.self, forKey: .sourceLink)
        alsoFrom = try container.decodeIfPresent([VolumeCatalogue].self, forKey: .alsoFrom) ?? []
        dateFrom = try container.decodeIfPresent(VolumeCatalogue.self, forKey: .dateFrom)
    }
}

/// What a source can say about the next volume.
///
/// **There is deliberately no case meaning "nothing is coming."** No source
/// surveyed can say that. ANN's encyclopedia is volunteer-edited: One Piece
/// has GN 113 dated 2026-11-10 because somebody entered it, and The
/// Apothecary Diaries stops at 2026-03-17 while the series is still running
/// in English because nobody has (`docs/sources/publishers.md`, 2026-09-14).
/// Both look identical on the wire. Putting the asymmetry in the type rather
/// than a comment is the point: a caller cannot render silence as an ending,
/// because there is no value that means one.
enum ForthcomingVolume: Sendable, Equatable {
    /// A publisher-announced date, from a source that stated it.
    case announced(EditionVolume)

    /// We do not know. Every non-answer lands here, and the reason is carried
    /// only so the screen can pick its words — none of them is "the series
    /// has finished".
    case unknown(UnknownReason)

    enum UnknownReason: Sendable, Equatable {
        /// The source answered and listed nothing dated ahead of today.
        case noneListed
        /// The source has no record of this series at all — either it
        /// answered `<warning>` for it, or MangaBaka holds no id to ask
        /// with. True of both Korean webtoons in the five-series set, and
        /// expected: ANN catalogues English-licensed print manga.
        case notCatalogued
        /// Nothing has been asked yet, or the ask is still in flight.
        case notAsked
        /// The request failed.
        case couldNotAsk(APIError)
    }
}

/// One edition's spines, ready for the shelf.
struct EditionShelf: Sendable, Equatable, Identifiable {
    let edition: VolumeEdition
    /// Sorted by volume number, unnumbered releases last.
    let volumes: [EditionVolume]

    var id: String { edition.id }

    /// The earliest volume in this edition dated after `now`, or why there
    /// isn't one. Never "nothing is coming" — see `ForthcomingVolume`.
    func forthcoming(asOf now: Date) -> ForthcomingVolume {
        let ahead = volumes
            .filter { $0.releaseDate?.isForthcoming(now: now) ?? false }
            .min { lhs, rhs in
                (lhs.releaseDate?.date ?? .distantFuture) < (rhs.releaseDate?.date ?? .distantFuture)
            }
        guard let ahead else { return .unknown(.noneListed) }
        return .announced(ahead)
    }
}

/// The whole answer the volumes shelf consumes.
///
/// **This is the API the detail lane wires to.** It is built by
/// `VolumeEditions.merge(ann:for:)` and nothing else; the client is never
/// called from a view.
struct VolumeEditionAnswer: Sendable, Equatable {
    /// Grouped by edition, fullest first, so the shelf's default tab is the
    /// one with the most spines on it.
    let shelves: [EditionShelf]
    /// The sources that actually put a row on screen, and therefore the ones
    /// owed a credit. Empty when `shelves` is empty — a credit for a source
    /// that contributed nothing is noise. Read
    /// `VolumeCatalogue.requiresPerEntryLink` for what each one obliges.
    let credits: [VolumeCatalogue]
    /// Why a leg is missing, when one is. Keyed by source so a section can
    /// show `InlineFailure` for the leg that failed while another renders.
    let failures: [VolumeCatalogue: APIError]
    /// Set when no shelf could be built at all, so `forthcoming(asOf:)` can
    /// say which kind of nothing this is. Nil once there is a shelf to read.
    let unaskedReason: ForthcomingVolume.UnknownReason?

    var isEmpty: Bool { shelves.isEmpty }

    /// Nothing asked yet. `unaskedReason: .notAsked` rather than nil, so a view
    /// holding this before its legs have run says "we haven't looked" and not
    /// the weaker "nobody listed one" — which is the distinction
    /// `ForthcomingVolume.UnknownReason` exists to keep.
    static let empty = VolumeEditionAnswer(
        shelves: [], credits: [], failures: [:], unaskedReason: .notAsked
    )

    /// The soonest announced volume across every shelf, or why there isn't
    /// one.
    ///
    /// **Never "nothing is coming."** Read `ForthcomingVolume` before writing
    /// any copy against this: `.unknown(.noneListed)` is the case a series
    /// that has genuinely ended and a series nobody has entered a date for
    /// both land in, and no source surveyed can tell those apart.
    func forthcoming(asOf now: Date) -> ForthcomingVolume {
        if let unaskedReason { return .unknown(unaskedReason) }
        let announced = shelves.compactMap { shelf -> EditionVolume? in
            guard case let .announced(volume) = shelf.forthcoming(asOf: now) else { return nil }
            return volume
        }
        guard let soonest = announced.min(by: { lhs, rhs in
            (lhs.releaseDate?.date ?? .distantFuture) < (rhs.releaseDate?.date ?? .distantFuture)
        }) else { return .unknown(.noneListed) }
        return .announced(soonest)
    }
}
