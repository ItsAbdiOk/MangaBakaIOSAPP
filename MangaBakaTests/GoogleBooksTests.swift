import Foundation
import Testing
@testable import MangaBaka

/// Which Google Books results are volumes of this series — mirrors
/// `AppleBooksMatchTests`, since `GoogleBooksMatch` reuses the same strict
/// matcher on purpose rather than a second, looser one.
@Suite("Google Books matching")
struct GoogleBooksMatchTests {
    private func item(
        _ id: String, _ title: String, language: String? = "en", thumbnail: String? = nil
    ) -> GoogleBooksItem {
        GoogleBooksItem(
            id: id,
            volumeInfo: .init(
                title: title,
                language: language,
                infoLink: URL(string: "https://books.google.com/books?id=\(id)"),
                canonicalVolumeLink: URL(string: "https://books.google.com/books/about/\(id).html"),
                imageLinks: thumbnail.map { .init(thumbnail: URL(string: $0), smallThumbnail: nil) }
            )
        )
    }

    /// The live answer for `intitle:"solo leveling"` mixes comic and novel
    /// editions with the "Ragnarok" sequel exactly like Apple's store does
    /// (verified 2026-09-12, 300 totalItems) — this is why the matcher is
    /// reused rather than rewritten.
    @Test("The series' own comic volumes, one per number, in order; nothing else")
    func strictMatch() {
        let items = [
            item("1", "Solo Leveling, Vol. 1 (comic)"),
            item("2", "Solo Leveling, Vol. 1 (novel)"),
            item("3", "Solo Leveling, Vol. 8 (comic)"),
            item("4", "Solo Leveling: Ragnarok, Vol. 1 (comic)"),
            item("5", "Solo Leveling, Vol. 2 (comic)")
        ]
        let volumes = GoogleBooksMatch.volumes(in: items, titles: ["Solo Leveling"], isNovel: false)
        #expect(volumes.map(\.number) == [1, 2, 8])
        #expect(volumes.map(\.id) == ["1", "5", "3"])
    }

    @Test("A novel series takes the novels and leaves the comics")
    func novels() {
        let items = [item("1", "Solo Leveling, Vol. 1 (comic)"), item("2", "Solo Leveling, Vol. 1 (novel)")]
        let volumes = GoogleBooksMatch.volumes(in: items, titles: ["Solo Leveling"], isNovel: true)
        #expect(volumes.map(\.id) == ["2"])
    }

    /// T3/F15: before this shared matcher, Google's own `volumes` had
    /// neither of Apple's morning fixes. An untagged "Volume 1" ranked
    /// ahead of "01 (Manga)" by the store's own relevance order used to win
    /// as first-seen; now tagged editions are ranked first, whichever
    /// store answered.
    @Test("A tagged edition beats an untagged one ranked first, same as Apple's")
    func taggedEditionRankedFirst() {
        let items = [
            item("1", "The Apothecary Diaries: Volume 1"), // untagged, ranked first by the store
            item("2", "The Apothecary Diaries 01 (Manga)")
        ]
        let comic = GoogleBooksMatch.volumes(in: items, titles: ["The Apothecary Diaries"], isNovel: false)
        #expect(comic.map(\.id) == ["2"], "the tagged (Manga) edition wins, not whichever came first")
    }

    /// T3/F15: `language` was decoded onto every item and never filtered
    /// on, so a foreign edition could fill a gap on an English shelf with
    /// no way to reject it.
    @Test("An item in another language is rejected when a language is asked for")
    func languageFilter() {
        let items = [
            item("1", "Solo Leveling, Vol. 1 (comic)", language: "fr"),
            item("2", "Solo Leveling, Vol. 2 (comic)", language: "en"),
            item("3", "Solo Leveling, Vol. 3 (comic)", language: nil) // unknown: kept, not guessed at
        ]
        let volumes = GoogleBooksMatch.volumes(
            in: items, titles: ["Solo Leveling"], isNovel: false, language: "en"
        )
        #expect(volumes.map(\.number) == [2, 3])
    }

    /// T8/F5: a comic tagged "(Graphic Novel)" is a comic, not a novel —
    /// the same rule as Apple's, since both now share `isNovelTag`.
    @Test("\"(Graphic Novel)\" reads as a comic, not a novel")
    func graphicNovelIsAComic() {
        let items = [item("1", "Watchmen, Vol. 1 (Graphic Novel)")]
        let comic = GoogleBooksMatch.volumes(in: items, titles: ["Watchmen"], isNovel: false)
        #expect(comic.map(\.id) == ["1"])
        let novel = GoogleBooksMatch.volumes(in: items, titles: ["Watchmen"], isNovel: true)
        #expect(novel.isEmpty)
    }

    /// The control: "Solo Leveling, Vol. 1 (comic)" from Ize Press had no
    /// `imageLinks` at all in the live answer (2026-09-12) — a matched
    /// volume with no artwork must still produce no gallery entry, not a
    /// grey rectangle.
    @Test("A matched volume with no artwork has no gallery image")
    func noArtwork() {
        let items = [item("1", "Solo Leveling, Vol. 1 (comic)", thumbnail: nil)]
        let volumes = GoogleBooksMatch.volumes(in: items, titles: ["Solo Leveling"], isNovel: false)
        #expect(volumes.count == 1)
        #expect(volumes.first?.thumbnailURL == nil)
        #expect(volumes.first?.galleryImage == nil)

        // Control: the same volume WITH a thumbnail does produce a gallery
        // entry, so the assertion above is testing the right thing.
        let withArt = [item("1", "Solo Leveling, Vol. 1 (comic)", thumbnail: "http://books.google.com/x.jpg")]
        let matched = GoogleBooksMatch.volumes(in: withArt, titles: ["Solo Leveling"], isNovel: false)
        #expect(matched.first?.galleryImage != nil)
    }

    /// Measured live, 2026-09-12: the default `thumbnail` URL is `http://`,
    /// which ATS blocks outright.
    @Test("An http thumbnail is rewritten to https")
    func httpsRewrite() {
        let url = URL(string: "http://books.google.com/books/content?id=abc&printsec=frontcover")
        #expect(GoogleBooksMatch.toHTTPS(url.unsafelyUnwrapped)?.scheme == "https")
    }

    /// Measured live, 2026-09-12: unmodified thumbnail is 128x184 (13,617
    /// bytes); `&fife=w800` upgrades the same URL to 800x1148 (125,714
    /// bytes). Undocumented, so this only tests that the parameter is
    /// appended, not that Google honours it.
    @Test("The large-thumbnail upgrade appends fife=w800 to an https URL")
    func fifeUpgrade() {
        let links = GoogleBooksItem.VolumeInfo.ImageLinks(
            thumbnail: URL(string: "http://books.google.com/books/content?id=abc&printsec=frontcover"),
            smallThumbnail: nil
        )
        let upgraded = GoogleBooksMatch.largeThumbnail(links)
        #expect(upgraded?.scheme == "https")
        #expect(upgraded?.absoluteString.contains("fife=w800") == true)
    }

    /// Control: no `imageLinks` at all degrades to nil, not a crash and not
    /// a fife-upgraded garbage URL.
    @Test("No imageLinks at all upgrades to nil")
    func noImageLinksAtAll() {
        #expect(GoogleBooksMatch.largeThumbnail(nil) == nil)
    }
}

/// Decoding a realistic recorded response, including the no-artwork case
/// Google's live answer actually contains.
@Suite("Google Books decoding")
struct GoogleBooksDecodingTests {
    private struct Envelope: Decodable {
        let items: [GoogleBooksItem]?
    }

    @Test("A realistic response decodes, including an item with no imageLinks")
    func decode() throws {
        let json = Data(#"""
        {"totalItems":300,"items":[
          {"id":"abc123","volumeInfo":{"title":"Solo Leveling, Vol. 6 (comic)","language":"en",
            "publisher":"Yen Press LLC",
            "infoLink":"http://books.google.com/books?id=abc123",
            "canonicalVolumeLink":"https://books.google.com/books/about/abc123.html",
            "imageLinks":{"smallThumbnail":"http://books.google.com/books/content?id=abc123&zoom=5",
              "thumbnail":"http://books.google.com/books/content?id=abc123&zoom=1"}}},
          {"id":"def456","volumeInfo":{"title":"Solo Leveling, Vol. 1 (comic)","language":"en",
            "publisher":"Ize Press",
            "infoLink":"http://books.google.com/books?id=def456"}}
        ]}
        """#.utf8)
        let decoded = try JSONDecoder().decode(Envelope.self, from: json)
        #expect(decoded.items?.count == 2)
        #expect(decoded.items?[0].volumeInfo.imageLinks?.thumbnail != nil)
        // The control this test exists for: Ize Press's listing really has no
        // imageLinks key at all, and decoding it must not fail or crash.
        #expect(decoded.items?[1].volumeInfo.imageLinks == nil)
    }
}

/// The client: gap-filling is keyed to the series and language, and an answer
/// is cached like Apple's is.
@Suite("Google Books client", .serialized)
struct GoogleBooksClientTests {
    private func makeClient(clock: TestClock) -> GoogleBooksClient {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("googlebooks-tests-\(UUID().uuidString)", isDirectory: true)
        return GoogleBooksClient(
            session: URLProtocolStub.makeSession(), clock: clock,
            cacheDirectory: directory
        )
    }

    private let answer = Data(#"""
    {"totalItems":1,"items":[
      {"id":"abc123","volumeInfo":{"title":"Solo Leveling, Vol. 1 (comic)","language":"en",
        "canonicalVolumeLink":"https://books.google.com/books/about/abc123.html",
        "imageLinks":{"thumbnail":"http://books.google.com/books/content?id=abc123&zoom=1"}}}
    ]}
    """#.utf8)

    /// The anonymous quota is shared and was spent when measured, so a 429 is
    /// the likely everyday answer. It has to read as "no extra covers" — nil,
    /// no throw — because Apple's volumes and MangaBaka's own covers are still
    /// on the page and must not be disturbed by Google being unavailable.
    @Test("A spent anonymous quota degrades to nil, not an error")
    func quotaExhausted() async {
        URLProtocolStub.setHandler { _ in .respond(.init(statusCode: 429)) }
        defer { URLProtocolStub.reset() }
        let series = SeriesFactory.make(id: 3397, title: "Solo Leveling")

        let result = await makeClient(clock: TestClock()).volumes(for: series)
        #expect(result == nil)
    }

    /// No key is sent at all now that the app uses the anonymous pool — a
    /// stray `key=` would be an unsubstituted build setting reaching Google.
    @Test("Asks with intitle and no key; a second look inside a week costs no request")
    func requestAndCache() async {
        URLProtocolStub.setHandler { _ in .respond(.init(body: answer)) }
        defer { URLProtocolStub.reset() }
        let clock = TestClock()
        let client = makeClient(clock: clock)
        let series = SeriesFactory.make(id: 3397, title: "Solo Leveling")

        let first = await client.volumes(for: series)
        #expect(first?.map(\.number) == [1])
        let url = URLProtocolStub.requests.first?.url?.absoluteString ?? ""
        #expect(url.contains("intitle"))
        #expect(!url.contains("key="))

        _ = await client.volumes(for: series)
        #expect(URLProtocolStub.requests.count == 1, "Cached inside the week")

        clock.advance(by: GoogleBooksClient.cacheLife + 1)
        _ = await client.volumes(for: series)
        #expect(URLProtocolStub.requests.count == 2)
    }

    /// Nil, not empty: a failed request must not be remembered as "no volumes".
    @Test("A failure is nil and is not remembered")
    func failure() async {
        URLProtocolStub.setHandler { _ in .respond(.init(statusCode: 500)) }
        defer { URLProtocolStub.reset() }
        let client = makeClient(clock: TestClock())
        let series = SeriesFactory.make(id: 3397, title: "Solo Leveling")

        let first = await client.volumes(for: series)
        #expect(first == nil)
        URLProtocolStub.setHandler { _ in .respond(.init(body: answer)) }
        let second = await client.volumes(for: series)
        #expect(second?.count == 1)
    }

    /// Gap 28: `try? await Task.sleep` swallowed cancellation and fell
    /// through to firing the request anyway. Expected failure before the
    /// fix: `URLProtocolStub.requests` is non-empty, because the cancelled
    /// task still spent its claimed slot.
    @Test("A cancelled wait for a request slot does not fire the request")
    func cancelledWaitDoesNotFireTheRequest() async {
        URLProtocolStub.setHandler { _ in .respond(.init(body: answer)) }
        defer { URLProtocolStub.reset() }
        let clock = TestClock()
        let client = makeClient(clock: clock)
        let series = SeriesFactory.make(id: 3397, title: "Solo Leveling")

        // Claim the only free slot so the next call must wait — that wait is
        // what gets cancelled below. A different `language` keeps the second
        // call off the first one's cache entry.
        let warm = Task { await client.volumes(for: series) }
        _ = await warm.value

        let task = Task { await client.volumes(for: series, language: "en") }
        task.cancel()
        _ = await task.value

        #expect(URLProtocolStub.requests.count == 1, "only the warm-up request should have been sent")
    }
}
