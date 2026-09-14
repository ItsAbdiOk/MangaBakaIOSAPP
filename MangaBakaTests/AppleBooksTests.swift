import Foundation
import Testing
@testable import MangaBaka

/// Which Apple Books results are volumes of this series. Strict, because a
/// wrong cover under "Volume 3" is worse than an empty spine.
@Suite("Apple Books matching")
struct AppleBooksMatchTests {
    private func result(
        _ id: Int, _ name: String, by artist: String? = nil, blurb: String? = nil, price: Double? = 6.99
    ) -> AppleBooksResult {
        AppleBooksResult(
            trackId: id, trackName: name, artistName: artist, description: blurb,
            artworkUrl100: URL(string: "https://is1-ssl.mzstatic.com/x/\(id).jpg/100x100bb.jpg"),
            trackViewUrl: URL(string: "https://books.apple.com/gb/book/id\(id)"),
            price: price, formattedPrice: price.map { "£\($0)" }, releaseDate: nil
        )
    }

    /// The live GB answer for "solo leveling", 2026-09-11, reduced: comics,
    /// novels of the same name, and the Ragnarok sequel.
    ///
    /// Result 7, "Solo Leveling Volume 3", carries no tag at all — the same
    /// shape as an untagged novel edition. Once the comic shelf has tagged
    /// "(comic)" rows of its own (results 1, 3, 5, 6), an untagged row must
    /// not fill a number gap on it (T4), so volume 3 is absent here even
    /// though result 7 parses fine on its own.
    @Test("The series' own comic volumes, one per number, in order; nothing else")
    func strictMatch() {
        let results = [
            result(1, "Solo Leveling, Vol. 1 (comic)"),
            result(2, "Solo Leveling, Vol. 1 (novel)"),
            result(3, "Solo Leveling, Vol. 8 (comic)"),
            result(4, "Solo Leveling: Ragnarok, Vol. 1 (comic)"),
            result(5, "Solo Leveling, Vol. 2 (comic)"),
            result(6, "Solo Leveling, Vol. 8 (comic)", price: 4.99), // a second listing
            result(7, "Solo Leveling Volume 3"), // untagged — dropped by T4, see above
            result(8, "Something Else, Vol. 4 (comic)")
        ]
        let volumes = AppleBooksMatch.volumes(in: results, titles: ["Solo Leveling"], isNovel: false)
        #expect(volumes.map(\.number) == [1, 2, 8])
        #expect(volumes.map(\.id) == [1, 5, 3], "The first listing of a number wins")
        #expect(volumes[0].artworkURL?.absoluteString.hasSuffix("600x600bb.jpg") == true)
    }

    /// T4: an untagged row must not fill a number gap the comic's own
    /// tagged rows leave — Square Enix's "01 (Manga)"…"16 (Manga)" run is
    /// missing "03", and an untagged "Volume 3" (the shape J-Novel Club's
    /// own bare early novels take) must not sit on the comic's shelf in its
    /// place.
    ///
    /// Before this fix: `comic.map(\.number)` included `3`, sourced from
    /// the untagged row, because `if let tag = parts.tag` skipped the
    /// kind check entirely when there was no tag to check.
    @Test("An untagged row cannot fill a gap in a shelf that already has tagged editions")
    func untaggedRowDoesNotFillGap() {
        let results = [
            result(1, "The Apothecary Diaries 01 (Manga)"),
            result(2, "The Apothecary Diaries 02 (Manga)"),
            // No "03 (Manga)" — the gap an untagged row must not fill.
            result(3, "The Apothecary Diaries 16 (Manga)"),
            result(4, "The Apothecary Diaries: Volume 3")
        ]
        let comic = AppleBooksMatch.volumes(in: results, titles: ["The Apothecary Diaries"], isNovel: false)
        #expect(comic.map(\.number) == [1, 2, 16], "volume 3 stays absent, not the novel's cover")
    }

    /// The live GB answer for "The Apothecary Diaries", 2026-09-13, reduced.
    /// Square Enix titles the comic "The Apothecary Diaries 01 (Manga)" —
    /// a bare number, then the kind in brackets — while J-Novel Club's light
    /// novels are "The Apothecary Diaries: Volume 1" up to 6 and only add
    /// "(Light Novel)" from 7. Abdi's phone showed six volumes: the six
    /// untagged novels, because the comic's numbering had no "Vol." to match.
    @Test("A bare number with a bracketed kind is a volume, and the tagged kind beats an untagged one")
    func bareNumberWithKind() {
        let results = [
            result(1, "The Apothecary Diaries: Volume 1"),
            result(2, "The Apothecary Diaries 01 (Manga)"),
            result(3, "The Apothecary Diaries 02 (Manga)"),
            result(4, "The Apothecary Diaries: Volume 7 (Light Novel)"),
            result(5, "The Apothecary Diaries 16 (Manga)", price: nil),
            result(6, "The Apothecary Diaries: Maomao’s Notes on the Inner Palace, Vol. 1"),
            result(7, "The Apothecary Diaries Art Book")
        ]
        let comic = AppleBooksMatch.volumes(in: results, titles: ["The Apothecary Diaries"], isNovel: false)
        #expect(comic.map(\.number) == [1, 2, 16])
        #expect(comic.map(\.id) == [2, 3, 5], "The edition tagged (Manga) wins over the untagged novel")

        let novel = AppleBooksMatch.volumes(in: results, titles: ["The Apothecary Diaries"], isNovel: true)
        #expect(novel.map(\.number) == [1, 7])
        #expect(novel.map(\.id) == [1, 4])
    }

    /// The GB store's answer for HUNTER×HUNTER is the French edition,
    /// "Hunter ✖ Hunter - Volume 1" credited to its translator; the results
    /// carry no language, so the credit is the tell (Abdi's phone,
    /// 2026-09-11).
    @Test("A volume credited to none of the series' creators is another edition")
    func creatorCredit() {
        let results = [
            result(1, "Hunter ✖ Hunter - Volume 1", by: "Baptiste Peyron"),
            result(2, "Hunter x Hunter, Vol. 2", by: "Yoshihiro Togashi"),
            result(3, "One Piece, Vol. 1", by: "Eiichiro Oda")
        ]
        let hunter = AppleBooksMatch.volumes(
            in: results, titles: ["HUNTER×HUNTER"], creators: ["Yoshihiro Togashi"], isNovel: false
        )
        #expect(hunter.map(\.id) == [2])
        // MangaBaka spells it "Eiichirou Oda"; the surname carries it.
        let onePiece = AppleBooksMatch.volumes(
            in: results, titles: ["ONE PIECE"], creators: ["Eiichirou Oda"], isNovel: false
        )
        #expect(onePiece.map(\.id) == [3])
        // No creators known: nothing to check against, so the title decides.
        let unknown = AppleBooksMatch.volumes(in: results, titles: ["HUNTER×HUNTER"], isNovel: false)
        #expect(unknown.map(\.id) == [1, 2])
    }

    /// The Hunter ✖ Hunter listing's first sentence, and VIZ's English one.
    /// A blurb too short to judge rejects nothing.
    @Test("A blurb confidently in another language is another edition")
    func blurbLanguage() {
        let french = "Parmi les mangas shōnen à succès, tels que One Piece, Naruto ou Spy x Family, " +
            "une série se démarque particulièrement par son intelligence et sa noirceur."
        let english = "Gon Freecss wants to become a Hunter, an elite member of humanity " +
            "who tracks down rare treasures, exotic animals and dangerous criminals."
        let results = [
            result(1, "Hunter x Hunter, Vol. 1", blurb: french),
            result(2, "Hunter x Hunter, Vol. 2", blurb: english),
            result(3, "Hunter x Hunter, Vol. 3", blurb: "Vol. 3"),
            result(4, "Hunter x Hunter, Vol. 4")
        ]
        let mine = AppleBooksMatch.volumes(
            in: results, titles: ["Hunter x Hunter"], isNovel: false, language: "en"
        )
        #expect(mine.map(\.id) == [2, 3, 4])
        #expect(AppleBooksMatch.languageOf(french) == "fr")
        #expect(AppleBooksMatch.languageOf("Vol. 3") == nil)
    }

    /// The Japanese store writes "ONE PIECE モノクロ版 115": no marker, an
    /// edition word, the bare number. Only that store, only that edition.
    @Test("The Japanese store's bare numbering, one per number")
    func bareNumbering() {
        let results = [
            result(1, "ONE PIECE モノクロ版 115"), result(2, "ONE PIECE カラー版 1"),
            result(3, "ONE PIECE モノクロ版 1"), result(4, "ONE PIECE of Paper"),
            result(5, "ONE PIECE 2")
        ]
        let bare = AppleBooksMatch.volumes(
            in: results, titles: ["ONE PIECE", "ワンピース"], isNovel: false, numbering: .bare
        )
        #expect(bare.map(\.number) == [1, 2, 115])
        #expect(bare.map(\.id) == [2, 5, 1], "The first listing of a number, whichever edition")
        // The marker rule still rejects every one of these.
        let marker = AppleBooksMatch.volumes(in: results, titles: ["ONE PIECE"], isNovel: false)
        #expect(marker.isEmpty)
    }

    /// T1: Kodansha writes the bare Japanese number in brackets rather than
    /// after a space — 0 of 34 Attack on Titan volumes matched the
    /// whitespace-then-digits shape the fallback was built from (Shueisha's
    /// ONE PIECE, above). Half- and full-width parentheses both occur.
    @Test("The Japanese store's bracketed bare numbering (Kodansha)")
    func bareNumberingWithBrackets() {
        let results = [
            result(1, "進撃の巨人 (1)"),
            result(2, "進撃の巨人(34)"),
            result(3, "進撃の巨人（12）") // full-width parentheses
        ]
        let bare = AppleBooksMatch.volumes(in: results, titles: ["進撃の巨人"], isNovel: false, numbering: .bare)
        #expect(bare.map(\.number) == [1, 12, 34])
        #expect(bare.map(\.id) == [1, 3, 2])
    }

    @Test("A novel series takes the novels and leaves the comics")
    func novels() {
        let results = [result(1, "Solo Leveling, Vol. 1 (comic)"), result(2, "Solo Leveling, Vol. 1 (novel)")]
        let volumes = AppleBooksMatch.volumes(in: results, titles: ["Solo Leveling"], isNovel: true)
        #expect(volumes.map(\.id) == [2])
    }

    /// T8/F5: a comic tagged "(Graphic Novel)" is a comic, not a novel — the
    /// word "novel" alone is not enough. `AppleBooksMatch.isNovelTag` is the
    /// one place this is decided, shared with Google's matcher (T3).
    @Test("\"(Graphic Novel)\" reads as a comic, not a novel")
    func graphicNovelIsAComic() {
        #expect(AppleBooksMatch.isNovelTag("graphic novel") == false)
        #expect(AppleBooksMatch.isNovelTag("light novel") == true)
        let results = [result(1, "Watchmen, Vol. 1 (Graphic Novel)")]
        let comic = AppleBooksMatch.volumes(in: results, titles: ["Watchmen"], isNovel: false)
        #expect(comic.map(\.id) == [1])
        let novel = AppleBooksMatch.volumes(in: results, titles: ["Watchmen"], isNovel: true)
        #expect(novel.isEmpty)
    }

    /// F3: the fixture above is one publisher per rule. Seven Seas puts the
    /// kind bracket *before* the marker; VIZ appends a subtitle *after* the
    /// number. Both were rejected outright by the pattern the morning of
    /// 2026-09-13 fixed for Square Enix's shape alone.
    @Test("Seven Seas' leading bracket and VIZ's trailing subtitle both parse")
    func sevenSeasAndVIZShapes() {
        let sevenSeas = AppleBooksMatch.split("Mushoku Tensei: Jobless Reincarnation (Manga) Vol. 1")
        #expect(sevenSeas?.title == "Mushoku Tensei: Jobless Reincarnation")
        #expect(sevenSeas?.number == 1)
        #expect(sevenSeas?.tag == "manga")

        let viz = AppleBooksMatch.split("Naruto, Vol. 1: Uzumaki Naruto")
        #expect(viz?.title == "Naruto")
        #expect(viz?.number == 1)

        // Still rejected: the subtitle sitting *between* the title and the
        // marker is a different series, not a dropped trailing subtitle.
        let ragnarok = AppleBooksMatch.split("Solo Leveling: Ragnarok, Vol. 1")
        #expect(ragnarok?.title != "Solo Leveling")
    }

    /// F4: `split` correctly reads the number out of an omnibus title, but
    /// the shelf must still reject it — a "Deluxe" collects three volumes
    /// into one, so it is not volume 12 of the plain series.
    @Test("A deluxe/omnibus edition is not a numbered volume of the plain series")
    func deluxeEditionIsNotAPlainVolume() {
        #expect(AppleBooksMatch.split("Berserk Deluxe Volume 12")?.number == 12)
        let results = [result(1, "Berserk Deluxe Volume 12")]
        let shelf = AppleBooksMatch.volumes(in: results, titles: ["Berserk"], isNovel: false)
        #expect(shelf.isEmpty, "\"Berserk Deluxe\" must not appear on the plain \"Berserk\" shelf")
    }

    /// The store lists ONE PIECE as "One Piece, Vol. 1"; the alternative
    /// titles are what make a romanised or differently-cased name match.
    @Test("Any of the series' titles matches, ignoring case and punctuation")
    func titlesAndNormalisation() {
        let results = [result(1, "One Piece, Vol. 1"), result(2, "ワンピース #2")]
        let volumes = AppleBooksMatch.volumes(in: results, titles: ["ONE PIECE", "ワンピース"], isNovel: false)
        #expect(volumes.map(\.number) == [1, 2])
        #expect(AppleBooksMatch.normalise("Solo-Leveling!") == "sololeveling")
        #expect(AppleBooksMatch.split("Berserk Deluxe Volume 12")?.number == 12)
        #expect(AppleBooksMatch.split("Berserk Deluxe") == nil)
    }
}

/// The client: one keyless request, an answer cached for a week, and nil
/// when the store cannot be asked.
@Suite("Apple Books client", .serialized)
struct AppleBooksClientTests {
    private func makeClient(clock: TestClock) -> AppleBooksClient {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("applebooks-tests-\(UUID().uuidString)", isDirectory: true)
        return AppleBooksClient(
            session: URLProtocolStub.makeSession(), clock: clock, cacheDirectory: directory
        )
    }

    private let answer = Data(#"""
    {"resultCount":2,"results":[
      {"trackId":1,"trackName":"Solo Leveling, Vol. 1 (comic)","artworkUrl100":"https://a/1/100x100bb.jpg",
       "artistName":"Chugong, Abigail Blackman, J. Torres",
       "trackViewUrl":"https://books.apple.com/gb/book/id1","price":6.99,"formattedPrice":"£6.99",
       "releaseDate":"2021-02-16T08:00:00Z"},
      {"trackId":2,"trackName":"Solo Leveling: Ragnarok, Vol. 1 (comic)"}
    ]}
    """#.utf8)

    @Test("Asks the store with the series title, the ebook filters and the country")
    func request() async throws {
        URLProtocolStub.setHandler { _ in .respond(.init(body: answer)) }
        defer { URLProtocolStub.reset() }
        let client = makeClient(clock: TestClock())

        let series = SeriesFactory.make(id: 3397, title: "Solo Leveling", authors: ["Chu-Gong"])
        let volumes = await client.volumes(for: series, country: "GB")

        #expect(try volumes.get().map(\.number) == [1])
        #expect(try volumes.get().first?.formattedPrice == "£6.99")
        let url = URLProtocolStub.requests.first?.url?.absoluteString ?? ""
        #expect(url.hasPrefix("https://itunes.apple.com/search?"))
        for expected in ["term=Solo%20Leveling", "media=ebook", "entity=ebook", "country=GB", "limit=200"] {
            #expect(url.contains(expected), Comment(rawValue: expected))
        }
    }

    /// T9: a strict `.iso8601` `Date` on `releaseDate` — a field nothing on
    /// screen reads — used to fail the whole envelope's decode over one row
    /// with a fractional second, sinking all 200 results to "Apple Books
    /// couldn't be reached". Before the fix (`releaseDate: Date?` with
    /// `decoder.dateDecodingStrategy = .iso8601`), this would fail with:
    /// `volumes == nil` — one bad date rejected the other 199 good rows.
    @Test("A 200-row envelope with one odd release date still decodes in full")
    func oneOddReleaseDateDoesNotSinkTheEnvelope() async throws {
        let rows: [[String: Any]] = (1...200).map { number in
            // Row 143 is the one the reviewer measured live: a fractional-
            // second timestamp `.iso8601` (no fractional-seconds option)
            // rejects outright.
            let date = number == 143 ? "2026-09-13T10:00:00.123Z" : "2021-02-16T08:00:00Z"
            return [
                "trackId": number,
                "trackName": "Solo Leveling, Vol. \(number) (comic)",
                "artistName": "Chu-Gong",
                "releaseDate": date
            ]
        }
        let envelope = try JSONSerialization.data(withJSONObject: ["resultCount": 200, "results": rows])
        URLProtocolStub.setHandler { _ in .respond(.init(body: envelope)) }
        defer { URLProtocolStub.reset() }
        let client = makeClient(clock: TestClock())
        let series = SeriesFactory.make(id: 3397, title: "Solo Leveling", authors: ["Chu-Gong"])

        let volumes = await client.volumes(for: series, country: "gb")
        #expect(try volumes.get().count == 200, "one odd date must not sink the other 199 rows")
    }

    @Test("A second look inside a week costs no request; after a week it does")
    func cache() async {
        URLProtocolStub.setHandler { _ in .respond(.init(body: answer)) }
        defer { URLProtocolStub.reset() }
        let clock = TestClock()
        let client = makeClient(clock: clock)
        let series = SeriesFactory.make(id: 3397, title: "Solo Leveling", authors: ["Chu-Gong"])

        _ = await client.volumes(for: series, country: "gb")
        _ = await client.volumes(for: series, country: "gb")
        #expect(URLProtocolStub.requests.count == 1)

        clock.advance(by: AppleBooksClient.cacheLife + 1)
        _ = await client.volumes(for: series, country: "gb")
        #expect(URLProtocolStub.requests.count == 2)
    }

    /// Nil, not empty: "the store could not be asked" must not be shown as
    /// "no volumes", and must not be cached as it either.
    ///
    /// Since item 60 the failure also says *which* failure: `volumes` returns
    /// `Result<[AppleBooksVolume], APIError>` rather than an optional, so
    /// `VolumesSection` can render a reason and a retry instead of one bare
    /// line of text. Expected failure before that change: `first` was `nil`
    /// and there was nothing to assert about a `.server(500)` at all.
    @Test("A failure names its reason, is not an empty shelf, and is not remembered")
    func failure() async throws {
        URLProtocolStub.setHandler { _ in .respond(.init(statusCode: 500)) }
        defer { URLProtocolStub.reset() }
        let client = makeClient(clock: TestClock())
        let series = SeriesFactory.make(id: 3397, title: "Solo Leveling", authors: ["Chu-Gong"])

        let first = await client.volumes(for: series, country: "gb")
        if case let .failure(error) = first {
            #expect(error == .server(status: 500, message: "", party: .appleBooks))
        } else {
            Issue.record("a 500 must not read as an empty shelf")
        }

        URLProtocolStub.setHandler { _ in .respond(.init(body: answer)) }
        let second = await client.volumes(for: series, country: "gb")
        #expect(try second.get().count == 1)
    }

    /// Gap 72: the cache file already carried `storedAt` and every read threw
    /// it away. Expected failure before the fix: this does not compile —
    /// `readCache` returned `[AppleBooksVolume]?` with no age alongside it.
    @Test("The cache exposes when it was written, not only what")
    func cacheExposesAge() async {
        URLProtocolStub.setHandler { _ in .respond(.init(body: answer)) }
        defer { URLProtocolStub.reset() }
        let clock = TestClock()
        let client = makeClient(clock: clock)
        let series = SeriesFactory.make(id: 3397, title: "Solo Leveling", authors: ["Chu-Gong"])
        let writtenAt = clock.now

        _ = await client.volumes(for: series, country: "gb")
        clock.advance(by: 6 * 24 * 3600)

        // v6 since 2026-09-14: Wikidata can overrule MangaBaka's `type` on the
        // novel question, so an answer matched under v5 must not outlive it.
        let key = "v6-\(series.id)-gb-any"
        let cached = await client.readCache(key)
        #expect(cached?.storedAt == writtenAt, "the age must be the write time, not the read time")
    }

    /// Gap 73: a 403 used to get the same 60s backoff as a 429, on the theory
    /// that Apple answers an over-limit client with 403 as often as 429. It
    /// also answers 403 for a store the requested country does not sell
    /// ebooks in, which has nothing to do with this client having asked too
    /// much — backing every future request off for that would stall
    /// `japaneseVolumes` (a different country) for an unrelated reason.
    /// Expected failure before the fix: the second call below also returns
    /// nil, because the first 403 armed a 60s backoff that suppressed it.
    @Test("A 403 does not back off the way a 429 does")
    func forbiddenDoesNotBackOff() async throws {
        URLProtocolStub.setHandler { _ in .respond(.init(statusCode: 403)) }
        defer { URLProtocolStub.reset() }
        let clock = TestClock()
        let client = makeClient(clock: clock)
        let series = SeriesFactory.make(id: 3397, title: "Solo Leveling", authors: ["Chu-Gong"])

        let first = await client.volumes(for: series, country: "gb")
        #expect(first.failureError != nil)

        URLProtocolStub.setHandler { _ in .respond(.init(body: answer)) }
        // No time advance at all: if the 403 had armed a backoff the way a
        // 429 does, this would still be inside its 60s window and fail.
        let second = await client.volumes(for: series, country: "gb")
        #expect(try second.get().count == 1, "a 403 must not suppress the very next request")
    }

    /// Gap 28: `try? await Task.sleep` swallowed cancellation and fell
    /// through to firing the request anyway — for a page the reader already
    /// left. Expected failure before the fix: `URLProtocolStub.requests` is
    /// non-empty, because the cancelled task still spent its claimed slot.
    @Test("A cancelled wait for a request slot does not fire the request")
    func cancelledWaitDoesNotFireTheRequest() async {
        URLProtocolStub.setHandler { _ in .respond(.init(body: answer)) }
        defer { URLProtocolStub.reset() }
        let clock = TestClock()
        let client = makeClient(clock: clock)
        let series = SeriesFactory.make(id: 3397, title: "Solo Leveling", authors: ["Chu-Gong"])

        // Claim the only free slot with a call that never awaits far enough
        // to be cancelled, so the next call must wait — that wait is what
        // gets cancelled below.
        let warm = Task { await client.volumes(for: series, country: "gb") }
        _ = await warm.value

        let task = Task { await client.volumes(for: series, country: "fr") }
        task.cancel()
        _ = await task.value

        #expect(URLProtocolStub.requests.count == 1, "only the warm-up request should have been sent")
    }
}

/// Gated per test, not per suite (2026-09-14): the gate on the suite also
/// skipped the tests below that assert on a value and never touch the
/// checkout, so they did not run on Xcode Cloud at all — and nothing
/// reports the difference between a local run and a cloud one.
@Suite("Apple volumes on the page")
struct AppleVolumesRowTests {
    /// One spine on the shelf, built the way the page builds it.
    @MainActor
    private func row(_ volume: AppleBooksVolume, expected: Int?) -> AppleVolumesRow {
        AppleVolumesRow(
            volumes: VolumeShelf.merge(apple: [volume], google: []), expected: expected
        )
    }

    @Test("The count admits when the store is behind the series")
    @MainActor
    func countLine() {
        let volume = AppleBooksVolume(
            id: 1, number: 1, title: "x", artworkURL: nil, storeURL: nil,
            price: nil, formattedPrice: nil, releaseDate: nil
        )
        #expect(row(volume, expected: 27).countLine == "1 of 27 on Apple Books")
        #expect(row(volume, expected: 1).countLine == "1")
        #expect(row(volume, expected: nil).countLine == "1")
    }

    /// S12: `countLine` used to compare a count with a number
    /// (`expected > volumes.count`), so a 15-volume shelf numbered 1-14 and
    /// 30 — missing volume 15 itself — read as complete because the *count*
    /// already matched `expected`. Before the fix this line would have
    /// read: `#expect(built.countLine == "15")`.
    @Test("The count admits a gap even when the total already matches")
    @MainActor
    func countLineChecksCoverage() {
        let numbers = Array(1...14) + [30]
        let volumes = numbers.map {
            AppleBooksVolume(
                id: $0, number: $0, title: "x", artworkURL: nil, storeURL: nil,
                price: nil, formattedPrice: nil, releaseDate: nil
            )
        }
        let built = AppleVolumesRow(volumes: VolumeShelf.merge(apple: volumes, google: []), expected: 15)
        #expect(
            built.countLine == "15 of 15 on Apple Books",
            "15 numbered volumes, but volume 15 itself is missing"
        )
    }

    /// The phone showed MangaBaka's seven One Piece editions with no hint
    /// of the store, and it was not possible to tell a failed request from
    /// a build without the feature. Now a failure says so.
    /// A series the reader's store does not sell falls back to the Japanese
    /// store's edition — covers and a count, no price, and it says so.
    @Test("Nothing at home, so the Japanese edition, labelled", .enabled(if: SourceTree.isAvailable))
    func japaneseFallback() throws {
        let source = try SourceTree.read("MangaBaka/Features/Detail/SeriesDetailView+Store.swift")
        // `(try? answer.get())?.isEmpty`, not `answer?.isEmpty`, since item
        // 60 made `volumes` return a `Result` — the rule is unchanged: an
        // empty home store, never a failed one, is what falls back.
        #expect(
            source.contains("if (try? answer.get())?.isEmpty == true, country.lowercased() != \"jp\"")
        )
        #expect(source.contains("answer = await appleBooks.japaneseVolumes(for: shown)"))
        let row = try SourceTree.read("MangaBaka/Features/Detail/AppleVolumesRow.swift")
        #expect(row.contains("if edition == nil, let price = volume.formattedPrice"))
    }

    /// Item 60 replaced the `Bool` this used to pin. `appleUnreachable` said
    /// only "something went wrong" and `VolumesSection` rendered it as one
    /// bare sentence with no retry; `appleFailure: APIError?` carries the
    /// reason, and the section renders the same `InlineFailure` every other
    /// section on the page has had since gap 10.
    @Test(
        "A store that could not be reached says which failure, and offers a retry",
        .enabled(if: SourceTree.isAvailable)
    )
    func failureIsSaid() throws {
        let source = try SourceTree.read("MangaBaka/Features/Detail/SeriesDetailView+Store.swift")
        #expect(source.contains("case let .failure(error):"))
        #expect(source.contains("appleFailure = error"))
        #expect(source.contains("failure: appleFailure,"))
        #expect(source.contains("retry: { await loadAppleVolumes() },"))
    }

    @Test(
        "The store's shelf replaces MangaBaka's editions, never joins them",
        .enabled(if: SourceTree.isAvailable)
    )
    func replaces() throws {
        let source = try SourceTree.read("MangaBaka/Features/Detail/SeriesDetailView+Store.swift")
        // `shelf`, not `appleVolumes`: the shelf is now Apple's volumes plus
        // any number only Google has (VolumeShelf.merge). The rule this pins
        // is unchanged — one shelf or the other, never both at once.
        let either = "if shelf.isEmpty {\n            VolumesSection(\n"
        #expect(source.contains(either))
        #expect(source.contains("volumes: extras.volumes,"))
    }
}

/// Which shelf spines are worth asking `OpenLibraryCovers` about at all —
/// the ones neither Apple nor Google sent artwork for.
@Suite("Open Library gap detection on the shelf")
struct VolumeShelfOpenLibraryTests {
    private func volume(
        _ number: Int, artwork: URL?, source: ShelfVolume.Source = .appleBooks
    ) -> ShelfVolume {
        let cover = Cover(
            raw: artwork, x150: nil, x250: nil, x350: nil, blurhash: nil, width: nil, height: nil
        )
        return ShelfVolume(number: number, cover: cover, link: nil, formattedPrice: nil, source: source)
    }

    @Test("Only the numbers with no artwork of their own are flagged")
    func onlyBareNumbersFlagged() {
        let art = URL(string: "https://example.com/1.jpg")
        let volumes = [volume(1, artwork: art), volume(2, artwork: nil)]
        #expect(VolumeShelf.numbersNeedingCovers(volumes) == [2])
    }

    @Test("Attribution names Open Library only when it was actually used")
    func attributionNamesOpenLibraryOnlyWhenUsed() {
        let volumes = [volume(1, artwork: nil)]
        #expect(VolumeShelf.attribution(for: volumes) == "Apple Books")
        #expect(
            VolumeShelf.attribution(for: volumes, openLibraryUsed: true) == "Apple Books & Open Library"
        )
        let both = volumes + [volume(2, artwork: nil, source: .googleBooks)]
        #expect(
            VolumeShelf.attribution(for: both, openLibraryUsed: true) == "Apple & Google Books & Open Library"
        )
    }
}

/// S2: `SeriesWork.date` parses a release date as UTC midnight on purpose —
/// reading it back through the device's own calendar rolls a 1 January
/// release onto 31 December of the previous year for every reader west of
/// UTC. Before the fix, `VolumesSection` read the year with
/// `Calendar.current.component(.year, from:)`, so on a device set to
/// America/Los_Angeles this control would have read 2020, not 2021.
@Suite("Volume spine year")
struct VolumesSectionSpineYearTests {
    @Test("The spine year is read in UTC, not the device's own zone")
    func spineYearIsUTC() {
        let utcMidnight = Date(timeIntervalSince1970: 1_609_459_200) // 2021-01-01T00:00:00Z
        #expect(VolumesSection.spineYear(for: utcMidnight) == 2021)

        // Control: this is the failure the fix guards against — the same
        // instant read through a negative-offset zone, which is what
        // `Calendar.current` would do on a US West Coast phone.
        var losAngeles = Calendar(identifier: .gregorian)
        losAngeles.timeZone = TimeZone(identifier: "America/Los_Angeles") ?? .current
        #expect(losAngeles.component(.year, from: utcMidnight) == 2020)
    }
}
