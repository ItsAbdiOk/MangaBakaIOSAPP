import Foundation

/// Every language's printing of one volume, from Open Library's editions API.
///
/// This is the multi-language edition coverage that went out of the door with
/// Google Books, from an endpoint the app already talks to for covers.
/// Measured live 2026-09-14 — one anchor ISBN, two requests, three editions
/// including a French one we had no other route to:
///
/// ```
/// GET /isbn/9781975319434.json      → 302 → /books/OL32184952M.json
///     works: [/works/OL19921538W]
/// GET /works/OL19921538W/editions.json?limit=50   → size 3
///   Solo Leveling, Vol. 1 | 2021-03-02   | 9781975319434 | Yen Press | eng | cover 10839422
///   Solo Leveling T01     | Apr 07, 2021 | 9782382880296 | KBOOKS    | —   | cover 10692670
///   Solo leveling         | 2012         | —             | unknown   | —   | —
/// ```
///
/// ## Why the lookup starts at an ISBN and never at a title
///
/// Title search is the obvious route and it is a trap. `search.json` matches
/// loosely and Open Library's `form:manga` / `form:light novel` subject tags
/// cannot repair it: Solo Leveling is **0 of 100** documents tagged, and The
/// Apothecary Diaries returns **16** tagged light novels next to **21**
/// untagged documents that are the manga volumes *and* some novels, mixed
/// (measured, `docs/sources/bibliographic.md`, 2026-09-14). A title search
/// filtered on `form:` puts light novels on the comic shelf, which is the
/// Apple Books failure this app already had once.
///
/// So the path is an identity, not a guess: **MangaBaka's own
/// `/v1/series/{id}/works` already holds the volume's ISBN, and an ISBN names
/// exactly one printing.** `/isbn/{isbn}.json` turns that into the one work
/// Open Library filed it under, and the editions under that work are siblings
/// of a printing we know is this series. No string matching happens anywhere
/// in this file. The format comes with the anchor — see `BookEdition.
/// FormatEvidence` for why nothing here reads a `form:` tag, and note that
/// neither endpoint used here even returns a `subject` field (checked in the
/// same measurement), so the tag cannot leak in by accident.
///
/// The cost is that a series with no ISBN in MangaBaka's works list gets no
/// answer at all. That is the right failure: nothing shown beats the wrong
/// book shown. It is also why the anchor must come from MangaBaka rather than
/// from anywhere else — measured 2026-09-14, feeding this a plausible-looking
/// but wrong ISBN for The Apothecary Diaries (9781646090679) returned a
/// perfectly coherent answer for *Beauty and the Feast*. A bad anchor does not
/// fail; it lies.
///
/// ## What survives the language filter — measured 2026-09-14
///
/// The app shows English and the series' original language, never a third, so
/// `editions(anchorISBN:originalLanguage:)` drops everything else before it
/// returns. One request per series against the live API, anchored on a
/// MangaBaka ISBN:
///
/// ```
/// Series (original)          editions  after filter  what the filter kept
/// Solo Leveling (kor)            3          1        the anchor only — no Korean edition exists here
/// One Piece (jpn)               18          7        6 English printings + the Shueisha original
/// Delicious in Dungeon (jpn)     5          3        2 English + ダンジョン飯 1 (9784047301535)
/// TBATE (eng)                    1          1        the anchor only
/// ```
///
/// **The negative result worth stating:** for a series whose English rights
/// sit with one publisher, this endpoint adds nothing — Solo Leveling and
/// TBATE came back holding only the row we started from. It earns its place on
/// long-running series, where the extra English printings are real ones
/// MangaBaka's own works list does not carry (One Piece: Viz, Tandem Library,
/// Selbite editions of volume 1) and where the original-language row arrives
/// with an ISBN and a date.
///
/// **Korean is not here.** Solo Leveling's work holds an English, a French and
/// an untyped edition, and no Korean one. Korean print volumes remain
/// unsourced — the National Library of Korea is the only route found and it
/// was rejected for requiring a shipped key (`docs/sources/bibliographic.md`).
actor OpenLibraryEditions {
    /// 4 seconds, raised from the 3 `OpenLibraryCovers` uses, because the
    /// research figure was measured again on 2026-09-14 and came out worse:
    /// twelve requests spaced 4 s apart over about two minutes ended with
    /// openlibrary.org refusing TCP connections outright (`Failed to connect
    /// … after 75008 ms`), and a `urllib` client at 3 s gaps was reset by peer
    /// on every one of five calls while `curl` at the same spacing succeeded.
    /// The documented limit is 1 req/s; the observed ceiling is far below it
    /// and is not purely time-based.
    ///
    /// **A caveat this actor cannot fix on its own:** `OpenLibraryCovers` is a
    /// separate actor with its own `RequestSpacing`, so the two can still put
    /// two requests on the same host inside one gap. A host-level gate shared
    /// by both is the real fix and belongs with whoever owns `Core/Volumes`.
    static let minimumInterval: TimeInterval = 4.0
    /// A GUESS, and deliberately long: an edition list changes when a
    /// publisher licenses a new translation, which is a thing that happens
    /// perhaps twice a year per series, not daily. A week keeps a new French
    /// printing at most seven days late while costing two requests a week per
    /// series on a host that resets connections at 1.5 s.
    static let cacheLife: TimeInterval = 7 * 24 * 3600
    /// One page, one request. Measured `size` was 3 for Solo Leveling, but
    /// One Piece has 1403 documents in search; a series whose work carries
    /// more printings than this shows the first 50 rather than paging, and a
    /// view must not present the list as exhaustive.
    static let pageSize = 50

    private let session: URLSession
    private let clock: any Clock
    private let cacheDirectory: URL?
    private var spacing: RequestSpacing

    /// - Parameter minimumInterval: injectable only because one lookup makes
    ///   **two** sequential requests, so a test of the happy path would
    ///   otherwise sleep for a real `minimumInterval` between them. The sleep
    ///   is `Task.sleep`, which the injected `clock` cannot fast-forward.
    init(
        session: URLSession = ThirdPartySession.shared,
        clock: any Clock = SystemClock(),
        minimumInterval: TimeInterval = OpenLibraryEditions.minimumInterval,
        cacheDirectory: URL? = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("openlibrary-editions", isDirectory: true)
    ) {
        self.session = session
        self.clock = clock
        self.cacheDirectory = cacheDirectory
        spacing = RequestSpacing(minimumInterval: minimumInterval)
    }

    /// Every printing Open Library files under the same work as this ISBN.
    ///
    /// - Parameters:
    ///   - anchorISBN: an ISBN-10 or -13 for a volume of this series, from
    ///     MangaBaka's own works list. Digits and hyphens are both accepted;
    ///     hyphens are stripped because NDL answers hyphenated ISBNs and Open
    ///     Library's path does not accept them.
    ///   - originalLanguage: the series' own language as ISO 639-2/B
    ///     (`jpn`, `kor`), or nil when MangaBaka does not say. Rows in any
    ///     language other than this and English are dropped here rather than
    ///     handed on — the app shows two languages and a view that had to
    ///     filter them itself would be a second place to get it wrong.
    ///   - knownFormat: what MangaBaka already says this series is. Inherited
    ///     by every row, since they are printings of the same work. Pass
    ///     `.unknown` and every row says `.unknown` — no field in either
    ///     response is treated as a format signal.
    /// - Returns: `.notCatalogued` when Open Library has no record of the
    ///   ISBN or of a work behind it. That is "we asked and they don't know",
    ///   which is not "this series has no other editions". An *empty*
    ///   `.editions` is the other real answer: the work exists and nothing in
    ///   it was in a language this app shows.
    func editions(
        anchorISBN: String,
        originalLanguage: String? = nil,
        knownFormat: BookEdition.Format = .unknown
    ) async throws(APIError) -> EditionAnswer {
        let isbn = Self.normalise(anchorISBN)
        guard !isbn.isEmpty else { return .notCatalogued }
        let key = "v2-\(isbn)-\(originalLanguage ?? "none")-\(knownFormat.rawValue)"
        if let cached = readCache(key) { return cached }

        guard let workKey = try await workKey(isbn: isbn) else {
            writeCache(key, .notCatalogued)
            return .notCatalogued
        }
        guard let entries = try await entries(workKey: workKey) else {
            writeCache(key, .notCatalogued)
            return .notCatalogued
        }

        let evidence: BookEdition.FormatEvidence =
            knownFormat == .unknown ? .unstated : .anchorISBN(isbn)
        let rows = entries
            .map { $0.row(format: knownFormat, evidence: evidence) }
            .filter { Self.isShown($0, originalLanguage: originalLanguage) }
        let answer = EditionAnswer.editions(rows)
        writeCache(key, answer)
        return answer
    }

    /// English, or the series' own language. Everything else goes.
    ///
    /// **A row whose language Open Library did not state is dropped**, and
    /// that is the deliberate part. Measured 2026-09-14, the rows with an
    /// empty `languages` array were the French Solo Leveling (KBOOKS), a
    /// Spanish One Piece (LARP Editores) and a French one (Glénat) — the
    /// language is missing precisely on the editions this filter exists to
    /// remove, so keeping unstated rows would defeat it. The cost is that a
    /// genuine English or Japanese printing with no language field is lost
    /// too; that is a row we cannot honestly place, and guessing it from the
    /// publisher's country is exactly the inference the brief ruled out.
    static func isShown(_ row: BookEdition, originalLanguage: String?) -> Bool {
        guard let language = row.language else { return false }
        return language == "eng" || language == originalLanguage
    }

    /// Hyphens out, upper-cased (an ISBN-10 can end in `X`), whitespace
    /// trimmed. Nothing else — this string goes into a URL path, so anything
    /// that is not an ISBN character is dropped rather than escaped and sent.
    static func normalise(_ isbn: String) -> String {
        isbn.uppercased().filter { $0.isNumber || $0 == "X" }
    }

    // MARK: - The two requests

    /// `/isbn/{isbn}.json` → the work key, or nil when Open Library has no
    /// such ISBN.
    ///
    /// Measured 2026-09-14: this endpoint answers **302** to
    /// `/books/{edition}.json`, not 200. `URLSession` follows that by default,
    /// which is why nothing here handles a redirect — recorded because a
    /// `curl` without `-L` returns an empty body and looks like a dead API.
    private func workKey(isbn: String) async throws(APIError) -> String? {
        guard let url = URL(string: "https://openlibrary.org/isbn/\(isbn).json") else { return nil }
        guard let data = try await load(url) else { return nil }
        guard let edition = try? JSONDecoder().decode(EditionDocument.self, from: data) else {
            throw .decoding(underlying: "Open Library edition did not parse.", party: .openLibrary)
        }
        return edition.works?.first?.key
    }

    /// `/works/{id}/editions.json` → the sibling printings.
    private func entries(workKey: String) async throws(APIError) -> [EditionDocument]? {
        let trimmed = workKey.hasPrefix("/") ? String(workKey.dropFirst()) : workKey
        var components = URLComponents(string: "https://openlibrary.org/\(trimmed)/editions.json")
        components?.queryItems = [URLQueryItem(name: "limit", value: String(Self.pageSize))]
        guard let url = components?.url else { return nil }
        guard let data = try await load(url) else { return nil }
        guard let list = try? JSONDecoder().decode(EditionList.self, from: data) else {
            throw .decoding(underlying: "Open Library editions did not parse.", party: .openLibrary)
        }
        return list.entries
    }

    /// - Returns: the body, or nil for a 404 — which is an answer here, not a
    ///   failure. Every other non-2xx throws.
    private func load(_ url: URL) async throws(APIError) -> Data? {
        let wait = spacing.claim(now: clock.now)
        if wait > 0 {
            try? await Task.sleep(for: .seconds(wait))
            // Gap 28, as in `OpenLibraryCovers.coverURL`: `try?` alone
            // swallows cancellation and would spend the request the
            // cancelled wait already claimed a slot for.
            guard !Task.isCancelled else { throw .cancelled }
        }

        let received: (data: Data, response: URLResponse)
        do {
            received = try await session.data(from: url)
        } catch let error {
            if (error as? URLError)?.code == .cancelled { throw .cancelled }
            throw .transport(underlying: "Open Library request failed.", party: .openLibrary)
        }
        guard let http = received.response as? HTTPURLResponse else {
            throw .transport(underlying: "Open Library sent a non-HTTP response.", party: .openLibrary)
        }
        if http.statusCode == 404 { return nil }
        if http.statusCode == 429 {
            // Parsed and clamped in one place (`RequestSpacing.backOff`), the
            // same as every other client — a bare `TimeInterval.init` accepted
            // "nan" and ended a client's spacing for the process.
            let retryAfter = spacing.backOff(
                retryAfterHeader: http.value(forHTTPHeaderField: "Retry-After"), now: clock.now
            )
            throw .rateLimited(retryAfter: retryAfter, party: .openLibrary)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw .server(
                status: http.statusCode,
                message: "Open Library returned \(http.statusCode).", party: .openLibrary
            )
        }
        return received.data
    }

    // MARK: - Wire shapes

    private struct EditionList: Decodable {
        let entries: [EditionDocument]?
    }

    /// The fields of an Open Library edition document this app reads. The
    /// real document carries 25 keys (measured 2026-09-14); the rest —
    /// `source_records`, `lc_classifications`, revision bookkeeping — are
    /// deliberately not decoded.
    private struct EditionDocument: Decodable {
        struct Reference: Decodable { let key: String? }

        let key: String?
        let title: String?
        let works: [Reference]?
        let isbn13: [String]?
        let publishers: [String]?
        let languages: [Reference]?
        let publishDate: String?
        let covers: [Int]?

        enum CodingKeys: String, CodingKey {
            case key, title, works, publishers, languages, covers
            case isbn13 = "isbn_13"
            case publishDate = "publish_date"
        }

        func row(format: BookEdition.Format, evidence: BookEdition.FormatEvidence) -> BookEdition {
            BookEdition(
                id: key ?? isbn13?.first ?? title ?? UUID().uuidString,
                title: title ?? "",
                isbn13: isbn13?.first,
                // "unknown" is a literal publisher name in the data, not a
                // missing value — measured on the third Solo Leveling row.
                // Treated as unstated rather than printed at a reader.
                publisher: publishers?.first.flatMap { $0 == "unknown" ? nil : $0 },
                language: languages?.first?.key.flatMap(Self.languageCode),
                published: PartialDate.parse(publishDate),
                coverID: covers?.first,
                // Open Library keeps the volume number inside the title
                // string ("Solo Leveling, Vol. 1", "Solo Leveling T01") and
                // publishes no field for it. Parsing it out of two languages'
                // punctuation is a guess, so this stays nil and the title
                // carries it. DNB's MARC `245$n` is the source that hands the
                // number over properly, if it is ever wanted.
                volume: nil,
                source: .openLibrary,
                format: format,
                formatEvidence: evidence
            )
        }

        /// `/languages/eng` → `eng`. Nil for anything that is not that shape,
        /// so a schema change reads as "did not say" rather than as a
        /// three-letter code that is not one.
        private static func languageCode(_ key: String) -> String? {
            let code = key.split(separator: "/").last.map(String.init)
            guard let code, code.count == 3, code.allSatisfy(\.isLetter) else { return nil }
            return code
        }
    }

    // MARK: - Cache

    private struct Cached: Codable {
        let storedAt: Date
        /// Nil is the remembered `.notCatalogued` answer. The outer optional
        /// on `readCache` is "nothing cached at all" — the same two-level
        /// distinction `OpenLibraryCovers` draws, for the same reason.
        let rows: [BookEdition]?
    }

    private func file(_ key: String) -> URL? {
        cacheDirectory?.appendingPathComponent("\(key).json")
    }

    func readCache(_ key: String) -> EditionAnswer? {
        guard let file = file(key), let data = try? Data(contentsOf: file),
              let cached = try? JSONDecoder().decode(Cached.self, from: data),
              clock.now.timeIntervalSince(cached.storedAt) < Self.cacheLife
        else { return nil }
        guard let rows = cached.rows else { return .notCatalogued }
        return .editions(rows)
    }

    private func writeCache(_ key: String, _ answer: EditionAnswer) {
        guard let directory = cacheDirectory, let file = file(key) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let rows: [BookEdition]? = {
            if case let .editions(rows) = answer { return rows }
            return nil
        }()
        let cached = Cached(storedAt: clock.now, rows: rows)
        try? JSONEncoder().encode(cached).write(to: file, options: .atomic)
    }
}
