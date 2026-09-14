import Foundation

/// What ANN said about one series' volumes.
struct ANNVolumes: Sendable, Equatable, Codable {
    let volumes: [EditionVolume]
    /// False when ANN has no manga record for this series to answer with —
    /// either it returned `<warning>`, or MangaBaka holds no ANN id to ask
    /// with.
    ///
    /// It exists so an empty shelf can say *which* nothing it is. "ANN does
    /// not catalogue this series" and "ANN catalogues it and has listed no
    /// volumes" are different sentences, and neither of them is "there are no
    /// more volumes" — see `ForthcomingVolume`.
    let isCatalogued: Bool
}

/// Anime News Network's Encyclopedia API, for a series' English print
/// volumes.
///
/// **Keyless, documented, and one request answers a whole series.** Measured
/// 2026-09-14: `api.xml?title=17164` → HTTP 200, 5,551 bytes,
/// `text/xml;charset=UTF-8`, carrying all fifteen Delicious in Dungeon
/// volumes with an exact date and an ISBN-13 each. The same shape gives One
/// Piece 232 releases including two future-dated pre-orders (GN 113 on
/// 2026-11-10, ean 9781974766703) in one 237 KB answer. GCD needed 1 + N
/// requests for the same list, which is most of why it is not here.
///
/// **Its limit, stated rather than hidden: 3 of the 5 test series.** Both
/// misses are Korean webtoons (Solo Leveling, The Beginning After The End),
/// and the miss is total — ANN has their anime, not their manhwa. This
/// library is majority webtoon, so this source answers "when is the English
/// volume out" for the Japanese half of the shelf and says nothing about the
/// other half. It must never be read as saying anything about the other half.
///
/// **Attribution is a condition of use, not a courtesy.** Every row this
/// produces carries `sourceLink`, and the view is obliged to render it — see
/// `VolumeCatalogue.requiresPerEntryLink`, which spells out exactly what the
/// view must show.
actor ANNClient {
    /// ANN documents 1 request per second per IP, enforced by *delaying* the
    /// request rather than refusing it (the `nodelay.api.xml` variant returns
    /// 503 instead; we use the normal one and pace ourselves). 1.2 s is the
    /// documented second plus **a guess at the margin**, in the same shape as
    /// `AppleBooksClient.minimumInterval`.
    static let minimumInterval: TimeInterval = 1.2

    /// One week. Not a guess: ANN's own documentation asks that details be
    /// cached, and a week is the figure in it. It also suits the data — a
    /// volume's ISBN and on-sale date do not move, and a *newly announced*
    /// pre-order appearing up to a week late is the correct trade for one
    /// request per series per week.
    static let cacheLife: TimeInterval = 7 * 24 * 3600

    private let baseURL: URL
    private let session: URLSession
    private let clock: any Clock
    private let cacheDirectory: URL?
    private var spacing = RequestSpacing(minimumInterval: ANNClient.minimumInterval)

    init(
        baseURL: URL = URL(string: "https://cdn.animenewsnetwork.com/encyclopedia/api.xml")
            .unsafeANNFallback,
        session: URLSession = ThirdPartySession.shared,
        clock: any Clock = SystemClock(),
        cacheDirectory: URL? = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("ann", isDirectory: true)
    ) {
        self.baseURL = baseURL
        self.session = session
        self.clock = clock
        self.cacheDirectory = cacheDirectory
    }

    /// Test-only: when this client's spacing will next let a request out, so
    /// the 429 test can prove the server's own header was honoured without
    /// waiting one out.
    var nextAllowedForTesting: Date { spacing.nextAllowed }

    /// The ANN id MangaBaka already holds for this series.
    ///
    /// **This is why the 760 KB title dump is not bundled, and why there is
    /// no title search.** `/v1/series/{id}` returns a `source` object with
    /// ids for seven trackers, ANN among them — verified live 2026-09-14,
    /// series 377 → `"anime_news_network": {"id": 1223}`. Bundling ANN's
    /// 24,322-title `reports.xml` dump would add ~760 KB to the binary and a
    /// build step, to re-derive an id we are handed for free.
    ///
    /// Title matching is worse than merely redundant: `api.xml?title=~name`
    /// matches only ANN's *primary* title, so `~The Apothecary Diaries`
    /// answers `<warning>no results</warning>` (ANN's primary name omits the
    /// article), and a loose `~Solo Leveling` lands on the *anime* record and
    /// its Blu-ray releases — a wrong answer that looks like a right one.
    /// A series MangaBaka has no ANN id for is reported `notCatalogued`
    /// rather than guessed at.
    ///
    /// `nonisolated static` so the tests can assert the lookup without a
    /// client, and so callers can skip the actor hop to decide whether to ask.
    nonisolated static func encyclopediaID(for series: Series) -> Int? {
        series.source?["anime_news_network"]?.id.flatMap(Int.init)
    }

    /// The series' English print volumes, as ANN lists them.
    ///
    /// `.loaded` with `isCatalogued: false` is the answer for a series ANN
    /// does not have — a real answer, not a failure, and not a loading state
    /// the view can sit spinning on.
    func volumes(for series: Series) async -> Fetched<ANNVolumes> {
        let role = VolumeEditions.role(of: "en", in: series)
        guard let identifier = Self.encyclopediaID(for: series) else {
            return .loaded(
                ANNVolumes(volumes: [], isCatalogued: false), fetchedAt: clock.now, isPartial: false
            )
        }
        // Versioned like the sibling clients' keys: a parsing rule that
        // tightens must not be outlived by a week of answers made under the
        // looser one. v2 (2026-09-14): `EditionVolume` grew `alsoFrom` and
        // `dateFrom` for the cross-source dedupe. Its decoder tolerates their
        // absence, so a v1 file would still read — the bump is belt and braces,
        // because the cost of being wrong here is a client that answers
        // nothing for a week.
        let key = "v2-ann-\(identifier)"
        if let cached = readCache(key) {
            return .loaded(cached.answer, fetchedAt: cached.storedAt, isPartial: false)
        }

        switch await fetch(identifier: identifier) {
        case let .failure(error):
            return .failed(error, stale: nil)
        case let .success(entry):
            // A `<warning>` is ANN's way of saying "no such record" over a
            // 200. An entry with an id and no releases is a record that
            // exists and lists nothing, which is a different answer.
            let catalogued = entry.id != nil || entry.warning == nil
            let answer = ANNVolumes(
                volumes: ANNEncyclopedia.volumes(in: entry, role: role), isCatalogued: catalogued
            )
            writeCache(key, answer)
            return .loaded(answer, fetchedAt: clock.now, isPartial: false)
        }
    }

    private func fetch(identifier: Int) async -> Result<ANNEntry, APIError> {
        // `title`, not `manga` or `id`: ANN's parameter for "fetch this
        // numeric encyclopedia id" is confusingly named `title`, and the
        // `manga=`/`title=~name` forms are the name lookups this client
        // deliberately does not use. Verified 2026-09-14.
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "title", value: String(identifier))]
        guard let url = components?.url else {
            return .failure(
                .transport(underlying: "Could not build the ANN URL.", party: .animeNewsNetwork)
            )
        }

        let wait = spacing.claim(now: clock.now)
        if wait > 0 {
            try? await Task.sleep(for: .seconds(wait))
            // Gap 28, as in `AppleBooksClient.search`: `try?` alone swallows
            // cancellation and falls through to spending the request the
            // cancelled wait already claimed a slot for.
            guard !Task.isCancelled else { return .failure(.cancelled) }
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(from: url)
        } catch let error {
            if error is CancellationError || (error as? URLError)?.code == .cancelled {
                return .failure(.cancelled)
            }
            if (error as? URLError)?.code == .notConnectedToInternet { return .failure(.offline) }
            return .failure(.transport(underlying: error.localizedDescription, party: .animeNewsNetwork))
        }
        guard let http = response as? HTTPURLResponse else {
            return .failure(.transport(underlying: "Not an HTTP response.", party: .animeNewsNetwork))
        }
        if http.statusCode == 429 || http.statusCode == 503 {
            // 503 is grouped with 429 on purpose: it is what ANN's
            // `nodelay.api.xml` returns for an over-rate client, and while
            // this client uses the delaying endpoint, a 503 from ANN is far
            // more likely to be "too fast" than "broken". Backing off is the
            // right response to either.
            let retryAfter = spacing.backOff(
                retryAfterHeader: http.value(forHTTPHeaderField: "Retry-After"), now: clock.now
            )
            return .failure(
                .rateLimited(
                    retryAfter: retryAfter ?? RequestSpacing.unstatedBackOff, party: .animeNewsNetwork
                )
            )
        }
        guard (200..<300).contains(http.statusCode) else {
            return .failure(.server(status: http.statusCode, message: "", party: .animeNewsNetwork))
        }
        guard let entry = ANNEncyclopedia.parse(data) else {
            return .failure(
                .decoding(underlying: "ANN's answer was not Encyclopedia XML.", party: .animeNewsNetwork)
            )
        }
        return .success(entry)
    }

    // MARK: - Cache

    private struct Cached: Codable {
        let storedAt: Date
        let answer: ANNVolumes
    }

    private func file(_ key: String) -> URL? {
        cacheDirectory?.appendingPathComponent("\(key).json")
    }

    /// - Returns: the cached answer and when it was written, or nil when
    ///   there is nothing usable cached. `storedAt` becomes the `fetchedAt`
    ///   on the `Fetched` above, so a `StaleBar` can say "volumes from 6 days
    ///   ago" honestly — which matters more here than for the stores, because
    ///   this cache is a week long at ANN's own request.
    ///
    ///   Internal rather than private, like the sibling clients' `readCache`,
    ///   purely so the tests can assert on `storedAt` directly.
    func readCache(_ key: String) -> (answer: ANNVolumes, storedAt: Date)? {
        guard let file = file(key), let data = try? Data(contentsOf: file),
              let cached = try? JSONDecoder().decode(Cached.self, from: data),
              clock.now.timeIntervalSince(cached.storedAt) < Self.cacheLife
        else { return nil }
        return (cached.answer, cached.storedAt)
    }

    private func writeCache(_ key: String, _ answer: ANNVolumes) {
        guard let directory = cacheDirectory, let file = file(key) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cached = Cached(storedAt: clock.now, answer: answer)
        try? JSONEncoder().encode(cached).write(to: file, options: .atomic)
    }
}

private extension Optional where Wrapped == URL {
    var unsafeANNFallback: URL {
        guard let self else { preconditionFailure("Hard-coded ANN API URL failed to parse.") }
        return self
    }
}
