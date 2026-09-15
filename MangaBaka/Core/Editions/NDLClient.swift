import Foundation

/// Japanese volumes — including ones that are not out yet — from the National
/// Diet Library's SRU catalogue.
///
/// NDL catalogues every book published in Japan by law, which makes it the
/// only complete source for the Japanese half of a series. Two things here
/// exist nowhere else in the bibliographic family:
///
/// **Forthcoming volumes.** NDL ingests 近刊 records. Measured 2026-09-14
/// against a clock reading 2026-09-14: `俺だけレベルアップな件外伝　01`,
/// `dcterms:issued = 2026-09-18`, ISBN 9784046604873, KADOKAWA — a volume
/// four days in the future. This is the closest thing left to the "what's
/// next" signal that went out with Naver, for print volumes rather than
/// chapters, and any copy written over it has to say *volume*.
///
/// **A real format field.** `dcndl:genre` is filled in by a national library's
/// cataloguers, not by a crowd — see `Query` for the measurement that
/// shows it separating the Apothecary manga from the Apothecary light novel
/// cleanly, which is the test Open Library's `form:` tags fail.
///
/// ## Licensing — read `docs/licences.md` before shipping this
///
/// NDL's terms require **prior application for commercial use**, and credit is
/// mandatory either way. The app is free and ad-free today, which is arguably
/// non-commercial, but that is not a call this file gets to make. The
/// obligation and NDL's exact wording are recorded in `docs/licences.md` as an
/// open question. Nothing here is gated off; the credit
/// (`BookEdition.Source.nationalDietLibrary.credit`) is not optional.
actor NDLClient {
    /// A GUESS. NDL documents that concurrent-request limits are enforced but
    /// publishes no numeric threshold, and says large-scale continuous access
    /// may be blocked. Sequential requests at this spacing were not throttled
    /// in either the research pass or the 2026-09-14 measurements (no 429 seen
    /// across ~6 calls), so this is a politeness figure, not a measured floor.
    static let minimumInterval: TimeInterval = 2.0
    /// One day. Shorter than `OpenLibraryEditions`' week on purpose: the
    /// forthcoming record is the reason to ask NDL at all, and a 近刊 date can
    /// move. A week's cache would show a slipped release date for six days
    /// after it changed.
    static let cacheLife: TimeInterval = 24 * 3600
    /// SRU's `maximumRecords`. One request per series; 薬屋のひとりごと holds 84
    /// book records and ONE PIECE far more, so a long-running series shows its
    /// first page and a view must not call the list complete.
    static let pageSize = 50

    private let session: URLSession
    private let clock: any Clock
    private let cacheDirectory: URL?
    private var spacing: RequestSpacing

    /// - Parameter minimumInterval: injectable so a test that makes two calls
    ///   in a row does not sleep for a real interval between them — the sleep
    ///   is `Task.sleep`, which the injected `clock` cannot fast-forward.
    init(
        session: URLSession = ThirdPartySession.shared,
        clock: any Clock = SystemClock(),
        minimumInterval: TimeInterval = NDLClient.minimumInterval,
        cacheDirectory: URL? = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("ndl", isDirectory: true)
    ) {
        self.session = session
        self.clock = clock
        self.cacheDirectory = cacheDirectory
        spacing = RequestSpacing(minimumInterval: minimumInterval)
    }

    /// The Japanese printings NDL holds for this series, forthcoming ones
    /// included.
    ///
    /// - Parameters:
    ///   - japaneseTitle: the series' own Japanese title, from MangaBaka's
    ///     `titles`. Searching in English finds nothing here.
    ///   - format: what MangaBaka says the series is. `.comic` turns on the
    ///     genre filter described in `Query` (`evidence(for:comicImprints:)`); `.unknown` turns it off
    ///     and lets every titled record through, which on a measured query
    ///     includes an anime soundtrack.
    /// - Returns: `.notCatalogued` when NDL matched nothing at all — "we
    ///   asked and they hold nothing of this". `.editions([])` when NDL
    ///   matched records and the filter removed every one: the catalogue
    ///   *has* the series, and a view saying "no record of this series" over
    ///   five light-novel records would be wrong. `BookEdition.swift` defines
    ///   the two answers as distinct; this is where the distinction is kept.
    func volumes(
        japaneseTitle: String, format: BookEdition.Format = .comic
    ) async throws(APIError) -> Answer {
        let title = japaneseTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return .notCatalogued }
        // `v2`: the rows gained `edition` and `workTitle` and the file gained
        // `isPartial` on 2026-09-15. A v1 file would decode (both are
        // optionals) to rows with no edition note — the vol. 13 pair on one
        // shelf again — for the day the cache lasts.
        let key = "v2-\(Self.cacheKey(title))-\(format.rawValue)"
        if let cached = readCache(key) { return cached }

        guard let url = Self.requestURL(japaneseTitle: title) else { return .notCatalogued }
        let data = try await load(url)
        guard let answer = Self.answer(title: title, format: format, from: data) else {
            throw .decoding(underlying: "NDL response did not parse.", party: .nationalDietLibrary)
        }
        writeCache(key, answer)
        return answer
    }

    /// What `volumes(japaneseTitle:format:)` returns: the rows, and whether
    /// the page they came from was the whole of NDL's answer.
    struct Answer: Sendable, Equatable {
        let answer: EditionAnswer
        /// True when NDL holds more records than this page carried. **A
        /// shelf built from a partial page must not call itself complete**:
        /// measured 2026-09-15, page 1 of 薬屋のひとりごと (50 of 84) holds
        /// Square Enix volumes 1 and 10–14 only, and 2–9 are on page 2 — an
        /// owned line reading "missing vol. 2–9" to a reader holding them
        /// would be false. `OwnedSummary.line` reads this off `EditionShelf`.
        let isPartial: Bool

        static let notCatalogued = Answer(answer: .notCatalogued, isPartial: false)
    }

    /// The page as an answer, or nil when it is not XML. Pure, so a test can
    /// hand it a recorded page.
    static func answer(title: String, format: BookEdition.Format, from data: Data) -> Answer? {
        guard let page = NDLRecordParser.parseResponse(data) else { return nil }
        let records = Query.deduplicated(page.records)
        let rows = Query(title: title, format: format).rows(from: records)
        // Counted after the URI dedupe, against `numberOfRecords`: NDL sends
        // each item as two `BibResource` elements and the parser drops the
        // empty second, so the raw element count is not the page size.
        let isPartial = page.totalRecords.map { $0 > records.count } ?? false
        return Answer(
            answer: records.isEmpty ? .notCatalogued : .editions(rows), isPartial: isPartial
        )
    }

    /// The SRU request, with the three parameters that were each found the
    /// hard way (`docs/sources/bibliographic.md`, 2026-09-14):
    ///
    /// - `recordPacking=xml` is **required**. Without it `recordData` comes
    ///   back as an escaped string and every XML parse returns zero records.
    /// - `mediatype=books`, unquoted. `mediatype="1"` is rejected outright
    ///   (`illegal mediaType value`). It narrows the answer but does **not**
    ///   clean it: measured 2026-09-14, `薬屋のひとりごと` with `mediatype=books`
    ///   still returned an anime soundtrack (東宝, 78 tracks) as its first
    ///   record. The genre filter, not this parameter, is what removes it.
    /// - `title=` is a loose keyword match, not a phrase match — hence the
    ///   post-filter in `Query`.
    ///
    /// The title is quoted in CQL, so a `"` inside it ends the phrase early:
    /// NDL answers a diagnostic, the parser finds zero records, and
    /// `.notCatalogued` is cached for a day. Quotes are dropped rather than
    /// escaped — CQL's `\"` is not documented on NDL's side, and a title's
    /// quote marks are not what its index keys on.
    static func requestURL(japaneseTitle: String) -> URL? {
        let phrase = japaneseTitle.filter { $0 != "\"" && $0 != "\\" }
        var components = URLComponents(string: "https://ndlsearch.ndl.go.jp/api/sru")
        components?.queryItems = [
            URLQueryItem(name: "operation", value: "searchRetrieve"),
            URLQueryItem(name: "recordSchema", value: "dcndl"),
            URLQueryItem(name: "recordPacking", value: "xml"),
            URLQueryItem(name: "maximumRecords", value: String(pageSize)),
            URLQueryItem(name: "query", value: "title=\"\(phrase)\" AND mediatype=books")
        ]
        return components?.url
    }

    /// A filename-safe key. The title is Japanese and goes into a path, so it
    /// is hashed rather than escaped — an escaped one runs past the
    /// filesystem's name length on a long light-novel title.
    ///
    /// FNV-1a rather than `hashValue`: Swift seeds `Hashable` per process, so
    /// a `hashValue`-named file is a cache that never hits after a relaunch —
    /// which is every launch. This one is stable for the life of the format.
    static func cacheKey(_ title: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in Array(title.utf8) {
            hash ^= UInt64(byte)
            hash = hash &* 0x1000_0000_01b3
        }
        return String(format: "%016llx", hash)
    }

    private func load(_ url: URL) async throws(APIError) -> Data {
        let wait = spacing.claim(now: clock.now)
        if wait > 0 {
            try? await Task.sleep(for: .seconds(wait))
            // Gap 28, as in every sibling client: `try?` alone swallows
            // cancellation and would spend the request the cancelled wait
            // already claimed a slot for.
            guard !Task.isCancelled else { throw .cancelled }
        }

        let received: (data: Data, response: URLResponse)
        do {
            received = try await session.data(from: url)
        } catch let error {
            if (error as? URLError)?.code == .cancelled { throw .cancelled }
            throw .transport(underlying: "NDL request failed.", party: .nationalDietLibrary)
        }
        guard let http = received.response as? HTTPURLResponse else {
            throw .transport(underlying: "NDL sent a non-HTTP response.", party: .nationalDietLibrary)
        }
        if http.statusCode == 429 {
            // Parsed and clamped in one place (`RequestSpacing.backOff`) like
            // every other client, rather than a bare `TimeInterval.init` that
            // accepts "nan".
            let retryAfter = spacing.backOff(
                retryAfterHeader: http.value(forHTTPHeaderField: "Retry-After"), now: clock.now
            )
            throw .rateLimited(retryAfter: retryAfter, party: .nationalDietLibrary)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw .server(
                status: http.statusCode,
                message: "NDL returned \(http.statusCode).", party: .nationalDietLibrary
            )
        }
        return received.data
    }

    // MARK: - Cache

    private struct Cached: Codable {
        let storedAt: Date
        /// Nil is the remembered `.notCatalogued`; the outer optional on
        /// `readCache` is "nothing cached at all".
        let rows: [BookEdition]?
        let isPartial: Bool
    }

    private func file(_ key: String) -> URL? {
        cacheDirectory?.appendingPathComponent("\(key).json")
    }

    func readCache(_ key: String) -> Answer? {
        guard let file = file(key), let data = try? Data(contentsOf: file),
              let cached = try? JSONDecoder().decode(Cached.self, from: data),
              clock.now.timeIntervalSince(cached.storedAt) < Self.cacheLife
        else { return nil }
        guard let rows = cached.rows else { return .notCatalogued }
        return Answer(answer: .editions(rows), isPartial: cached.isPartial)
    }

    private func writeCache(_ key: String, _ answer: Answer) {
        guard let directory = cacheDirectory, let file = file(key) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let rows: [BookEdition]? = {
            if case let .editions(rows) = answer.answer { return rows }
            return nil
        }()
        let cached = Cached(storedAt: clock.now, rows: rows, isPartial: answer.isPartial)
        try? JSONEncoder().encode(cached).write(to: file, options: .atomic)
    }
}
