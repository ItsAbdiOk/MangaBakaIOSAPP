import Foundation

/// One character in a series.
///
/// **Why Shikimori and not AniList.** AniList was the obvious source and the
/// one asked for. Its GraphQL API answers every request with HTTP 403 and the
/// message "The AniList API has been temporarily disabled due to severe
/// stability issues" — checked repeatedly on 2026-09-10, so not a blip.
/// Shikimori is already one of MangaBaka's own upstream sources, its id arrives
/// in every series' `source` block, and it carries names, roles and portraits.
/// If AniList returns it is the better source, and this type is the seam.
struct SeriesCharacter: Identifiable, Equatable, Sendable {
    let id: Int
    let name: String
    /// "Main" or "Supporting". Shikimori sends an array whose remaining entries
    /// repeat the first in Russian.
    let role: String?
    let imageURL: URL?

    var isMain: Bool { role?.caseInsensitiveCompare("Main") == .orderedSame }
}

/// Shikimori's own role row. `character` is null on staff rows, which is how
/// the author and the artist arrive in the same list as the cast.
struct ShikimoriRole: Decodable, Sendable {
    struct Character: Decodable, Sendable {
        struct Image: Decodable, Sendable {
            let x96: String?
            let preview: String?
        }
        let id: Int?
        let name: String?
        let image: Image?
    }
    let roles: [String]?
    let character: Character?
}

enum ShikimoriCast {
    /// Shikimori returns a placeholder image rather than null when it has no
    /// portrait. The path is the tell.
    static func isMissingPortrait(_ path: String) -> Bool {
        path.contains("missing_")
    }

    /// Turns Shikimori's role list into a cast worth showing.
    ///
    /// Three things happen here, each for a measured reason, checked against
    /// Solo Leveling's live response on 2026-09-10 (98 rows, 95 with a
    /// character):
    ///
    /// - Staff rows are dropped. The author and artist arrive in the same list
    ///   with `character: null`, and they are already in the credits table.
    /// - Characters with no portrait are dropped. Most of the 95 carry a
    ///   `missing_x96.jpg` placeholder, and a row of identical grey squares
    ///   says nothing and reads as broken.
    /// - Main characters come first. Shikimori orders the rest alphabetically,
    ///   so without this the row opens on whoever's name begins with A.
    static func cast(from rows: [ShikimoriRole], baseURL: URL, limit: Int) -> [SeriesCharacter] {
        let people: [SeriesCharacter] = rows.compactMap { row in
            guard let character = row.character,
                  let id = character.id,
                  let name = character.name,
                  !name.isEmpty
            else { return nil }

            let path = character.image?.x96 ?? character.image?.preview
            guard let path, !isMissingPortrait(path) else { return nil }

            return SeriesCharacter(
                id: id,
                name: name,
                role: row.roles?.first,
                // Shikimori's paths are host-relative.
                imageURL: URL(string: path, relativeTo: baseURL)?.absoluteURL
            )
        }

        // Stable within each group, so the alphabetical order Shikimori sends
        // survives among the supporting cast rather than being reshuffled.
        let main = people.filter(\.isMain)
        let rest = people.filter { !$0.isMain }
        return Array((main + rest).prefix(limit))
    }
}

/// Reads character lists from Shikimori.
///
/// A third API with a third set of rules: it requires a User-Agent naming the
/// app, and asks for no more than five requests a second. An actor so the
/// spacing holds across concurrent callers.
actor ShikimoriClient {
    /// Their published limit is five requests a second. 250ms is half that, the
    /// app makes one request per series page opened, so the margin costs
    /// nothing and a ban would cost the feature entirely.
    static let minimumInterval: TimeInterval = 0.25

    /// Required by their terms: an unidentified client is refused.
    static let userAgent = "MangaBakaIOS/1.0 (+https://github.com/ItsAbdiOk/MangaBakaIOSAPP)"

    private let baseURL: URL
    private let session: URLSession
    private let clock: any Clock
    private var nextAllowedRequest: Date = .distantPast

    init(
        baseURL: URL = URL(string: "https://shikimori.one").unsafeCharacterFallback,
        session: URLSession = .shared,
        clock: any Clock = SystemClock()
    ) {
        self.baseURL = baseURL
        self.session = session
        self.clock = clock
    }

    /// The cast of one series, main characters first.
    ///
    /// - Parameter limit: how many to keep. Solo Leveling returns 95, and a row
    ///   of 95 portraits is a scroll rather than a summary.
    func characters(mangaId: Int, limit: Int = 20) async throws(APIError) -> [SeriesCharacter] {
        try await waitForSlot()

        var request = URLRequest(url: baseURL.appending(path: "/api/mangas/\(mangaId)/roles"))
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw APIError.transport(underlying: String(describing: error))
        }

        guard let http = response as? HTTPURLResponse else {
            throw APIError.transport(underlying: "Shikimori sent a non-HTTP response.")
        }
        if http.statusCode == 429 {
            let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            nextAllowedRequest = clock.now.addingTimeInterval(retryAfter ?? 60)
            throw APIError.rateLimited(retryAfter: retryAfter)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.server(
                status: http.statusCode,
                message: "Shikimori returned \(http.statusCode)."
            )
        }

        do {
            let rows = try JSONDecoder().decode([ShikimoriRole].self, from: data)
            return ShikimoriCast.cast(from: rows, baseURL: baseURL, limit: limit)
        } catch {
            throw APIError.decoding(underlying: String(describing: error))
        }
    }

    private func waitForSlot() async throws(APIError) {
        let now = clock.now
        if nextAllowedRequest > now {
            do {
                try await Task.sleep(for: .seconds(nextAllowedRequest.timeIntervalSince(now)))
            } catch {
                throw APIError.transport(underlying: "Cancelled while waiting for a request slot.")
            }
        }
        nextAllowedRequest = clock.now.addingTimeInterval(Self.minimumInterval)
    }
}

private extension Optional where Wrapped == URL {
    var unsafeCharacterFallback: URL {
        guard let self else { preconditionFailure("Hard-coded Shikimori URL failed to parse.") }
        return self
    }
}
