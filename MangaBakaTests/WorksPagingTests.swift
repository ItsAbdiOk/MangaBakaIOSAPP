import Foundation
import Testing
@testable import MangaBaka

/// `/works` pages ascending and honours no sort, so the forthcoming volume of
/// a long series sits on the last page — measured 2026-09-15 on ONE PIECE
/// (377): 267 printings, page one grouped to "Volumes 7", volume 113 (due
/// 2026-11-10) on page 6. `fetchWorks` asks for the first and last pages.
/// `.serialized` for `URLProtocolStub`'s recorder.
@Suite("Works: first and last page", .serialized)
struct WorksPagingTests {
    private let baseURL = URL(string: "https://api.example.invalid").unsafeTestURL

    private func makeRepository() throws -> SeriesRepository {
        SeriesRepository(
            client: APIClient(
                baseURL: baseURL, session: URLProtocolStub.makeSession(),
                tokenProvider: UnauthenticatedTokenProvider()
            ),
            database: try AppDatabase.inMemory(), clock: TestClock()
        )
    }

    private func page(ids: [Int], count: Int, page: Int) -> Data {
        let rows = ids.map {
            #"{"id":"w\#($0)","sequence_string":"\#($0)","sequence_numeric":\#($0),"release_date":null}"#
        }
        let pagination = #"{"count":\#(count),"page":\#(page),"limit":50}"#
        return Data(
            #"{"status":200,"data":[\#(rows.joined(separator: ","))],"pagination":\#(pagination)}"#.utf8
        )
    }

    /// Control: a short series is one request, and the total is the count.
    @Test("Control — a series within one page makes one request")
    func shortSeriesIsOneRequest() async throws {
        URLProtocolStub.setHandler { [body = page(ids: [1, 2, 3], count: 3, page: 1)] _ in
            .respond(.init(body: body))
        }
        defer { URLProtocolStub.reset() }
        let answer = try await makeRepository().fetchWorks(for: 2060)
        #expect(answer.works.map(\.id) == ["w1", "w2", "w3"])
        #expect(answer.total == 3)
        #expect(URLProtocolStub.requests.count == 1)
    }

    /// Fails on the old code with one request and works 1–50 only.
    @Test("A long series fetches page 1 and the last page, in one list")
    func longSeriesFetchesLastPage() async throws {
        URLProtocolStub.setHandler { [self] request in
            let url = request.url ?? URL(fileURLWithPath: "/")
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let pageNumber = items.first { $0.name == "page" }?.value ?? "1"
            if pageNumber == "6" {
                return .respond(.init(body: page(ids: [112, 113], count: 267, page: 6)))
            }
            return .respond(.init(body: page(ids: Array(1...50), count: 267, page: 1)))
        }
        defer { URLProtocolStub.reset() }
        let answer = try await makeRepository().fetchWorks(for: 377)
        #expect(answer.total == 267)
        #expect(answer.works.count == 52)
        #expect(answer.works.last?.id == "w113")
        let pages = URLProtocolStub.requests.compactMap { request in
            URLComponents(url: request.url ?? URL(fileURLWithPath: "/"), resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "page" }?.value
        }
        #expect(pages == ["1", "6"])
        #expect(
            URLProtocolStub.requests.allSatisfy { $0.url?.query?.contains("limit=50") == true },
            "the endpoint's ceiling, not its 25 default"
        )
    }

    /// The badge on the shelf: the volume count when the list is whole, the
    /// highest volume number when it is not.
    @Test("The volumes badge reads 113, not 7, for a partial shelf")
    func badgeOnPartialShelf() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let rows = [("a", 1), ("b", 1), ("c", 113)].map {
            #"{"id":"\#($0.0)","sequence_string":"\#($0.1)","sequence_numeric":\#($0.1)}"#
        }
        let works = try decoder.decode(
            [SeriesWork].self, from: Data("[\(rows.joined(separator: ","))]".utf8)
        )
        let volumes = SeriesWork.volumes(from: works)
        let whole = try #require(VolumesSection.badge(volumes: volumes, worksTotal: 3))
        #expect(whole.text == "2")
        #expect(!whole.isPartial)
        let partial = try #require(VolumesSection.badge(volumes: volumes, worksTotal: 267))
        #expect(partial.text == "113")
        #expect(partial.isPartial)
        let unknown = try #require(VolumesSection.badge(volumes: volumes, worksTotal: nil))
        #expect(unknown.text == "2", "a row cached before the total existed reads as before")
        #expect(VolumesSection.badge(volumes: [], worksTotal: 267) == nil)
    }
}
