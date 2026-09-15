import Foundation
import NaturalLanguage

/// One volume of a series as sold on Apple Books: the cover, the price, and
/// the link to buy it.
///
/// Apple Books is the destination because these are iOS readers (Abdi,
/// 2026-09-11); Google Books is data only. The iTunes Search API is public,
/// keyless, and answers with one result per volume sold, 600px art, and a
/// store link — which for the series it carries is the whole of roadmap
/// item 4 in one request. MangaBaka's own `/images` is too sparse to lead
/// with: ONE PIECE has 4 English volume covers there, of 115.
struct AppleBooksVolume: Codable, Identifiable, Sendable, Equatable {
    /// Apple's track id.
    let id: Int
    let number: Int
    let title: String
    let artworkURL: URL?
    let storeURL: URL?
    let price: Double?
    /// "£6.99", in the store's own formatting.
    let formattedPrice: String?
    /// Raw, undecoded ("2021-02-16T08:00:00Z" or a fractional-second
    /// variant) and unread by anything on screen — kept as a string on
    /// purpose. A strict `.iso8601` `Date` here sank the whole 200-row
    /// answer for one odd row (T9, 2026-09-13); nothing reads this field,
    /// so nothing should be able to fail decoding it.
    let releaseDate: String?

    var cover: Cover {
        Cover(raw: artworkURL, x150: nil, x250: nil, x350: nil, blurhash: nil, width: nil, height: nil)
    }

    /// This volume as a gallery entry, so the store's covers can sit in the
    /// same fan and the same full-screen gallery as MangaBaka's own.
    ///
    /// Apple is the fuller source for most series and that is the whole reason
    /// it leads: ONE PIECE has 4 English volume covers on MangaBaka's
    /// `/images`, of 115, while the store sells every volume it carries with
    /// official art. Nil when the store sent no artwork — a gallery page that
    /// is a grey rectangle is worse than one fewer page.
    ///
    /// Typed "volume" and captioned by number, which is what it is. The entry
    /// does not say "Apple Books" on it; the volumes shelf further down the
    /// page is where the store is named and linked.
    var galleryImage: SeriesImage? {
        guard artworkURL != nil else { return nil }
        return SeriesImage(
            imageID: nil,
            seriesId: nil,
            type: "volume",
            index: String(number),
            indexNumeric: Double(number),
            language: nil,
            contentRating: nil,
            image: cover,
            workId: nil,
            note: nil
        )
    }
}

/// One row of the iTunes Search API's answer, as it arrives.
struct AppleBooksResult: Decodable, Sendable, Equatable {
    let trackId: Int
    let trackName: String
    /// Who the store credits. The publisher's edition credits the author;
    /// a translated edition often credits the translator instead.
    let artistName: String?
    /// The blurb. Not shown; its language is what tells a French edition
    /// from an English one, since nothing else in the result does.
    let description: String?
    let artworkUrl100: URL?
    let trackViewUrl: URL?
    let price: Double?
    let formattedPrice: String?
    /// String, not `Date` — see `AppleBooksVolume.releaseDate`.
    let releaseDate: String?
}

/// Which results are volumes of *this* series, and nothing else.
///
/// Strict on purpose: a wrong cover under "Volume 3" is worse than an empty
/// spine. The result's name must be the series' title — or one of its other
/// titles — followed directly by a volume marker: "Solo Leveling, Vol. 8
/// (comic)". "Solo Leveling: Ragnarok, Vol. 1" is a different series and is
/// rejected because ": Ragnarok" sits between the title and the marker. The
/// "(novel)" editions Yen Press sells beside the comic are rejected unless
/// the series is itself a novel. Verified against the live answer for
/// "solo leveling" in the GB store, 2026-09-11: 60 results, 15 comic volumes
/// plus novels and Ragnarok.
enum AppleBooksMatch {
    /// One volume per number — the first result for it, which the store
    /// ranks by relevance — sorted by number.
    ///
    /// The store's credit must name one of the series' creators, when the
    /// series has any. HUNTER×HUNTER's GB store answer is "Hunter ✖ Hunter -
    /// Volume 1" credited to Baptiste Peyron — the French edition, sold in
    /// every store, and the search results carry no language field to say
    /// so. VIZ credits "Eiichiro Oda", Yen Press "Chugong, …"; the French
    /// edition credits its translator. A surname is enough: MangaBaka spells
    /// it "Eiichirou Oda", the store "Eiichiro Oda".
    static func volumes(
        in results: [AppleBooksResult],
        titles: [String],
        creators: [String] = [],
        isNovel: Bool,
        language: String? = nil,
        numbering: Numbering = .marker
    ) -> [AppleBooksVolume] {
        let surnames = creators.compactMap { $0.split(separator: " ").last.map { normalise(String($0)) } }
            .filter { $0.count >= 3 }
        let matched = matchedVolumes(
            in: results, nameOf: \.trackName, titles: titles, isNovel: isNovel, numbering: numbering
        ) { result, _ in
            if !surnames.isEmpty {
                let credit = normalise(result.artistName ?? "")
                guard surnames.contains(where: { credit.contains($0) }) else { return false }
            }
            if let language, let blurb = languageOf(result.description), blurb != language { return false }
            return true
        }
        return matched.map { entry in
            AppleBooksVolume(
                id: entry.item.trackId,
                number: entry.parts.number,
                title: entry.item.trackName,
                artworkURL: entry.item.artworkUrl100.flatMap(enlarge),
                storeURL: entry.item.trackViewUrl.flatMap(SafeLink.web),
                price: entry.item.price,
                formattedPrice: entry.item.formattedPrice,
                releaseDate: entry.item.releaseDate
            )
        }.sorted { $0.number < $1.number }
    }

    /// One item ranked and matched to a volume number, before its store
    /// builds a volume out of it. Shared so a rule fixed on one catalogue
    /// (Apple's) is fixed on every catalogue that reuses this (Google's) —
    /// T3/F15, 2026-09-13.
    struct Matched<Item> {
        let item: Item
        let parts: Parts
    }

    /// The shared matcher behind both `AppleBooksMatch.volumes` and
    /// `GoogleBooksMatch.volumes`: title match, tagged-editions-first
    /// ranking, one volume per number, and the untagged-gap-filler guard
    /// (T4). `extraFilter` is where a store's own checks (creator credit,
    /// blurb language, catalogue language) plug in.
    static func matchedVolumes<Item>(
        in items: [Item],
        nameOf: (Item) -> String,
        titles: [String],
        isNovel: Bool,
        numbering: Numbering = .marker,
        extraFilter: (Item, Parts) -> Bool = { _, _ in true }
    ) -> [Matched<Item>] {
        let wanted = Set(titles.map(normalise).filter { !$0.isEmpty })
        guard !wanted.isEmpty else { return [] }
        // Two passes, tagged editions first. Store relevance order put "The
        // Apothecary Diaries: Volume 1" (the light novel, untagged) ahead of
        // "The Apothecary Diaries 01 (Manga)", so first-seen-wins showed the
        // novel's cover on the comic's shelf (Abdi's phone, 2026-09-13). An
        // edition that says what it is outranks one that does not.
        let ranked = items.enumerated().sorted { lhs, rhs in
            let lhsTagged = isTagged(nameOf(lhs.element), numbering)
            let rhsTagged = isTagged(nameOf(rhs.element), numbering)
            return lhsTagged != rhsTagged ? lhsTagged : lhs.offset < rhs.offset
        }.map(\.element)
        var byNumber: [Int: Matched<Item>] = [:]
        // Set only while building the comic shelf (`isNovel == false`): an
        // untagged row is normally a light novel's own bare early numbering
        // (J-Novel Club tags only from volume 7 on; 1-6 are bare "Volume N"),
        // so once the comic shelf has a tagged edition of its own, an
        // untagged row must not fill a number the comic hasn't reached
        // (T4). The novel shelf keeps accepting its own untagged rows —
        // that bare numbering is the normal case there, not the leak.
        // Marker numbering only: in the Japanese store a "tag" is an edition
        // word (モノクロ版), and "ONE PIECE 2" without one is the same comic,
        // not a novel leaking in.
        var comicShelfHasTaggedEdition = false
        for item in ranked {
            let name = nameOf(item)
            guard let parts = split(name, numbering: numbering), wanted.contains(normalise(parts.title))
            else { continue }
            if let tag = parts.tag {
                guard isNovelTag(tag) == isNovel else { continue }
                if !isNovel { comicShelfHasTaggedEdition = true }
            } else if !isNovel && comicShelfHasTaggedEdition && numbering == .marker {
                continue
            }
            guard extraFilter(item, parts) else { continue }
            guard byNumber[parts.number] == nil else { continue }
            byNumber[parts.number] = Matched(item: item, parts: parts)
        }
        return byNumber.values.sorted { $0.parts.number < $1.parts.number }
    }

    private static func isTagged(_ name: String, _ numbering: Numbering) -> Bool {
        split(name, numbering: numbering)?.tag != nil
    }

    /// "(novel)", "(Light Novel)" → a novel; "(comic)", "(Manga)",
    /// "(Graphic Novel)" → not (T8/F5: "novel" alone is not enough).
    static func isNovelTag(_ tag: String) -> Bool { tag.contains("novel") && !tag.contains("graphic") }

    struct Parts: Equatable {
        let title: String
        let number: Int
        /// Whatever sits in trailing brackets, lowercased: "comic", "novel".
        let tag: String?
    }

    /// How a store writes a volume number.
    enum Numbering {
        /// "Solo Leveling, Vol. 8 (comic)": a marker before the number. The
        /// English-language stores.
        case marker
        /// "ONE PIECE モノクロ版 115": the title, an edition word, and the
        /// bare number. The Japanese store (verified 2026-09-11 on 377).
        /// Looser, so only used there, and only for the Japanese edition.
        case bare
    }

    /// "Solo Leveling, Vol. 8 (comic)" → ("Solo Leveling", 8, "comic").
    /// The marker may be "Vol.", "Vol", "Volume" or "#" — or absent when a
    /// bracketed kind follows the number: Square Enix's "The Apothecary
    /// Diaries 01 (Manga)" (GB store, 2026-09-13). The bracket is what
    /// makes a bare number safe to read as a volume; "Kingdom 2" alone
    /// could be a sequel's title. The kind bracket may also come *before*
    /// the marker — Seven Seas' "Mushoku Tensei: Jobless Reincarnation
    /// (Manga) Vol. 1" (GB store, 2026-09-13) — and the store may append a
    /// subtitle after the number, dropped rather than parsed: VIZ's
    /// "Naruto, Vol. 1: Uzumaki Naruto" (F3).
    static func split(_ name: String, numbering: Numbering = .marker) -> Parts? {
        switch numbering {
        case .marker:
            guard let match = name.wholeMatch(of: pattern) else { return nil }
            guard let digits = match.output.3 ?? match.output.4, let number = Int(digits) else { return nil }
            let tag = (match.output.2 ?? match.output.5).map { $0.lowercased() }
            return Parts(title: String(match.output.1), number: number, tag: tag)
        case .bare:
            guard let match = name.wholeMatch(of: barePattern) else { return nil }
            guard let digits = match.output.3 ?? match.output.4, let number = Int(digits) else { return nil }
            return Parts(title: String(match.output.1), number: number, tag: match.output.2.map(String.init))
        }
    }

    // Built per call: a Regex is not Sendable, so it cannot be a static
    // constant. Cheap enough — the store answers at most 200 names.
    // swiftlint:disable:next large_tuple
    private static var barePattern: Regex<(Substring, Substring, Substring?, Substring?, Substring?)> {
        // Title, an optional edition word (モノクロ版 monochrome, カラー版
        // colour, 新装版 new edition, 完全版 complete), then a bare number —
        // Shueisha's "呪術廻戦 30". Or, with no edition word, the number in
        // parentheses (half- or full-width): Kodansha's "進撃の巨人 (1)" and
        // "進撃の巨人(34)" — 0 of 34 Attack on Titan volumes matched the
        // whitespace-then-bare-digits shape alone (T1, 2026-09-13; the
        // fixture at the time was ONE PIECE, Shueisha's shape only).
        /^(.+?)(?:\s+(?:(モノクロ版|カラー版|新装版|完全版)\s*)?(\d+)|\s*[（(](\d+)[)）])\s*$/
    }

    private static var pattern: PatternMatch {
        // 1 title, 2 a kind bracket before the marker (Seven Seas), 3/4 the
        // number (marker word or bare-before-bracket), 5 a kind bracket
        // after the number (the common case), and a trailing "[,:] subtitle"
        // dropped rather than captured — VIZ's "Naruto, Vol. 1: Uzumaki
        // Naruto" (F3, 2026-09-13). The bracket before the marker may be
        // followed by a comma: Ize Press's "Omniscient Reader's Viewpoint
        // (novel), Vol. 1" (live GB/US store, 2026-09-15) — without it the
        // lazy title swallowed "(novel)" and the novel's own page showed no
        // volumes at all.
        // swiftlint:disable:next line_length
        /^(.+?)[,:]?\s+(?:\(([^)]+)\)[,:]?\s+)?(?:(?:vol\.?|volume|#)\s*(\d+)|(\d+)(?=\s*\())\s*(?:\(([^)]+)\))?(?:[,:]\s*.+)?\s*$/
            .ignoresCase()
    }

    // swiftlint:disable large_tuple
    private typealias PatternMatch =
        Regex<(Substring, Substring, Substring?, Substring?, Substring?, Substring?)>
    // swiftlint:enable large_tuple

    /// The language a blurb is written in, as a primary subtag ("fr"), or
    /// nil when there is no blurb or the recogniser is not sure.
    ///
    /// On-device, no network. The store's results carry no language field,
    /// and the Hunter ✖ Hunter listing that reached a UK phone was French
    /// from its first sentence ("Parmi les mangas shōnen à succès…"). Only a
    /// confident answer is used: a blurb that is one title and a number is
    /// not evidence of anything, and must not reject a real volume.
    static func languageOf(_ text: String?) -> String? {
        guard let text, text.count >= 40 else { return nil }
        let recogniser = NLLanguageRecognizer()
        recogniser.processString(String(text.prefix(400)))
        guard let (language, confidence) = recogniser.languageHypotheses(withMaximum: 1).first,
              confidence >= 0.8
        else { return nil }
        return language.rawValue.split(separator: "-").first.map(String.init)
    }

    /// Case, punctuation and spacing do not make two titles different, and
    /// neither does the cross: MangaBaka writes HUNTER×HUNTER, the store
    /// "Hunter ✖ Hunter" or "Hunter x Hunter".
    static func normalise(_ title: String) -> String {
        title.lowercased()
            .replacing(/[×✖✕✗]/, with: "x")
            .filter { $0.isLetter || $0.isNumber }
    }

    /// The API hands back 100×100 art; the same path serves 600×600.
    /// Undocumented but long-standing, and the 100px fallback still loads if
    /// it ever stops.
    static func enlarge(_ url: URL) -> URL? {
        URL(string: url.absoluteString.replacingOccurrences(of: "100x100bb", with: "600x600bb"))
    }
}
