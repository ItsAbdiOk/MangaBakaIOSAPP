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

    var displayName: String {
        switch self {
        case .animeNewsNetwork: "Anime News Network"
        }
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

    var id: String { "\(edition.id)-\(isbn13 ?? title)" }
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

/// Turns a client's answer into the shelf's.
enum VolumeEditions {
    /// - Parameters:
    ///   - ann: `ANNClient.volumes(for:)`'s answer. `.idle` when the series
    ///     carries no ANN id to ask with, which is a real and common state —
    ///     not an error, and not an empty shelf either.
    ///   - series: read for `coverLanguages` (the existing "English plus the
    ///     original" rule) and for the native language the roles are tagged
    ///     against. Passing the series rather than two strings keeps that
    ///     rule in one place.
    static func merge(ann: Fetched<ANNVolumes>, for series: Series) -> VolumeEditionAnswer {
        let shown = series.coverLanguages
        let visible = (ann.value?.volumes ?? []).filter { volume in
            shown.map { $0.contains(volume.edition.language.lowercased()) } ?? true
        }
        var grouped: [VolumeEdition: [EditionVolume]] = [:]
        for volume in visible { grouped[volume.edition, default: []].append(volume) }

        // Built in two named steps with explicit types: chaining `map` into
        // `sorted` with a ternary inside the comparator is what the type
        // checker gave up on ("unable to type-check in reasonable time",
        // 2026-09-14).
        let unsorted: [EditionShelf] = grouped.map { edition, volumes in
            EditionShelf(edition: edition, volumes: volumes.sorted(by: byNumber))
        }
        let shelves: [EditionShelf] = unsorted.sorted { lhs, rhs in
            if lhs.volumes.count != rhs.volumes.count {
                return lhs.volumes.count > rhs.volumes.count
            }
            return lhs.id < rhs.id
        }
        var failures: [VolumeCatalogue: APIError] = [:]
        if let error = ann.error { failures[.animeNewsNetwork] = error }
        // Each step named rather than nested: as one expression the type
        // checker gave up outright ("unable to type-check in reasonable
        // time"), 2026-09-14 — the same shape that defeated it in
        // `SeriesImage.stableID`.
        let present: Set<VolumeCatalogue> = Set(shelves.map { $0.edition.catalogue })
        let credits: [VolumeCatalogue] = VolumeCatalogue.allCases.filter { present.contains($0) }
        let reason: ForthcomingVolume.UnknownReason? = shelves.isEmpty ? unasked(ann) : nil
        return VolumeEditionAnswer(
            shelves: shelves,
            credits: credits,
            failures: failures,
            unaskedReason: reason
        )
    }

    /// Which kind of nothing an empty answer is.
    ///
    /// A filtered-out shelf (ANN answered with English volumes for a series
    /// whose shown languages somehow exclude "en") lands on `.noneListed`
    /// rather than `.notCatalogued`, because ANN did have a record — the app
    /// chose not to show it.
    private static func unasked(_ ann: Fetched<ANNVolumes>) -> ForthcomingVolume.UnknownReason {
        switch ann {
        case .idle, .loading: .notAsked
        case let .failed(error, _): .couldNotAsk(error)
        case let .loaded(value, _, _): value.isCatalogued ? .noneListed : .notCatalogued
        }
    }

    /// Which of "English" and "the original" a language code is, for this
    /// series.
    ///
    /// English wins a tie. An English-original series (`type: "oel"`) has no
    /// implied language and `nativeLanguage` is usually absent, so it never
    /// reaches the tie anyway — but a series that did carry `en` as native
    /// should read as the English edition, which is the heading a reader
    /// recognises.
    ///
    /// `nonisolated static` so `ANNClient` can tag an edition without
    /// building a shelf, and so the tests can reach it directly.
    nonisolated static func role(of language: String, in series: Series) -> EditionLanguageRole {
        let code = language.lowercased()
        if code == "en" { return .english }
        let own = (series.nativeLanguage ?? series.impliedLanguage)?.lowercased()
        return code == own ? .original : .other
    }

    /// Unnumbered releases — box sets, mostly — sort after every numbered one
    /// rather than to the front, which is where a nil-as-zero sort would put
    /// them.
    private static func byNumber(_ lhs: EditionVolume, _ rhs: EditionVolume) -> Bool {
        (lhs.number ?? Int.max, lhs.title) < (rhs.number ?? Int.max, rhs.title)
    }
}
