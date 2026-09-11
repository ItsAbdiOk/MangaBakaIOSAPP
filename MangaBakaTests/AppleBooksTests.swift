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
    @Test("The series' own comic volumes, one per number, in order; nothing else")
    func strictMatch() {
        let results = [
            result(1, "Solo Leveling, Vol. 1 (comic)"),
            result(2, "Solo Leveling, Vol. 1 (novel)"),
            result(3, "Solo Leveling, Vol. 8 (comic)"),
            result(4, "Solo Leveling: Ragnarok, Vol. 1 (comic)"),
            result(5, "Solo Leveling, Vol. 2 (comic)"),
            result(6, "Solo Leveling, Vol. 8 (comic)", price: 4.99), // a second listing
            result(7, "Solo Leveling Volume 3"),
            result(8, "Something Else, Vol. 4 (comic)")
        ]
        let volumes = AppleBooksMatch.volumes(in: results, titles: ["Solo Leveling"], isNovel: false)
        #expect(volumes.map(\.number) == [1, 2, 3, 8])
        #expect(volumes.map(\.id) == [1, 5, 7, 3], "The first listing of a number wins")
        #expect(volumes[0].artworkURL?.absoluteString.hasSuffix("600x600bb.jpg") == true)
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

    @Test("A novel series takes the novels and leaves the comics")
    func novels() {
        let results = [result(1, "Solo Leveling, Vol. 1 (comic)"), result(2, "Solo Leveling, Vol. 1 (novel)")]
        let volumes = AppleBooksMatch.volumes(in: results, titles: ["Solo Leveling"], isNovel: true)
        #expect(volumes.map(\.id) == [2])
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
    func request() async {
        URLProtocolStub.setHandler { _ in .respond(.init(body: answer)) }
        defer { URLProtocolStub.reset() }
        let client = makeClient(clock: TestClock())

        let series = SeriesFactory.make(id: 3397, title: "Solo Leveling", authors: ["Chu-Gong"])
        let volumes = await client.volumes(for: series, country: "GB")

        #expect(volumes?.map(\.number) == [1])
        #expect(volumes?.first?.formattedPrice == "£6.99")
        let url = URLProtocolStub.requests.first?.url?.absoluteString ?? ""
        #expect(url.hasPrefix("https://itunes.apple.com/search?"))
        for expected in ["term=Solo%20Leveling", "media=ebook", "entity=ebook", "country=GB", "limit=200"] {
            #expect(url.contains(expected), Comment(rawValue: expected))
        }
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
    @Test("A failure is nil and is not remembered")
    func failure() async {
        URLProtocolStub.setHandler { _ in .respond(.init(statusCode: 500)) }
        defer { URLProtocolStub.reset() }
        let client = makeClient(clock: TestClock())
        let series = SeriesFactory.make(id: 3397, title: "Solo Leveling", authors: ["Chu-Gong"])

        let first = await client.volumes(for: series, country: "gb")
        #expect(first == nil)
        URLProtocolStub.setHandler { _ in .respond(.init(body: answer)) }
        let second = await client.volumes(for: series, country: "gb")
        #expect(second?.count == 1)
    }
}

@Suite("Apple volumes on the page", .enabled(if: SourceTree.isAvailable))
struct AppleVolumesRowTests {
    @Test("The count admits when the store is behind the series")
    @MainActor
    func countLine() {
        let volume = AppleBooksVolume(
            id: 1, number: 1, title: "x", artworkURL: nil, storeURL: nil,
            price: nil, formattedPrice: nil, releaseDate: nil
        )
        #expect(AppleVolumesRow(volumes: [volume], expected: 27).countLine == "1 of 27")
        #expect(AppleVolumesRow(volumes: [volume], expected: 1).countLine == "1")
        #expect(AppleVolumesRow(volumes: [volume], expected: nil).countLine == "1")
    }

    /// The phone showed MangaBaka's seven One Piece editions with no hint
    /// of the store, and it was not possible to tell a failed request from
    /// a build without the feature. Now a failure says so.
    @Test("A store that could not be reached is said, not silent")
    func failureIsSaid() throws {
        let source = try SourceTree.read("MangaBaka/Features/Detail/SeriesDetailView+Store.swift")
        #expect(source.contains("appleUnreachable = answer == nil"))
        #expect(source.contains("note: appleUnreachable ? \"Apple Books couldn't be reached\" : nil"))
    }

    @Test("The store's shelf replaces MangaBaka's editions, never joins them")
    func replaces() throws {
        let source = try SourceTree.read("MangaBaka/Features/Detail/SeriesDetailView+Store.swift")
        let either = "if appleVolumes.isEmpty {\n            VolumesSection(\n"
        #expect(source.contains(either))
        #expect(source.contains("volumes: extras.volumes,"))
    }
}
